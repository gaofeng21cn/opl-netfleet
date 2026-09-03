#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf '%s\n' 'Usage: scripts/netfleet-feed-build.sh --packages <dir> --apk <apk> --sign-key <pem> --output <dir>'
}
die() { printf 'netfleet-feed-build: %s\n' "$1" >&2; exit 1; }

packages=''; apk_tool=''; sign_key=''; output=''
while (($#)); do
  case "$1" in
    --packages) (($# >= 2)) || die '--packages requires a directory'; packages=$2; shift 2;;
    --apk) (($# >= 2)) || die '--apk requires a path'; apk_tool=$2; shift 2;;
    --sign-key) (($# >= 2)) || die '--sign-key requires a path'; sign_key=$2; shift 2;;
    --output) (($# >= 2)) || die '--output requires a directory'; output=$2; shift 2;;
    -h|--help) usage; exit 0;;
    *) die "unknown option: $1";;
  esac
done
[[ -d "$packages" ]] || die 'package directory is unavailable'
[[ -x "$apk_tool" ]] || die 'apk tool is unavailable'
[[ -f "$sign_key" ]] || die 'signing key is unavailable'
[[ -n "$output" ]] || die '--output is required'
mkdir -p "$output"
artifacts=()
while IFS= read -r artifact; do artifacts+=("$artifact"); done < <(find "$packages" -maxdepth 1 -type f -name '*.apk' -print | LC_ALL=C sort)
[[ ${#artifacts[@]} -eq 2 ]] || die 'feed requires exactly two APK artifacts'
for artifact in "${artifacts[@]}"; do cp "$artifact" "$output/"; done
"$apk_tool" mkndx --root "$output" --keys-dir "$(dirname "$sign_key")" --allow-untrusted \
  --output "$output/packages.adb" --sign "$sign_key" \
  "$output/$(basename "${artifacts[0]}")" "$output/$(basename "${artifacts[1]}")"
[[ -s "$output/packages.adb" ]] || die 'generated feed index is empty'
chmod 0644 "$output"/*.apk "$output/packages.adb"
printf '%s\n' "$output/packages.adb"
