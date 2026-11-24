#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
APP_PKG="$ROOT_DIR/desktop/app"
INFO_PLIST="$APP_PKG/Info.plist"
EXPECTED_FEED_URL="https://github.com/gaofeng21cn/opl-netfleet/releases/latest/download/appcast.xml"

# 1. SwiftPM host must link Sparkle 2 with framework rpath.
grep -Fq 'https://github.com/sparkle-project/Sparkle' "$APP_PKG/Package.swift"
grep -Fq '.product(name: "Sparkle", package: "Sparkle")' "$APP_PKG/Package.swift"
grep -Fq '@executable_path/../Frameworks' "$APP_PKG/Package.swift"

# 2. Info.plist must declare valid Sparkle feed, 32-byte Ed25519 key, monotonic build, and automatic checks.
/usr/bin/plutil -lint "$INFO_PLIST" >/dev/null
ACTUAL_FEED_URL="$(/usr/bin/plutil -extract SUFeedURL raw "$INFO_PLIST")"
ACTUAL_PUBLIC_KEY="$(/usr/bin/plutil -extract SUPublicEDKey raw "$INFO_PLIST")"
ACTUAL_AUTO_CHECKS="$(/usr/bin/plutil -extract SUEnableAutomaticChecks raw "$INFO_PLIST")"
ACTUAL_AUTO_UPDATE="$(/usr/bin/plutil -extract SUAutomaticallyUpdate raw "$INFO_PLIST")"
ACTUAL_VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$INFO_PLIST")"
ACTUAL_BUILD="$(/usr/bin/plutil -extract CFBundleVersion raw "$INFO_PLIST")"

if [[ "$ACTUAL_FEED_URL" != "$EXPECTED_FEED_URL" ]]; then
  echo "Unexpected SUFeedURL in Info.plist: ${ACTUAL_FEED_URL:-none}" >&2
  exit 1
fi
if [[ "$ACTUAL_AUTO_CHECKS" != "true" ]]; then
  echo "Expected SUEnableAutomaticChecks=true, got ${ACTUAL_AUTO_CHECKS:-none}" >&2
  exit 1
fi
if [[ "$ACTUAL_AUTO_UPDATE" != "false" ]]; then
  echo "Expected SUAutomaticallyUpdate=false, got ${ACTUAL_AUTO_UPDATE:-none}" >&2
  exit 1
fi
if [[ ! "$ACTUAL_BUILD" =~ ^[1-9][0-9]*$ ]]; then
  echo "Expected positive monotonic integer CFBundleVersion, got ${ACTUAL_BUILD:-none}" >&2
  exit 1
fi
/usr/bin/python3 - "$ACTUAL_PUBLIC_KEY" <<'PY'
import base64
import sys

raw = base64.b64decode(sys.argv[1], validate=True)
if len(raw) != 32:
    raise SystemExit(f"Expected 32-byte Ed25519 public key, got {len(raw)} bytes")
PY

# 3. Native Sparkle updater wired into Swift host; retired hand-rolled DMG updater and raw ZIP EOCD parser removed.
grep -Fq 'SPUStandardUpdaterController' "$APP_PKG/AppUpdater.swift"
grep -Fq 'checkForUpdates' "$APP_PKG/main.swift"
grep -Fq 'Installer.xpc' "$ROOT_DIR/scripts/macos/build-app.py"
grep -Fq 'Downloader.xpc' "$ROOT_DIR/scripts/macos/build-app.py"
grep -Fq 'Autoupdate' "$ROOT_DIR/scripts/macos/build-app.py"
grep -Fq 'Updater.app' "$ROOT_DIR/scripts/macos/build-app.py"
if [[ -e "$ROOT_DIR/desktop/runtime/update.mjs" || -e "$ROOT_DIR/desktop/runtime/update-install.sh" ]]; then
  echo "Retired hand-rolled DMG updater files must not exist." >&2
  exit 1
fi
if grep -Eq '0x06054b50|0x02014b50|0x04034b50' "$ROOT_DIR/desktop/runtime/dashboard.mjs"; then
  echo "desktop/runtime/dashboard.mjs must not hand-parse raw ZIP binary structures." >&2
  exit 1
fi

