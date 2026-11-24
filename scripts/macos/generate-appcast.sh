#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
DMG_PATH="${1:-$ROOT_DIR/.build/macos/OPL-NetFleet-macos-arm64.dmg}"
OUTPUT_PATH="${2:-${DMG_PATH:h}/appcast.xml}"
RELEASE_TAG="${OPL_NETFLEET_RELEASE_TAG:-}"
REPOSITORY="${OPL_NETFLEET_REPOSITORY:-gaofeng21cn/opl-netfleet}"
SPARKLE_ACCOUNT="${OPL_NETFLEET_SPARKLE_ACCOUNT:-opl-netfleet}"
SPARKLE_KEY_FILE="${OPL_NETFLEET_SPARKLE_KEY_FILE:-}"
REQUIRE_KEY_ENV="${OPL_NETFLEET_REQUIRE_SPARKLE_KEY_ENV:-0}"
RELEASE_NOTES_FILE="${OPL_NETFLEET_RELEASE_NOTES_FILE:-}"
APP_PATH="${OPL_NETFLEET_APP_PATH:-$ROOT_DIR/.build/macos/OPL NetFleet.app}"

if [[ ! -f "$DMG_PATH" ]]; then
  echo "DMG not found: $DMG_PATH" >&2
  exit 1
fi

if [[ -z "$RELEASE_TAG" ]]; then
  if [[ -f "$APP_PATH/Contents/Info.plist" ]]; then
    VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$APP_PATH/Contents/Info.plist")"
    RELEASE_TAG="v$VERSION"
  else
    echo "OPL_NETFLEET_RELEASE_TAG is required when app bundle is unavailable." >&2
    exit 1
  fi
fi

EXPECTED_VERSION="${RELEASE_TAG#v}"
if [[ -z "$EXPECTED_VERSION" || "$RELEASE_TAG" != "v$EXPECTED_VERSION" ]]; then
  echo "Release tag must look like v<version>, got: $RELEASE_TAG" >&2
  exit 1
fi

SPARKLE_BIN_DIR=""
for candidate in \
  "$ROOT_DIR/desktop/app/.build/artifacts" \
  "$ROOT_DIR/.build/artifacts"
do
  if [[ -x "$candidate/sparkle/Sparkle/bin/generate_appcast" ]]; then
    SPARKLE_BIN_DIR="$candidate/sparkle/Sparkle/bin"
    break
  fi
  if [[ -d "$candidate" ]]; then
    found_tool="$(/usr/bin/find "$candidate" -path '*/Sparkle/bin/generate_appcast' -type f -perm -u+x -print -quit 2>/dev/null || true)"
    if [[ -n "$found_tool" ]]; then
      SPARKLE_BIN_DIR="${found_tool:h}"
      break
    fi
  fi
done

GENERATE_APPCAST="${SPARKLE_BIN_DIR:+$SPARKLE_BIN_DIR/generate_appcast}"
SIGN_UPDATE="${SPARKLE_BIN_DIR:+$SPARKLE_BIN_DIR/sign_update}"
if [[ -z "$GENERATE_APPCAST" || ! -x "$GENERATE_APPCAST" || ! -x "$SIGN_UPDATE" ]]; then
  echo "Sparkle CLI tools not found. Run swift build --package-path desktop/app first." >&2
  exit 1
fi

if [[ "$REQUIRE_KEY_ENV" == "1" && -z "${SPARKLE_ED25519_PRIVATE_KEY:-}" ]]; then
  echo "SPARKLE_ED25519_PRIVATE_KEY is required for release appcast generation." >&2
  exit 1
fi

# Fail closed if the supplied private key does not derive SUPublicEDKey in the app bundle.
if [[ -f "$APP_PATH/Contents/Info.plist" ]]; then
  EXPECTED_PUB_KEY="$(/usr/bin/plutil -extract SUPublicEDKey raw "$APP_PATH/Contents/Info.plist")"
  if [[ -n "${SPARKLE_ED25519_PRIVATE_KEY:-}" ]]; then
    ACTUAL_PUB_KEY="$(
      printf '%s' "$SPARKLE_ED25519_PRIVATE_KEY" | /usr/bin/swift -e '
import CryptoKit
import Foundation
let raw = FileHandle.standardInput.readDataToEndOfFile()
let b64 = String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
guard let seed = Data(base64Encoded: b64), seed.count == 32,
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
    fputs("Invalid Ed25519 private key seed\n", stderr)
    exit(1)
}
print(key.publicKey.rawRepresentation.base64EncodedString())
'
    )"
    if [[ "$ACTUAL_PUB_KEY" != "$EXPECTED_PUB_KEY" ]]; then
      echo "SPARKLE_ED25519_PRIVATE_KEY does not match SUPublicEDKey in $APP_PATH/Contents/Info.plist." >&2
      exit 1
    fi
  fi
fi

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/opl-netfleet-appcast.XXXXXX")"
cleanup() {
  rm -rf "${TEMP_DIR:?}"
}
trap cleanup EXIT INT TERM

DMG_NAME="${DMG_PATH:t}"
/bin/cp "$DMG_PATH" "$TEMP_DIR/$DMG_NAME"

