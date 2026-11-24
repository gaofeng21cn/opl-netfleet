#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf '%s\n' 'Usage: scripts/netfleet-feed-build.sh --packages <dir> [--merge-feed <dir>] --apk <apk> --sign-key <pem> --output <dir>'
}
die() { printf 'netfleet-feed-build: %s\n' "$1" >&2; exit 1; }

packages=''; merge_feed=''; apk_tool=''; sign_key=''; output=''
while (($#)); do
  case "$1" in
    --packages) (($# >= 2)) || die '--packages requires a directory'; packages=$2; shift 2;;
    --merge-feed) (($# >= 2)) || die '--merge-feed requires a directory'; merge_feed=$2; shift 2;;
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
if [[ -n "$merge_feed" ]]; then
  [[ -d "$merge_feed" ]] || die 'merge feed directory is unavailable'
fi
mkdir -p "$output"
repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/opl-netfleet-feed.XXXXXX")
trap 'rm -rf "$work"' EXIT

new_names=()
if [[ -f "$packages/manifest.json" ]]; then
  manifest_identity=$(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print(m["source_commit"], m["source_tree"])' "$packages/manifest.json")
  python3 "$repo_dir/scripts/verify-netfleet-release.py" --directory "$packages" \
    --source-commit "${manifest_identity%% *}" --source-tree "${manifest_identity#* }" >/dev/null
  architecture=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["build_target_arch"])' "$packages/manifest.json")
  while IFS= read -r name; do [[ -n "$name" ]] || continue; new_names+=("$name"); done < <(
    python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); assert m["package_format"] == "apk"; print("\n".join(i["name"] for i in m["artifacts"] + m.get("dependency_artifacts", [])))' "$packages/manifest.json"
  )
elif [[ -f "$packages/plugin-release.json" ]]; then
  release_meta=$(python3 - "$packages/plugin-release.json" "$packages" <<'PYPREL'
import hashlib, json, sys
from pathlib import Path
manifest = json.loads(Path(sys.argv[1]).read_text())
pkg_dir = Path(sys.argv[2])
assert manifest.get('schema') == 'opl-netfleet-plugin-release.v1', 'invalid plugin-release schema'
arch = manifest['build_target_arch']
names = []
for item in manifest.get('artifacts', []) + manifest.get('dependency_artifacts', []):
    name = item['name']
    path = pkg_dir / name
    assert path.is_file() and name.endswith('.apk'), f'missing APK: {name}'
    assert hashlib.sha256(path.read_bytes()).hexdigest() == item['sha256'], f'checksum mismatch: {name}'
    assert item['size'] == path.stat().st_size, f'size mismatch: {name}'
    names.append(name)
assert names, 'plugin release has no artifacts'
print(arch)
for name in names:
    print(name)
PYPREL
  ) || die 'invalid plugin-release metadata'
  architecture=$(printf '%s\n' "$release_meta" | sed -n '1p')
  while IFS= read -r name; do [[ -n "$name" ]] || continue; new_names+=("$name"); done < <(
    printf '%s\n' "$release_meta" | sed -n '2,$p'
  )
else
  die 'packages directory is missing manifest.json or plugin-release.json'
fi
[[ ${#new_names[@]} -ge 1 ]] || die 'feed requires validated NetFleet APK artifacts'

keys_dir="$work/keys"
mkdir -p "$keys_dir"
for search_dir in "$packages" "${merge_feed:-}" "$(dirname "$sign_key")"; do
  [[ -n "$search_dir" && -d "$search_dir" ]] || continue
  for pem in "$search_dir"/*.pem; do
    [[ -f "$pem" ]] || continue
    if grep -q -- 'BEGIN PUBLIC KEY' "$pem" 2>/dev/null; then
      cp "$pem" "$keys_dir/$(basename "$pem")"
    fi
  done
done
if ! find "$keys_dir" -maxdepth 1 -type f -name '*.pem' | grep -q . && command -v openssl >/dev/null 2>&1; then
  openssl ec -in "$sign_key" -pubout >"$keys_dir/opl-netfleet-apk.pem" 2>/dev/null || rm -f "$keys_dir/opl-netfleet-apk.pem"
fi

artifacts=()
if [[ -n "$merge_feed" ]]; then
  base_apks=()
  while IFS= read -r apk_path; do [[ -n "$apk_path" ]] || continue; base_apks+=("$apk_path"); done < <(
    find "$merge_feed" -maxdepth 1 -type f -name '*.apk' | sort
  )
  [[ ${#base_apks[@]} -gt 0 ]] || die 'merge feed contains no APK packages'
  new_paths=()
  for name in "${new_names[@]}"; do new_paths+=("$packages/$name"); done
  "$apk_tool" verify --keys-dir "$keys_dir" "${base_apks[@]}" || die 'merge feed signature verification failed'
  "$apk_tool" verify --keys-dir "$keys_dir" "${new_paths[@]}" || die 'new package signature verification failed'
  merged_sources=$(python3 - "$apk_tool" "$packages" "${new_names[@]}" -- "${base_apks[@]}" <<'PYMERGE'
import json, subprocess, sys
from pathlib import Path

apk_tool = sys.argv[1]
pkg_dir = Path(sys.argv[2])
sep = sys.argv.index('--', 3)
new_names = sys.argv[3:sep]
base_apks = [Path(p) for p in sys.argv[sep + 1:]]

def pkg_name(path: Path) -> str:
    raw = subprocess.check_output([apk_tool, 'adbdump', '--format', 'json', str(path)], text=True)
    return json.loads(raw)['info']['name']

merged = {}
for base in base_apks:
    name = pkg_name(base)
    if name in merged:
        raise SystemExit(f'duplicate package in merge feed: {name}')
    merged[name] = base
seen_new = set()
for fname in new_names:
    path = pkg_dir / fname
    name = pkg_name(path)
    if name in seen_new:
        raise SystemExit(f'duplicate package in candidate set: {name}')
    seen_new.add(name)
    merged[name] = path
for name in sorted(merged):
    print(merged[name])
PYMERGE
  ) || die 'failed to merge feed packages'
  rm -f "$output"/*.apk
  while IFS= read -r src_apk; do
    [[ -n "$src_apk" ]] || continue
    dst_apk="$output/$(basename "$src_apk")"
    cp "$src_apk" "$dst_apk"
    artifacts+=("$dst_apk")
  done <<< "$merged_sources"
else
  [[ ${#new_names[@]} -ge 2 ]] || die 'feed requires validated NetFleet APK artifacts'
  for name in "${new_names[@]}"; do
    artifacts+=("$output/$name")
    cp "$packages/$name" "$output/"
  done
fi
"$apk_tool" mkndx --root "$output" --keys-dir "$(dirname "$sign_key")" --allow-untrusted \
  --output "$output/packages.adb" --sign "$sign_key" \
  "${artifacts[@]}"
[[ -s "$output/packages.adb" ]] || die 'generated feed index is empty'
python3 "$repo_dir/scripts/openwrt-feed-metadata.py" --apk "$apk_tool" \
  --index "$output/packages.adb" --architecture "$architecture" --output "$output/index.json"
chmod 0644 "$output"/*.apk "$output/packages.adb"
printf '%s\n' "$output/packages.adb"
