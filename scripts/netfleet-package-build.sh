#!/usr/bin/env bash
set -euo pipefail
usage() { printf '%s\n' 'Usage: scripts/netfleet-package-build.sh --sdk <openwrt-sdk> [--ref <git-ref>] [--output <dir>] [--apk-private-key <pem>]'; }
die() { printf 'netfleet-package-build: %s\n' "$1" >&2; exit 1; }
sdk=''; ref='HEAD'; output=''; apk_private_key=''
while (($#)); do
  case "$1" in
    --sdk) (($# >= 2)) || die '--sdk requires a path'; sdk=$2; shift 2;;
    --ref) (($# >= 2)) || die '--ref requires a ref'; ref=$2; shift 2;;
    --output) (($# >= 2)) || die '--output requires a directory'; output=$2; shift 2;;
    --apk-private-key) (($# >= 2)) || die '--apk-private-key requires a path'; apk_private_key=$2; shift 2;;
    -h|--help) usage; exit 0;;
    *) die "unknown option: $1";;
  esac
done
[[ -n "$sdk" ]] || die 'OpenWrt SDK is required; no package was fabricated'
sdk=$(cd "$sdk" 2>/dev/null && pwd) || die 'SDK is unavailable'
[[ -f "$sdk/Makefile" ]] || die "not an OpenWrt SDK: $sdk"
if [[ -n "$apk_private_key" ]]; then
  apk_private_key=$(cd "$(dirname "$apk_private_key")" 2>/dev/null && pwd)/$(basename "$apk_private_key") || die 'APK private key is unavailable'
  [[ -f "$apk_private_key" ]] || die 'APK private key is unavailable'
  [[ -x "$sdk/staging_dir/host/bin/openssl" ]] || die 'SDK host openssl is unavailable'
fi
repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
commit=$(git -C "$repo_dir" rev-parse --verify "${ref}^{commit}") || die "ref does not resolve: $ref"
tree=$(git -C "$repo_dir" rev-parse "$commit^{tree}")
output_explicit=$output
work=$(mktemp -d "${TMPDIR:-/tmp}/opl-netfleet-sdk.XXXXXX")
backup=$(mktemp -d "${TMPDIR:-/tmp}/opl-netfleet-sdk-backup.XXXXXX")
staged_packages=()
restore_sdk() {
  for package_name in "${staged_packages[@]}"; do
    rm -rf "$sdk/package/$package_name"
    [[ ! -e "$backup/$package_name" ]] || mv "$backup/$package_name" "$sdk/package/$package_name"
  done
  for name in .config private-key.pem public-key.pem; do
    rm -f "$sdk/$name"
    [[ ! -e "$backup/$name" ]] || mv "$backup/$name" "$sdk/$name"
  done
  rm -rf "$work" "$backup"
}
trap restore_sdk EXIT
for name in .config private-key.pem public-key.pem; do
  [[ ! -e "$sdk/$name" ]] || cp -p "$sdk/$name" "$backup/$name"
done
git -C "$repo_dir" archive "$commit" openwrt scripts/install-netfleet.sh scripts/verify-native-runtime.py | tar -C "$work" -xf -
version=$(awk -F':=' '/^PKG_VERSION[[:space:]]*:=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$work/openwrt/Makefile")
release=$(awk -F':=' '/^PKG_RELEASE[[:space:]]*:=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$work/openwrt/Makefile")
[[ -n "$version" ]] || die 'package version metadata is missing'
luci_version=$(awk -F':=' '/^PKG_VERSION[[:space:]]*:=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$work/openwrt/luci-app-netfleet/Makefile")
luci_release=$(awk -F':=' '/^PKG_RELEASE[[:space:]]*:=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$work/openwrt/luci-app-netfleet/Makefile")
[[ -n "$luci_version" ]] || die 'LuCI package version metadata is missing'
build_identity=$work/openwrt/files/usr/share/opl-netfleet/build.json
mkdir -p "$(dirname "$build_identity")"
python3 - "$build_identity" "$version" "$commit" "$tree" <<'PY'
import json, sys
from pathlib import Path

path, version, commit, tree = sys.argv[1:]
Path(path).write_text(json.dumps({
    'schema': 'opl-netfleet-package-build.v1',
    'version': version,
    'source_commit': commit,
    'source_tree': tree,
}, sort_keys=True, indent=2) + '\n')
PY
build_target_arch=$(make -s -C "$sdk" val.ARCH_PACKAGES 2>/dev/null | tail -1)
[[ -n "$build_target_arch" && "$build_target_arch" != *' undefined' ]] || die 'SDK package architecture is unreadable'
[[ -n "$output_explicit" ]] || output="${XDG_CACHE_HOME:-$HOME/.cache}/opl-netfleet/packages/$commit-$tree/$build_target_arch"
mkdir -p "$output"; chmod 0700 "$output"
core_lock=$work/openwrt/mihomo-meta/source.json
core_arch=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["architecture"])' "$core_lock")
core_version=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$core_lock")
[[ "$build_target_arch" == "$core_arch" ]] || die "no pinned core asset for SDK architecture: $build_target_arch"
for package_name in opl-netfleet luci-app-netfleet mihomo-meta; do
  if [[ -e "$sdk/package/$package_name" ]]; then mv "$sdk/package/$package_name" "$backup/$package_name"; fi
  staged_packages+=("$package_name")
done
mkdir -p "$sdk/package/opl-netfleet"
cp -R "$work/openwrt/Makefile" "$sdk/package/opl-netfleet/"
cp "$work/openwrt/plugin-packages.py" "$sdk/package/opl-netfleet/"
cp "$work/openwrt/plugin_payload.py" "$sdk/package/opl-netfleet/"
cp -R "$work/openwrt/files" "$sdk/package/opl-netfleet/"
mkdir -p "$sdk/package/luci-app-netfleet"
cp -R "$work/openwrt/luci-app-netfleet/." "$sdk/package/luci-app-netfleet/"
cp -R "$work/openwrt/mihomo-meta" "$sdk/package/mihomo-meta"
cp "$work/openwrt/files/usr/share/opl-netfleet/nikki/LICENSE" "$sdk/package/mihomo-meta/LICENSE"
package_format=ipk
package_arch=all
if grep -Eq '^CONFIG_USE_APK=y$' "$sdk/.config" 2>/dev/null; then
  package_format=apk
  package_arch=noarch
  [[ -n "$apk_private_key" ]] || die 'APK builds require --apk-private-key; unsigned release packages are not allowed'
  cp "$apk_private_key" "$sdk/private-key.pem"
  chmod 0600 "$sdk/private-key.pem"
  "$sdk/staging_dir/host/bin/openssl" ec -in "$sdk/private-key.pem" -pubout >"$sdk/public-key.pem"
fi
make -C "$sdk" package/opl-netfleet/clean package/luci-app-netfleet/clean V=s
# These payloads use the prepared SDK tools, not compiled dependency libraries.
# Keep runtime APK dependencies, but do not rebuild the SDK's entire kmod set.
make -C "$sdk" package/mihomo-meta/compile package/opl-netfleet/compile package/luci-app-netfleet/compile NO_DEPS=1 V=s

payload=$work/payload
mkdir -p "$payload/usr/libexec" "$payload/usr/libexec/rpcd" \
  "$payload/etc/opl-netfleet" "$payload/etc/init.d" "$payload/www" \
  "$payload/usr/share/luci" "$payload/usr/share/rpcd" "$payload/usr/share/opl-netfleet"
cp -R "$work/openwrt/files/usr/libexec/opl-netfleet" "$payload/usr/libexec/"
cp "$work/openwrt/files/usr/libexec/opl-netfleet-transfer" "$payload/usr/libexec/"
cp "$work/openwrt/files/usr/libexec/opl-netfleet-plugin-package" "$payload/usr/libexec/"
cp "$work/openwrt/files/usr/libexec/rpcd/opl-netfleet" "$payload/usr/libexec/rpcd/opl-netfleet"
cp "$work/openwrt/files/usr/libexec/rpcd/opl-netfleet.plugins" "$payload/usr/libexec/rpcd/opl-netfleet.plugins"
cp "$work/openwrt/files/etc/init.d/opl-netfleet" "$payload/etc/init.d/opl-netfleet"
cp "$work/openwrt/files/etc/init.d/opl-netfleet-core" "$payload/etc/init.d/opl-netfleet-core"
cp "$work/openwrt/files/etc/init.d/opl-netfleet-update-recovery" "$payload/etc/init.d/opl-netfleet-update-recovery"
cp -R "$work/openwrt/files/usr/share/opl-netfleet/." "$payload/usr/share/opl-netfleet/"
cp "$work/openwrt/files/etc/config/netfleet" "$payload/usr/share/opl-netfleet/netfleet.config"
cp -R "$work/openwrt/files/etc/opl-netfleet/." "$payload/etc/opl-netfleet/"
cp "$build_identity" "$payload/usr/share/opl-netfleet/build.json"
cp -R "$work/openwrt/luci-app-netfleet/htdocs/." "$payload/www/"
find "$payload/www" -type f -name '*.d.ts' -delete
for plugin_dir in "$work/openwrt/files/usr/libexec/opl-netfleet/plugins/"*; do
  python3 "$work/openwrt/plugin_payload.py" project "$plugin_dir" "$payload/www"
done
cp -R "$work/openwrt/luci-app-netfleet/root/." "$payload/"
view_version="v${luci_version//./_}"
sh "$work/openwrt/luci-app-netfleet/stage-assets.sh" \
  "$payload/www/luci-static/resources" "$view_version"
grep -Fq "\"path\": \"netfleet/overview-${view_version}\"" \
  "$payload/usr/share/luci/menu.d/luci-app-netfleet.json" ||
  die "LuCI menu view does not match package version: $luci_version"
find "$payload" -type f -exec chmod 0644 {} +
chmod 0755 "$payload/usr/libexec/opl-netfleet/main.uc" \
	"$payload/usr/libexec/opl-netfleet-transfer" \
	"$payload/usr/libexec/opl-netfleet-plugin-package" \
  "$payload/usr/libexec/opl-netfleet/supervisor.uc" \
  "$payload/usr/libexec/rpcd/opl-netfleet" "$payload/usr/libexec/rpcd/opl-netfleet.plugins" \
  "$payload/etc/init.d/opl-netfleet" "$payload/etc/init.d/opl-netfleet-core" "$payload/etc/init.d/opl-netfleet-update-recovery"
files_manifest=$output/FILES.sha256
: >"$files_manifest"
while IFS= read -r path; do
  relative=${path#"$payload"/}
  printf '%s  %s\n' "$(sha256sum "$path" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$path" | awk '{print $1}')" "$relative" >>"$files_manifest"
done < <(find "$payload" -type f | LC_ALL=C sort)
runtime_files_manifest=$work/RUNTIME_FILES.sha256
: >"$runtime_files_manifest"
while read -r expected path extra; do
  [[ -n "$expected" ]] || continue
  [[ -z "${extra:-}" ]] || die "invalid payload manifest entry: $path"
  case "$path" in
    www/luci-static/resources/netfleet/*|www/luci-static/resources/view/netfleet/*|usr/share/luci/menu.d/luci-app-netfleet.json|usr/share/rpcd/acl.d/luci-app-netfleet.json) continue ;;
  esac
  printf '%s  %s\n' "$expected" "$path" >>"$runtime_files_manifest"
done <"$files_manifest"
chmod 0600 "$files_manifest"
files_sha256=$(sha256sum "$files_manifest" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$files_manifest" | awk '{print $1}')
runtime_payload_sha256=$(sha256sum "$runtime_files_manifest" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$runtime_files_manifest" | awk '{print $1}')
policy_schema=$(sed -n 's/^[[:space:]]*"schema_version"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$payload/etc/opl-netfleet/policy.example.json" | head -1)
[[ "$policy_schema" =~ ^[0-9]+$ ]] || die 'policy schema is unreadable'
artifacts=()
product_packages=(opl-netfleet opl-netfleet-kernel luci-app-netfleet)
while IFS= read -r package_name; do product_packages+=("$package_name"); done < <(
  python3 - "$work/openwrt/files/usr/libexec/opl-netfleet/plugins" <<'PY'
import json, sys
from pathlib import Path
for path in sorted(Path(sys.argv[1]).glob('*/manifest.json')):
    manifest = json.loads(path.read_text())
    if manifest['schema'] != 'opl-netfleet-service-plugin.v1':
        raise SystemExit(f'unsupported built-in plugin manifest: {path}')
    print(manifest['package'])
PY
)
for package_name in "${product_packages[@]}"; do
  artifact_version=$version
  artifact_release=$release
  if [[ "$package_name" == luci-app-netfleet ]]; then
    artifact_version=$luci_version
    artifact_release=$luci_release
  fi
  if [[ "$package_name" == opl-netfleet-plugin-* ]]; then
    artifact_version=$(python3 "$work/openwrt/plugin-packages.py" version "${package_name#opl-netfleet-plugin-}")
  fi
  # Only archived sources have a separate OpenWrt package revision.
  [[ -z "$artifact_release" ]] || artifact_version+="-r${artifact_release}"
  if [[ "$package_format" == apk ]]; then
    artifact_pattern="${package_name}-${artifact_version}.apk"
  else
    artifact_pattern="${package_name}_${artifact_version}_all.ipk"
  fi
  package_artifacts=()
  while IFS= read -r file; do package_artifacts+=("$file"); done < <(find "$sdk/bin/packages" -type f -name "$artifact_pattern" -print | sort)
  [[ ${#package_artifacts[@]} -eq 1 ]] || die "expected exactly one $package_name artifact, found ${#package_artifacts[@]}"
  artifacts+=("${package_artifacts[0]}")
done
if [[ "$package_format" == apk ]]; then
  core_pattern="mihomo-meta-${core_version}-r1.apk"
else
  core_pattern="mihomo-meta_${core_version}-r1_${build_target_arch}.ipk"
fi
core_artifacts=()
while IFS= read -r file; do core_artifacts+=("$file"); done < <(find "$sdk/bin/packages" -type f -name "$core_pattern" -print | sort)
[[ ${#core_artifacts[@]} -eq 1 ]] || die 'expected exactly one pinned Mihomo dependency package'
artifacts+=("${core_artifacts[0]}")
bootstrap_sha256=''
public_key=''
if [[ "$package_format" == apk ]]; then
	bootstrap_source=$work/scripts/install-netfleet.sh
	[[ -f "$bootstrap_source" ]] || die 'feed bootstrap is missing from source'
	bootstrap_target=$output/install-netfleet.sh
	cp "$bootstrap_source" "$bootstrap_target"
	chmod 0755 "$bootstrap_target"
	bootstrap_sha256=$(sha256sum "$bootstrap_target" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$bootstrap_target" | awk '{print $1}')
  public_key=$sdk/public-key.pem
  signed_dir=$work/signed
  trusted_dir=$work/trusted
  mkdir -p "$signed_dir" "$trusted_dir"
  signed_artifacts=()
  for artifact in "${artifacts[@]}"; do
    signed_artifact=$signed_dir/$(basename "$artifact")
    cp "$artifact" "$signed_artifact"
    "$sdk/staging_dir/host/bin/apk" adbsign --allow-untrusted --reset-signatures \
      --sign-key "$sdk/private-key.pem" "$signed_artifact"
    signed_artifacts+=("$signed_artifact")
  done
  cp "$public_key" "$trusted_dir/opl-netfleet-apk.pem"
  "$sdk/staging_dir/host/bin/apk" verify --keys-dir "$trusted_dir" "${signed_artifacts[@]}"
  artifacts=("${signed_artifacts[@]}")
  python3 "$work/scripts/verify-native-runtime.py" --apk "$sdk/staging_dir/host/bin/apk" "${artifacts[@]:0:${#product_packages[@]}}" >"$output/native-runtime.json"
fi
python3 - "$output" "$commit" "$tree" "$version" "$release" "$package_format" "$package_arch" "$build_target_arch" "$policy_schema" "$public_key" "$runtime_payload_sha256" "$files_sha256" "$bootstrap_sha256" "$core_lock" "${artifacts[@]}" <<'PY'
import hashlib, json, re, sys
from pathlib import Path
output, commit, tree, version, release, package_format, package_arch, build_target_arch, policy_schema, public_key, runtime_payload_sha256, files_sha256, bootstrap_sha256, core_lock, *artifacts = sys.argv[1:]
items=[]
dependencies=[]
core_source=json.loads(Path(core_lock).read_text())
for source in artifacts:
    data=Path(source).read_bytes(); name=Path(source).name
    target=Path(output)/name; target.write_bytes(data); target.chmod(0o600)
    pattern = r'(.+)-(\d+\.\d+\.\d+)(?:-r(\d+))?\.apk' if package_format == 'apk' else r'(.+)_(\d+\.\d+\.\d+)(?:-r(\d+))?_[A-Za-z0-9_]+\.ipk'
    identity = re.fullmatch(pattern, name)
    if identity is None:
        raise SystemExit(f'unrecognized package artifact: {name}')
    package_name, artifact_version, artifact_release = identity.groups()
    item={'package':package_name,'name':name,'sha256':hashlib.sha256(data).hexdigest(),'size':len(data)}
    if package_name == 'mihomo-meta':
        item.update({'package_arch':build_target_arch, 'version':core_source['version'], 'upstream':core_source})
        dependencies.append(item)
    else:
        item.update({'version': artifact_version})
        if artifact_release is not None:
            item['release'] = artifact_release
        items.append(item)
manifest={'schema':'opl-netfleet-package-manifest.v2','source_commit':commit,'source_tree':tree,'package_version':version,'package_format':package_format,'package_arch':package_arch,'build_target_arch':build_target_arch,'policy_schema':int(policy_schema),'runtime_payload_sha256':runtime_payload_sha256,'files_manifest':{'name':'FILES.sha256','sha256':files_sha256},'artifacts':items}
if release:
    manifest['package_release'] = release
manifest['artifact_files']={item['package']: item['name'] for item in items}
if package_format == 'apk':
    manifest['native_runtime'] = {'name':'native-runtime.json', 'sha256':hashlib.sha256((Path(output)/'native-runtime.json').read_bytes()).hexdigest()}
manifest['dependency_artifacts']=dependencies
if bootstrap_sha256:
    manifest['feed_bootstrap']={'name':'install-netfleet.sh','sha256':bootstrap_sha256}
if public_key:
    key_data=Path(public_key).read_bytes(); key_name='opl-netfleet-apk.pem'
    key_target=Path(output)/key_name; key_target.write_bytes(key_data); key_target.chmod(0o600)
    manifest['apk_public_key']={'name':key_name,'sha256':hashlib.sha256(key_data).hexdigest()}
manifest_path=Path(output)/'manifest.json'; manifest_path.write_text(json.dumps(manifest,sort_keys=True,indent=2)+'\n'); manifest_path.chmod(0o600)
PY
if [[ "$package_format" == apk ]]; then
  package_files=()
  for artifact in "${artifacts[@]}"; do package_files+=("$output/$(basename "$artifact")"); done
  "$sdk/staging_dir/host/bin/apk" mkndx \
    --root "$sdk" \
    --keys-dir "$sdk" \
    --allow-untrusted \
    --output "$output/packages.adb" \
    --sign "$sdk/private-key.pem" \
    "${package_files[@]}"
  [[ -s "$output/packages.adb" ]] || die 'APK feed index is empty'
  chmod 0600 "$output/packages.adb"
  python3 - "$output/manifest.json" "$output/packages.adb" <<'PY'
import hashlib, json, sys
from pathlib import Path
manifest_path, index_path = map(Path, sys.argv[1:])
manifest = json.loads(manifest_path.read_text())
manifest['feed_index'] = {'name': index_path.name, 'sha256': hashlib.sha256(index_path.read_bytes()).hexdigest()}
manifest_path.write_text(json.dumps(manifest, sort_keys=True, indent=2) + '\n')
PY
fi
printf '%s\n' "$output/manifest.json"