# 4. If an app bundle path was passed, verify embedded Sparkle inside-out signature and rpath.
if [[ $# -ge 1 && -d "$1" ]]; then
  APP_BUNDLE="$1"
  SPARKLE_FW="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
  [[ -d "$SPARKLE_FW" ]]
  [[ -f "$SPARKLE_FW/Versions/B/Sparkle" ]]
  /usr/bin/otool -l "$APP_BUNDLE/Contents/MacOS/OPL NetFleet" | grep -Fq '@executable_path/../Frameworks'
  for comp in \
    "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc" \
    "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc" \
    "$SPARKLE_FW/Versions/B/Autoupdate" \
    "$SPARKLE_FW/Versions/B/Updater.app" \
    "$SPARKLE_FW"
  do
    /usr/bin/codesign --verify --strict "$comp"
  done
  /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
fi

# 5. End-to-end signed appcast generation and fail-closed verification with an ephemeral Ed25519 key.
SPARKLE_GENERATE=""
for candidate in \
  "$APP_PKG/.build/artifacts" \
  "$ROOT_DIR/.build/artifacts"
do
  if [[ -x "$candidate/sparkle/Sparkle/bin/generate_appcast" ]]; then
    SPARKLE_GENERATE="$candidate/sparkle/Sparkle/bin/generate_appcast"
    break
  fi
done
if [[ -z "$SPARKLE_GENERATE" ]]; then
  echo "Sparkle CLI tools missing under desktop/app/.build/artifacts; run swift build --package-path desktop/app first." >&2
  exit 1
fi

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/opl-netfleet-sparkle-contract.XXXXXX")"
cleanup() {
  rm -rf "${TEMP_ROOT:?}"
}
trap cleanup EXIT INT TERM

EPHEMERAL_KEYS="$(/usr/bin/swift -e 'import CryptoKit; import Foundation; let key = Curve25519.Signing.PrivateKey(); print(key.rawRepresentation.base64EncodedString()); print(key.publicKey.rawRepresentation.base64EncodedString())')"
EPHEMERAL_PRIV_KEY="$(printf '%s\n' "$EPHEMERAL_KEYS" | sed -n '1p')"
EPHEMERAL_PUB_KEY="$(printf '%s\n' "$EPHEMERAL_KEYS" | sed -n '2p')"

STAGING="$TEMP_ROOT/staging"
FAKE_APP="$STAGING/OPL NetFleet.app"
mkdir -p "$FAKE_APP/Contents/MacOS"
cp "$INFO_PLIST" "$FAKE_APP/Contents/Info.plist"
/usr/bin/plutil -replace SUPublicEDKey -string "$EPHEMERAL_PUB_KEY" "$FAKE_APP/Contents/Info.plist"
cp /usr/bin/true "$FAKE_APP/Contents/MacOS/OPL NetFleet"
chmod +x "$FAKE_APP/Contents/MacOS/OPL NetFleet"
/usr/bin/codesign --force --sign - "$FAKE_APP" >/dev/null 2>&1

FAKE_DMG="$TEMP_ROOT/OPL-NetFleet-macos-arm64.dmg"
/usr/bin/hdiutil create \
  -volname "OPL NetFleet" \
  -srcfolder "$STAGING" \
  -format UDZO \
  -ov \
  "$FAKE_DMG" >/dev/null

OUT_APPCAST="$TEMP_ROOT/appcast.xml"

SPARKLE_ED25519_PRIVATE_KEY="$EPHEMERAL_PRIV_KEY" \
OPL_NETFLEET_RELEASE_TAG="v$ACTUAL_VERSION" \
OPL_NETFLEET_APP_PATH="$FAKE_APP" \
OPL_NETFLEET_REQUIRE_SPARKLE_KEY_ENV=1 \
  "$ROOT_DIR/scripts/macos/generate-appcast.sh" "$FAKE_DMG" "$OUT_APPCAST" >/dev/null

[[ -s "$OUT_APPCAST" ]]
grep -Fq "<sparkle:version>$ACTUAL_BUILD</sparkle:version>" "$OUT_APPCAST"
grep -Fq "<sparkle:shortVersionString>$ACTUAL_VERSION</sparkle:shortVersionString>" "$OUT_APPCAST"
grep -Fq 'sparkle:edSignature="' "$OUT_APPCAST"

# Negative check: mismatched private key must fail closed.
WRONG_PRIV_KEY="$(/usr/bin/openssl rand -base64 32)"
if SPARKLE_ED25519_PRIVATE_KEY="$WRONG_PRIV_KEY" \
  OPL_NETFLEET_RELEASE_TAG="v$ACTUAL_VERSION" \
  OPL_NETFLEET_APP_PATH="$FAKE_APP" \
  OPL_NETFLEET_REQUIRE_SPARKLE_KEY_ENV=1 \
  "$ROOT_DIR/scripts/macos/generate-appcast.sh" "$FAKE_DMG" "$TEMP_ROOT/wrong-appcast.xml" >/dev/null 2>&1
then
  echo "generate-appcast.sh unexpectedly accepted a mismatched Ed25519 key." >&2
  exit 1
fi

echo "Verified OPL NetFleet Sparkle 2 updater contract and signed appcast generation for v$ACTUAL_VERSION ($ACTUAL_BUILD)."
