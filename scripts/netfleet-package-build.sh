#!/usr/bin/env bash
set -euo pipefail
usage() { printf '%s\n' 'Usage: scripts/netfleet-package-build.sh --sdk <openwrt-sdk> [--ref <git-ref>] [--output <dir>] [--apk-private-key <pem>] [--bundle-sign-key <pem>] [--mihomo-asset <tar.gz>] [--preflight] [--jobs <1..16>] [--core-only --core-arch <architecture>]'; }
die() { printf 'netfleet-package-build: %s\n' "$1" >&2; exit 1; }
sdk=''; ref='HEAD'; output=''; apk_private_key=''; bundle_sign_key=''; mihomo_asset=''; preflight=0; jobs=4; core_only=0; core_package_arch=''; skip_ipk=0
SECONDS=0
while (($#)); do
  case "$1" in
    --sdk) (($# >= 2)) || die '--sdk requires a path'; sdk=$2; shift 2;;
    --ref) (($# >= 2)) || die '--ref requires a ref'; ref=$2; shift 2;;
    --output) (($# >= 2)) || die '--output requires a directory'; output=$2; shift 2;;
    --apk-private-key) (($# >= 2)) || die '--apk-private-key requires a path'; apk_private_key=$2; shift 2;;
    --bundle-sign-key) (($# >= 2)) || die '--bundle-sign-key requires a path'; bundle_sign_key=$2; shift 2;;
    --mihomo-asset) (($# >= 2)) || die '--mihomo-asset requires a file'; mihomo_asset=$2; shift 2;;
    --skip-ipk) skip_ipk=1; shift;;
    --preflight) preflight=1; shift;;
    --core-only) core_only=1; shift;;
    --core-arch) (($# >= 2)) || die '--core-arch requires an architecture'; core_package_arch=$2; shift 2;;
    --jobs) (($# >= 2)) || die '--jobs requires a count'; jobs=$2; shift 2;;
    -h|--help) usage; exit 0;;
    *) die "unknown option: $1";;
  esac
done
[[ "$jobs" =~ ^([1-9]|1[0-6])$ ]] || die '--jobs must be an integer from 1 to 16'
[[ -z "$core_package_arch" || "$core_only" == 1 ]] || die '--core-arch requires --core-only'
[[ -n "$sdk" ]] || die 'OpenWrt SDK is required; no package was fabricated'
sdk=$(cd "$sdk" 2>/dev/null && pwd) || die 'SDK is unavailable'
[[ -f "$sdk/Makefile" ]] || die "not an OpenWrt SDK: $sdk"
if [[ -n "$apk_private_key" ]]; then
  apk_private_key=$(cd "$(dirname "$apk_private_key")" 2>/dev/null && pwd)/$(basename "$apk_private_key") || die 'APK private key is unavailable'
  [[ -f "$apk_private_key" ]] || die 'APK private key is unavailable'
  [[ -x "$sdk/staging_dir/host/bin/openssl" ]] || die 'SDK host openssl is unavailable'
fi
if [[ -z "$bundle_sign_key" && -n "${NETFLEET_BUNDLE_SIGN_KEY:-}" ]]; then
  bundle_sign_key=$NETFLEET_BUNDLE_SIGN_KEY
fi
if [[ -z "$bundle_sign_key" && -f "$HOME/.config/opl-netfleet/keys/netfleet-ed25519-private.pem" ]]; then
  bundle_sign_key="$HOME/.config/opl-netfleet/keys/netfleet-ed25519-private.pem"
fi
if [[ -n "$bundle_sign_key" ]]; then
  bundle_sign_key=$(cd "$(dirname "$bundle_sign_key")" 2>/dev/null && pwd)/$(basename "$bundle_sign_key") || die 'bundle signing key is unavailable'
  [[ -f "$bundle_sign_key" ]] || die 'bundle signing key is unavailable'
fi
if [[ -n "$mihomo_asset" ]]; then
  mihomo_asset=$(cd "$(dirname "$mihomo_asset")" 2>/dev/null && pwd)/$(basename "$mihomo_asset") || die 'mihomo asset is unavailable'
  [[ -f "$mihomo_asset" ]] || die 'mihomo asset is unavailable'
fi

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
commit=$(git -C "$repo_dir" rev-parse --verify "${ref}^{commit}") || die "ref does not resolve: $ref"
tree=$(git -C "$repo_dir" rev-parse "${commit}^{tree}")

# Resolve the immutable source before touching the shared SDK or signing keys.
if [[ "$(uname -s)" != Linux || "$(uname -m)" != x86_64 ]]; then
  command -v docker >/dev/null 2>&1 || die 'the Linux x86_64 SDK requires Docker on this host'
  builder_image=${NETFLEET_SDK_IMAGE:-opl-netfleet-openwrt-sdk-builder:latest}
  [[ -n "$output" ]] || output="${XDG_CACHE_HOME:-$HOME/.cache}/opl-netfleet/packages/$commit-$tree"
  mkdir -p "$output"
  output=$(cd "$output" && pwd)
  [[ -e "$output.build-timings.json" ]] || : >"$output.build-timings.json"
  chmod 0600 "$output.build-timings.json"
  common=$(git -C "$repo_dir" rev-parse --path-format=absolute --git-common-dir)
  container_args=(run --pull=never --rm --user 0:0 --platform linux/amd64
    -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e "GIT_CONFIG_VALUE_0=$repo_dir"
    -v "$repo_dir:$repo_dir:ro" -v "$common:$common:ro"
    -v "$sdk:$sdk" -v "$output:$output"
    -v "$output.build-timings.json:$output.build-timings.json" -w "$repo_dir")
  if [[ -z "$mihomo_asset" ]]; then
    core_fname=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["filename"])' "$repo_dir/openwrt/mihomo-meta/source.json")
    cached_core="${XDG_CACHE_HOME:-$HOME/.cache}/opl-netfleet/openwrt-vm/$core_fname"
    [[ ! -f "$cached_core" ]] || mihomo_asset=$cached_core
  fi
  build_args=(--sdk "$sdk" --ref "$commit" --output "$output" --jobs "$jobs")
  [[ "$skip_ipk" == 0 ]] || build_args+=(--skip-ipk)
  [[ "$preflight" == 0 ]] || build_args+=(--preflight)
  [[ "$core_only" == 0 ]] || build_args+=(--core-only)
  [[ -z "$core_package_arch" ]] || build_args+=(--core-arch "$core_package_arch")
  if [[ -n "$apk_private_key" ]]; then
    container_args+=(-v "$apk_private_key:$apk_private_key:ro")
    build_args+=(--apk-private-key "$apk_private_key")
  fi
  if [[ -n "$bundle_sign_key" ]]; then
    container_args+=(-v "$bundle_sign_key:$bundle_sign_key:ro")
    build_args+=(--bundle-sign-key "$bundle_sign_key")
  fi
  if [[ -n "$mihomo_asset" ]]; then
    container_args+=(-v "$mihomo_asset:$mihomo_asset:ro")
    build_args+=(--mihomo-asset "$mihomo_asset")
  fi
  docker "${container_args[@]}" "$builder_image" bash "$repo_dir/scripts/netfleet-package-build.sh" "${build_args[@]}"
  exit 0
fi

make_bin=${MAKE:-make}
command -v "$make_bin" >/dev/null 2>&1 || die "GNU Make is unavailable: $make_bin"
make_version=$("$make_bin" --version | sed -n '1p')
[[ "$make_version" == 'GNU Make '* ]] || die "GNU Make is required: $make_bin"
make_major=${make_version#GNU Make }; make_major=${make_major%%.*}
[[ "$make_major" =~ ^[0-9]+$ && "$make_major" -ge 4 ]] || die "GNU Make 4 or newer is required: $make_version"
for tool in git python3 tar flock; do command -v "$tool" >/dev/null || die "missing build tool: $tool"; done
if [[ -n "$apk_private_key" ]]; then
  "$sdk/staging_dir/host/bin/openssl" version >/dev/null 2>&1 ||
    die 'SDK host openssl cannot execute; check the SDK host architecture and loader'
fi
exec 9>"$sdk/.netfleet-build.lock"
flock -n 9 || die 'SDK is in use by another NetFleet build; reuse its result or select a separate SDK'
output_explicit=$output
work=$(mktemp -d "${TMPDIR:-/tmp}/opl-netfleet-sdk.XXXXXX")
backup=$(mktemp -d "${TMPDIR:-/tmp}/opl-netfleet-sdk-backup.XXXXXX")
staged_packages=()
variant_artifact=''
restore_sdk() {
  [[ -z "$variant_artifact" ]] || rm -f -- "$variant_artifact"
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
git -C "$repo_dir" archive "$commit" \
  LICENSE product-version.json openwrt plugins \
  scripts/install-netfleet.sh scripts/verify-native-runtime.py \
  scripts/netfleet-bundle-build.py scripts/netfleet-ipk-build.py \
  scripts/openwrt-feed-metadata.py scripts/netfleet_usign.py | tar -C "$work" -xf -
chmod -R go-w "$work/openwrt" "$work/plugins"
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

build_target_arch=''
if [[ -f "$sdk/.config" ]]; then
  build_target_arch=$(sed -n 's/^CONFIG_TARGET_ARCH_PACKAGES="\([^"]*\)"$/\1/p' "$sdk/.config" | head -1)
fi
if [[ -z "$build_target_arch" ]]; then
  build_target_arch=$("$make_bin" -s -C "$sdk" val.ARCH_PACKAGES 2>&1 | tail -1) ||
    die "failed to read SDK package architecture; SDK make rejected '$make_bin'"
fi
[[ -n "$build_target_arch" && "$build_target_arch" != *' undefined' ]] || die 'SDK package architecture is unreadable'
[[ -n "$output_explicit" ]] || output="${XDG_CACHE_HOME:-$HOME/.cache}/opl-netfleet/packages/$commit-$tree/$build_target_arch"
mkdir -p "$output"; chmod 0700 "$output"
core_lock=$work/openwrt/mihomo-meta/source.json
core_arch=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["architecture"])' "$core_lock")
core_version=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$core_lock")
[[ "$build_target_arch" == "$core_arch" ]] || die "no pinned core asset for SDK architecture: $build_target_arch"
if [[ "$core_only" == 1 ]]; then
  [[ -n "$core_package_arch" ]] || core_package_arch=$build_target_arch
  python3 - "$core_lock" "$core_package_arch" <<'PYARCH'
import json,sys
m=json.load(open(sys.argv[1]))
if sys.argv[2] not in m.get('package_architectures', [m['architecture']]):
    raise SystemExit('unsupported pinned Mihomo package architecture')
PYARCH
fi
if [[ "$preflight" == 1 ]]; then
  printf 'preflight_ok source=%s architecture=%s make=%s\n' "$commit" "$build_target_arch" "$make_version"
  exit 0
fi
[[ ! -e "$output/manifest.json" ]] || die 'candidate output already exists; verify and reuse it or choose a new directory'
if [[ "$core_only" == 1 ]]; then
  [[ -n "$apk_private_key" ]] || die 'core-only requires an APK signing key'
  grep -Eq '^CONFIG_USE_APK=y$' "$sdk/.config" || die 'core-only requires an APK SDK'
  [[ ! -e "$output/core-manifest.json" ]] || die 'core candidate already exists'
  [[ ! -e "$sdk/package/mihomo-meta" ]] || mv "$sdk/package/mihomo-meta" "$backup/mihomo-meta"
  staged_packages+=(mihomo-meta)
  cp -R "$work/openwrt/mihomo-meta" "$sdk/package/mihomo-meta"
  cp "$work/openwrt/files/usr/share/opl-netfleet/nikki/LICENSE" "$sdk/package/mihomo-meta/LICENSE"
  cp "$apk_private_key" "$sdk/private-key.pem"
  chmod 0600 "$sdk/private-key.pem"
  "$sdk/staging_dir/host/bin/openssl" ec -in "$sdk/private-key.pem" -pubout >"$sdk/public-key.pem"
  "$make_bin" -C "$sdk" package/mihomo-meta/clean V=s
  "$make_bin" -j"$jobs" -C "$sdk" package/mihomo-meta/compile NETFLEET_CORE_ARCH="$core_package_arch" NO_DEPS=1 CONFIG_AUTOREMOVE= V=s
  artifact="$sdk/bin/packages/$build_target_arch/base/mihomo-meta-${core_version}-r1.apk"
  variant_artifact=$artifact
  [[ -f "$artifact" ]] || die 'expected core architecture artifact is missing'
  cp "$artifact" "$output/$(basename "$artifact")"
  artifact="$output/$(basename "$artifact")"
  apk_tool="$sdk/staging_dir/host/bin/apk"
  "$apk_tool" adbsign --allow-untrusted --reset-signatures --sign-key "$sdk/private-key.pem" "$artifact"
  mkdir -p "$work/trusted"
  cp "$sdk/public-key.pem" "$work/trusted/opl-netfleet-apk.pem"
  cp "$sdk/public-key.pem" "$output/opl-netfleet-apk.pem"
  "$apk_tool" verify --keys-dir "$work/trusted" "$artifact"
  "$apk_tool" adbdump --format json "$artifact" >"$work/core-metadata.json"
  python3 - "$output" "$artifact" "$work/core-metadata.json" "$core_lock" "$commit" "$tree" "$core_package_arch" <<'PYCORE'
import hashlib,json,sys
from pathlib import Path
out,artifact,metadata,lock,commit,tree,arch=sys.argv[1:]
info=json.load(open(metadata))['info']; source=json.load(open(lock))
assert info['name']=='mihomo-meta' and info['version']==source['version']+'-r1' and info['arch']==arch
p=Path(artifact)
m={'schema':'opl-netfleet-core-package.v1','source_commit':commit,'source_tree':tree,
   'package':info['name'],'version':info['version'],'architecture':arch,'name':p.name,
   'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'upstream':source}
Path(out,'core-manifest.json').write_text(json.dumps(m,indent=2)+'\n')
PYCORE
  printf 'core_build_ok architecture=%s seconds=%s\n' "$core_package_arch" "$SECONDS"
  exit 0
fi

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
[[ -n "$bundle_sign_key" ]] || die 'Release Bundle requires --bundle-sign-key (Ed25519 signing key)'

stage_opl_netfleet() {
  if [[ -e "$sdk/package/opl-netfleet" ]]; then mv "$sdk/package/opl-netfleet" "$backup/opl-netfleet"; fi
  staged_packages+=(opl-netfleet)
  mkdir -p "$sdk/package/opl-netfleet"
  cp -R "$work/openwrt/Makefile" "$sdk/package/opl-netfleet/"
  cp "$work/LICENSE" "$sdk/package/opl-netfleet/LICENSE"
  cp -R "$work/openwrt/files" "$sdk/package/opl-netfleet/"
  python3 "$work/scripts/netfleet-bundle-build.py" \
    --repo "$work" --output "$output" --expanded-dir "$sdk/package/opl-netfleet/bundle-stage" \
    --version "$version" --source-commit "$commit" --source-tree "$tree" \
    --sign-key "$bundle_sign_key" >"$work/bundle-summary.json"
  cp "$output/opl-netfleet-bundle.pub" "$sdk/package/opl-netfleet/bundle.pub"
  python3 - "$sdk/package/opl-netfleet/shell.json" "$version" <<'PYSHELL'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({"schema": "opl-netfleet-shell.v1", "shell_version": sys.argv[2]}, indent=2, sort_keys=True) + "\n")
PYSHELL
}

stage_luci_app() {
  if [[ -e "$sdk/package/luci-app-netfleet" ]]; then mv "$sdk/package/luci-app-netfleet" "$backup/luci-app-netfleet"; fi
  staged_packages+=(luci-app-netfleet)
  mkdir -p "$sdk/package/luci-app-netfleet"
  cp -R "$work/openwrt/luci-app-netfleet/." "$sdk/package/luci-app-netfleet/"
}

stage_mihomo_meta() {
  if [[ -e "$sdk/package/mihomo-meta" ]]; then mv "$sdk/package/mihomo-meta" "$backup/mihomo-meta"; fi
  staged_packages+=(mihomo-meta)
  cp -R "$work/openwrt/mihomo-meta" "$sdk/package/mihomo-meta"
  cp "$work/openwrt/files/usr/share/opl-netfleet/nikki/LICENSE" "$sdk/package/mihomo-meta/LICENSE"
}

stage_opl_netfleet
stage_luci_app
stage_mihomo_meta

preflight_seconds=$SECONDS
sdk_prepare_seconds=0
rm -rf "$sdk/staging_dir/target-"*"/root-"*"/usr/share/opl-netfleet"
clean_targets=(package/opl-netfleet/clean package/luci-app-netfleet/clean)
"$make_bin" -C "$sdk" "${clean_targets[@]}" V=s
clean_seconds=$((SECONDS - preflight_seconds - sdk_prepare_seconds))
compile_targets=(package/mihomo-meta/compile package/opl-netfleet/compile package/luci-app-netfleet/compile)
"$make_bin" -j"$jobs" -C "$sdk" "${compile_targets[@]}" NO_DEPS=1 CONFIG_AUTOREMOVE= V=s

compile_seconds=$((SECONDS - preflight_seconds))
product_compile_seconds=$((compile_seconds - sdk_prepare_seconds - clean_seconds))
payload="$sdk/package/opl-netfleet/bundle-stage"
files_manifest=$output/FILES.sha256
python3 - "$payload" "$files_manifest" <<'PYFILES'
import hashlib, os, sys
from pathlib import Path
root, output = map(Path, sys.argv[1:])
with output.open('w') as stream:
    for path in sorted((p for p in root.rglob('*') if p.is_file() and not p.is_symlink()), key=lambda p: os.fsencode(str(p))):
        stream.write(f'{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.relative_to(root)}\n')
PYFILES
chmod 0644 "$files_manifest"
files_sha256=$(sha256sum "$files_manifest" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$files_manifest" | awk '{print $1}')
runtime_payload_sha256=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["runtime_payload_sha256"])' "$work/bundle-summary.json")
policy_schema=$(sed -n 's/^[[:space:]]*"schema_version"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$payload/share/defaults/policy.example.json" | head -1)
[[ "$policy_schema" =~ ^[0-9]+$ ]] || die 'policy schema is unreadable'

artifacts=()
product_packages=(opl-netfleet luci-app-netfleet)
product_versions=("$version" "$luci_version")
for package_index in "${!product_packages[@]}"; do
  package_name=${product_packages[$package_index]}
  artifact_version=${product_versions[$package_index]}
  artifact_release=$release
  if [[ "$package_name" == luci-app-netfleet ]]; then
    artifact_release=$luci_release
  fi
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

bootstrap_source=$work/scripts/install-netfleet.sh
[[ -f "$bootstrap_source" ]] || die 'feed bootstrap is missing from source'
bootstrap_target=$output/install-netfleet.sh
cp "$bootstrap_source" "$bootstrap_target"
chmod 0755 "$bootstrap_target"
bootstrap_sha256=$(sha256sum "$bootstrap_target" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$bootstrap_target" | awk '{print $1}')

public_key=''
if [[ "$package_format" == apk ]]; then
  public_key=$sdk/public-key.pem
  signed_dir=$work/signed
  trusted_dir=$work/trusted
  mkdir -p "$signed_dir" "$trusted_dir"
  final_artifacts=()
  rebuilt_product_apks=()
  for idx in "${!artifacts[@]}"; do
    artifact=${artifacts[$idx]}
    signed_artifact=$signed_dir/$(basename "$artifact")
    cp "$artifact" "$signed_artifact"
    "$sdk/staging_dir/host/bin/apk" adbsign --allow-untrusted --reset-signatures \
      --sign-key "$sdk/private-key.pem" "$signed_artifact"
    final_artifacts+=("$signed_artifact")
    if (( idx < ${#product_packages[@]} )); then
      rebuilt_product_apks+=("$signed_artifact")
    fi
  done
  cp "$public_key" "$trusted_dir/opl-netfleet-apk.pem"
  "$sdk/staging_dir/host/bin/apk" verify --keys-dir "$trusted_dir" "${final_artifacts[@]}"
  artifacts=("${final_artifacts[@]}")
  python3 "$work/scripts/verify-native-runtime.py" --apk "$sdk/staging_dir/host/bin/apk" \
    "${rebuilt_product_apks[@]}" >"$output/native-runtime.json"
fi

python3 - "$output" "$commit" "$tree" "$version" "$release" "$package_format" "$package_arch" "$build_target_arch" "$policy_schema" "$public_key" "$runtime_payload_sha256" "$files_sha256" "$bootstrap_sha256" "$core_lock" "$work/bundle-summary.json" "${artifacts[@]}" <<'PY'
import hashlib, json, re, sys
from pathlib import Path
output, commit, tree, version, release, package_format, package_arch, build_target_arch, policy_schema, public_key, runtime_payload_sha256, files_sha256, bootstrap_sha256, core_lock, bundle_summary_path, *artifacts = sys.argv[1:]
items=[]
dependencies=[]
core_source=json.loads(Path(core_lock).read_text())
bundle_summary=json.loads(Path(bundle_summary_path).read_text())
for source in artifacts:
    data=Path(source).read_bytes(); name=Path(source).name
    target=Path(output)/name; target.write_bytes(data); target.chmod(0o644)
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
manifest={
    'schema':'opl-netfleet-package-manifest.v2',
    'delivery_model':'release-bundle',
    'source_commit':commit,'source_tree':tree,'package_version':version,
    'package_format':package_format,'package_arch':package_arch,'build_target_arch':build_target_arch,
    'policy_schema':int(policy_schema),'runtime_payload_sha256':runtime_payload_sha256,
    'files_manifest':{'name':'FILES.sha256','sha256':files_sha256},
    'artifacts':items,
    'release_bundle': {
        'archive': bundle_summary['archive'],
        'archive_sha256': bundle_summary['archive_sha256'],
        'archive_size': bundle_summary['archive_size'],
        'manifest': 'release-manifest.json',
        'manifest_sha256': bundle_summary['manifest_sha256'],
        'manifest_sig': 'release-manifest.json.sig',
        'manifest_sig_sha256': bundle_summary['manifest_sig_sha256'],
        'public_key': 'opl-netfleet-bundle.pub',
    },
}
if release:
    manifest['package_release'] = release
manifest['artifact_files']={item['package']: item['name'] for item in items}
if package_format == 'apk':
    manifest['native_runtime'] = {'name':'native-runtime.json', 'sha256':hashlib.sha256((Path(output)/'native-runtime.json').read_bytes()).hexdigest()}
manifest['dependency_artifacts']=dependencies
manifest['feed_bootstrap']={'name':'install-netfleet.sh','sha256':bootstrap_sha256}
if public_key:
    key_data=Path(public_key).read_bytes(); key_name='opl-netfleet-apk.pem'
    key_target=Path(output)/key_name; key_target.write_bytes(key_data); key_target.chmod(0o644)
    manifest['apk_public_key']={'name':key_name,'sha256':hashlib.sha256(key_data).hexdigest()}
manifest_path=Path(output)/'manifest.json'; manifest_path.write_text(json.dumps(manifest,sort_keys=True,indent=2)+'\n'); manifest_path.chmod(0o644)
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
  chmod 0644 "$output/packages.adb"
  python3 "$work/scripts/openwrt-feed-metadata.py" --apk "$sdk/staging_dir/host/bin/apk" \
    --index "$output/packages.adb" --architecture "$build_target_arch" --output "$output/index.json"
  python3 - "$output/manifest.json" "$output/packages.adb" "$output/index.json" <<'PY'
import hashlib, json, sys
from pathlib import Path
manifest_path, index_path, metadata_path = map(Path, sys.argv[1:])
manifest = json.loads(manifest_path.read_text())
manifest['feed_index'] = {'name': index_path.name, 'sha256': hashlib.sha256(index_path.read_bytes()).hexdigest()}
manifest['feed_metadata'] = {'name': metadata_path.name, 'sha256': hashlib.sha256(metadata_path.read_bytes()).hexdigest()}
manifest_path.write_text(json.dumps(manifest, sort_keys=True, indent=2) + '\n')
PY
fi
if [[ "$skip_ipk" == 0 ]]; then
  ipk_args=(--repo "$work" --output "$output" --arch "$build_target_arch" --sign-key "$bundle_sign_key" --source-commit "$commit" --source-tree "$tree" --merge-manifest)
  [[ -n "$mihomo_asset" ]] && ipk_args+=(--mihomo-asset "$mihomo_asset") || ipk_args+=(--skip-core)
  python3 "$work/scripts/netfleet-ipk-build.py" "${ipk_args[@]}" >/dev/null
  chmod 0644 "$output"/manifest.json "$output"/opl-netfleet-usign.pub "$output"/Packages* "$output"/*.ipk || true
fi
python3 - "$output.build-timings.json" "$preflight_seconds" "$compile_seconds" "$sdk_prepare_seconds" "$clean_seconds" "$product_compile_seconds" "$SECONDS" <<'PYTIMING'
import json, sys
from pathlib import Path
out_file, preflight, compile_s, prepare, clean, prod_compile, total = sys.argv[1:]
Path(out_file).write_text(json.dumps({
    'preflight_seconds': int(preflight),
    'compile_seconds': int(compile_s),
    'sdk_prepare_seconds': int(prepare),
    'clean_seconds': int(clean),
    'product_compile_seconds': int(prod_compile),
    'packaging_seconds': int(total) - int(preflight) - int(compile_s),
    'total_seconds': int(total),
    'reused_packages': [],
}, sort_keys=True) + '\n')
PYTIMING
printf '%s\n' "$output/manifest.json"
