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
repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
manifest_identity=$(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print(m["source_commit"], m["source_tree"])' "$packages/manifest.json")
python3 "$repo_dir/scripts/verify-netfleet-release.py" --directory "$packages" \
  --source-commit "${manifest_identity%% *}" --source-tree "${manifest_identity#* }" >/dev/null
artifacts=()
while IFS= read -r name; do artifacts+=("$output/$name"); cp "$packages/$name" "$output/"; done < <(
  python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); assert m["package_format"] == "apk"; print("\n".join(i["name"] for i in m["artifacts"] + m.get("dependency_artifacts", [])))' "$packages/manifest.json"
)
[[ ${#artifacts[@]} -ge 2 ]] || die 'feed requires validated NetFleet APK artifacts'
"$apk_tool" mkndx --root "$output" --keys-dir "$(dirname "$sign_key")" --allow-untrusted \
  --output "$output/packages.adb" --sign "$sign_key" \
  "${artifacts[@]}"
[[ -s "$output/packages.adb" ]] || die 'generated feed index is empty'
chmod 0644 "$output"/*.apk "$output/packages.adb"
printf '%s\n' "$output/packages.adb"