DOWNLOAD_PREFIX="https://github.com/$REPOSITORY/releases/download/$RELEASE_TAG/"
RELEASE_PAGE_URL="https://github.com/$REPOSITORY/releases/tag/$RELEASE_TAG"

typeset -a appcast_args
appcast_args=(
  --download-url-prefix "$DOWNLOAD_PREFIX"
  --link "$RELEASE_PAGE_URL"
  --full-release-notes-url "$RELEASE_PAGE_URL"
)

if [[ -n "$RELEASE_NOTES_FILE" && -f "$RELEASE_NOTES_FILE" ]]; then
  /bin/cp "$RELEASE_NOTES_FILE" "$TEMP_DIR/${DMG_NAME:r}.md"
  appcast_args+=(--embed-release-notes)
fi

if [[ -n "${SPARKLE_ED25519_PRIVATE_KEY:-}" ]]; then
  printf '%s' "$SPARKLE_ED25519_PRIVATE_KEY" | \
    "$GENERATE_APPCAST" "${appcast_args[@]}" --ed-key-file - "$TEMP_DIR"
elif [[ -n "$SPARKLE_KEY_FILE" ]]; then
  "$GENERATE_APPCAST" "${appcast_args[@]}" --ed-key-file "$SPARKLE_KEY_FILE" "$TEMP_DIR"
else
  "$GENERATE_APPCAST" "${appcast_args[@]}" --account "$SPARKLE_ACCOUNT" "$TEMP_DIR"
fi

GENERATED_APPCAST="$TEMP_DIR/appcast.xml"
if [[ ! -s "$GENERATED_APPCAST" ]]; then
  echo "Sparkle generate_appcast did not produce $GENERATED_APPCAST." >&2
  exit 1
fi

EXPECTED_BUILD=""
if [[ -f "$APP_PATH/Contents/Info.plist" ]]; then
  EXPECTED_BUILD="$(/usr/bin/plutil -extract CFBundleVersion raw "$APP_PATH/Contents/Info.plist")"
fi
EXPECTED_LENGTH="$(stat -f%z "$DMG_PATH")"
EXPECTED_URL="${DOWNLOAD_PREFIX}${DMG_NAME}"

ED_SIGNATURE="$(
  /usr/bin/python3 - "$GENERATED_APPCAST" "$EXPECTED_VERSION" "$EXPECTED_BUILD" "$EXPECTED_URL" "$EXPECTED_LENGTH" <<'PY'
import sys
import xml.etree.ElementTree as ET

appcast_path, expected_version, expected_build, expected_url, expected_length = sys.argv[1:6]
sparkle_ns = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ns = {"sparkle": sparkle_ns}

tree = ET.parse(appcast_path)
root = tree.getroot()
items = root.findall("./channel/item")
if len(items) != 1:
    raise SystemExit(f"Expected exactly 1 item in appcast.xml, found {len(items)}")

item = items[0]
short_ver = item.findtext("sparkle:shortVersionString", namespaces=ns)
build_ver = item.findtext("sparkle:version", namespaces=ns)
min_sys = item.findtext("sparkle:minimumSystemVersion", namespaces=ns)
enclosure = item.find("enclosure")

if short_ver != expected_version:
    raise SystemExit(f"Expected sparkle:shortVersionString={expected_version}, got {short_ver!r}")
if expected_build and build_ver != expected_build:
    raise SystemExit(f"Expected sparkle:version={expected_build}, got {build_ver!r}")
if not build_ver:
    raise SystemExit("Missing sparkle:version in appcast item")
if not min_sys:
    raise SystemExit("Missing sparkle:minimumSystemVersion in appcast item")
if enclosure is None:
    raise SystemExit("Missing enclosure element in appcast item")

url = enclosure.attrib.get("url")
length = enclosure.attrib.get("length")
sig = enclosure.attrib.get(f"{{{sparkle_ns}}}edSignature")

if url != expected_url:
    raise SystemExit(f"Expected enclosure url={expected_url}, got {url!r}")
if length != expected_length:
    raise SystemExit(f"Expected enclosure length={expected_length}, got {length!r}")
if not sig:
    raise SystemExit("Missing sparkle:edSignature on enclosure")

print(sig)
PY
)"

if [[ -n "${SPARKLE_ED25519_PRIVATE_KEY:-}" ]]; then
  printf '%s' "$SPARKLE_ED25519_PRIVATE_KEY" | \
    "$SIGN_UPDATE" --ed-key-file - --verify "$DMG_PATH" "$ED_SIGNATURE"
elif [[ -n "$SPARKLE_KEY_FILE" ]]; then
  "$SIGN_UPDATE" --ed-key-file "$SPARKLE_KEY_FILE" --verify "$DMG_PATH" "$ED_SIGNATURE"
else
  "$SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" --verify "$DMG_PATH" "$ED_SIGNATURE"
fi

/bin/mkdir -p "${OUTPUT_PATH:h}"
/bin/cp "$GENERATED_APPCAST" "$OUTPUT_PATH"
echo "$OUTPUT_PATH"
