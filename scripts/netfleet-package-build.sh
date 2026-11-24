#!/usr/bin/env bash
set -euo pipefail
usage() { printf '%s\n' 'Usage: scripts/netfleet-package-build.sh --sdk <openwrt-sdk> [--ref <git-ref>] [--output <dir>] [--apk-private-key <pem>] [--reuse-feed <dir>] [--plugins <id1,id2,...>] [--preflight] [--jobs <1..16>] [--core-only --core-arch <architecture>]'; }
die() { printf 'netfleet-package-build: %s\n' "$1" >&2; exit 1; }
sdk=''; ref='HEAD'; output=''; apk_private_key=''; preflight=0; jobs=4; core_only=0; core_package_arch=''; reuse_feed=''; plugins_filter=''
SECONDS=0
while (($#)); do
  case "$1" in
    --sdk) (($# >= 2)) || die '--sdk requires a path'; sdk=$2; shift 2;;
    --ref) (($# >= 2)) || die '--ref requires a ref'; ref=$2; shift 2;;
    --output) (($# >= 2)) || die '--output requires a directory'; output=$2; shift 2;;
    --apk-private-key) (($# >= 2)) || die '--apk-private-key requires a path'; apk_private_key=$2; shift 2;;
    --reuse-feed) (($# >= 2)) || die '--reuse-feed requires a directory'; reuse_feed=$2; shift 2;;
    --plugins) (($# >= 2)) || die '--plugins requires a comma-separated list'; plugins_filter=$2; shift 2;;
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
[[ -z "$plugins_filter" || -n "$reuse_feed" ]] || die '--plugins requires --reuse-feed'
[[ -z "$plugins_filter" || "$core_only" == 0 ]] || die '--plugins cannot be combined with --core-only'
[[ -z "$reuse_feed" || "$core_only" == 0 ]] || die '--reuse-feed cannot be combined with --core-only'
[[ -n "$sdk" ]] || die 'OpenWrt SDK is required; no package was fabricated'
sdk=$(cd "$sdk" 2>/dev/null && pwd) || die 'SDK is unavailable'
[[ -f "$sdk/Makefile" ]] || die "not an OpenWrt SDK: $sdk"
if [[ -n "$reuse_feed" ]]; then
  reuse_feed=$(cd "$reuse_feed" 2>/dev/null && pwd) || die 'reuse feed directory is unavailable'
  [[ -f "$reuse_feed/manifest.json" ]] || die 'reuse feed manifest is missing'
fi
if [[ -n "$apk_private_key" ]]; then
  apk_private_key=$(cd "$(dirname "$apk_private_key")" 2>/dev/null && pwd)/$(basename "$apk_private_key") || die 'APK private key is unavailable'
  [[ -f "$apk_private_key" ]] || die 'APK private key is unavailable'
  [[ -x "$sdk/staging_dir/host/bin/openssl" ]] || die 'SDK host openssl is unavailable'
fi
repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
commit=$(git -C "$repo_dir" rev-parse --verify "${ref}^{commit}") || die "ref does not resolve: $ref"
tree=$(git -C "$repo_dir" rev-parse "$commit^{tree}")
if [[ -n "$plugins_filter" ]]; then
  [[ "$plugins_filter" =~ ^[a-z0-9-]+(,[a-z0-9-]+)*$ ]] || die '--plugins must contain comma-separated plugin IDs or luci'
  [[ -n "$apk_private_key" ]] || die '--plugins builds require --apk-private-key'
  plugins_filter=$(python3 - "$repo_dir" "$commit" "$plugins_filter" <<'PYPLUGINS'
import json, subprocess, sys
repo, commit, raw = sys.argv[1:]
seen, ordered = set(), []
for token in raw.split(','):
    if token in seen:
        continue
    seen.add(token)
    if token != 'luci':
        data = subprocess.check_output(['git', '-C', repo, 'show', f'{commit}:plugins/{token}/manifest.json'], text=True)
        manifest = json.loads(data)
        if manifest.get('schema') != 'opl-netfleet-service-plugin.v1':
            raise SystemExit(f'unsupported plugin schema: {token}')
    ordered.append(token)
print(','.join(ordered))
PYPLUGINS
  ) || die 'invalid plugin identifier in --plugins'
fi
# Resolve the immutable source before touching the shared SDK or signing keys.
if [[ "$(uname -s)" != Linux || "$(uname -m)" != x86_64 ]]; then
  command -v docker >/dev/null 2>&1 || die 'the Linux x86_64 SDK requires Docker on this host'
  builder_image=${NETFLEET_SDK_IMAGE:-opl-netfleet-openwrt-sdk-builder:latest}
  [[ -n "$output" ]] || output="${XDG_CACHE_HOME:-$HOME/.cache}/opl-netfleet/packages/$commit-$tree"
  mkdir -p "$output"
  output=$(cd "$output" && pwd)
  # Keep timing evidence outside the immutable release, but mounted past --rm.
  [[ -e "$output.build-timings.json" ]] || : >"$output.build-timings.json"
  chmod 0600 "$output.build-timings.json"
  common=$(git -C "$repo_dir" rev-parse --path-format=absolute --git-common-dir)
  container_args=(run --pull=never --rm --user 0:0 --platform linux/amd64
    -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e "GIT_CONFIG_VALUE_0=$repo_dir"
    -v "$repo_dir:$repo_dir:ro" -v "$common:$common:ro"
    -v "$sdk:$sdk" -v "$output:$output"
    -v "$output.build-timings.json:$output.build-timings.json" -w "$repo_dir")
  build_args=(--sdk "$sdk" --ref "$commit" --output "$output" --jobs "$jobs")
  [[ "$preflight" == 0 ]] || build_args+=(--preflight)
  [[ "$core_only" == 0 ]] || build_args+=(--core-only)
  [[ -z "$core_package_arch" ]] || build_args+=(--core-arch "$core_package_arch")
  if [[ -n "$reuse_feed" ]]; then
    container_args+=(-v "$reuse_feed:$reuse_feed:ro")
    build_args+=(--reuse-feed "$reuse_feed")
  fi
  if [[ -n "$plugins_filter" ]]; then
    build_args+=(--plugins "$plugins_filter")
  fi
  if [[ -n "$apk_private_key" ]]; then
    container_args+=(-v "$apk_private_key:$apk_private_key:ro")
    build_args+=(--apk-private-key "$apk_private_key")
  fi
  exec docker "${container_args[@]}" "$builder_image" bash "$repo_dir/scripts/netfleet-package-build.sh" "${build_args[@]}"
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
git -C "$repo_dir" archive "$commit" LICENSE openwrt plugins scripts/install-netfleet.sh scripts/verify-native-runtime.py | tar -C "$work" -xf -
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
if [[ -n "$plugins_filter" ]]; then
  [[ ! -e "$output/plugin-release.json" ]] || die 'incremental plugin candidate already exists; verify and reuse it or choose a new directory'
fi
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
if [[ -n "$reuse_feed" && "$package_format" != apk ]]; then
  die '--reuse-feed requires an APK SDK'
fi
if [[ -n "$plugins_filter" && "$package_format" != apk ]]; then
  die '--plugins requires an APK SDK'
fi

stage_opl_netfleet() {
  if [[ -e "$sdk/package/opl-netfleet" ]]; then mv "$sdk/package/opl-netfleet" "$backup/opl-netfleet"; fi
  staged_packages+=(opl-netfleet)
  mkdir -p "$sdk/package/opl-netfleet"
  cp -R "$work/openwrt/Makefile" "$sdk/package/opl-netfleet/"
  cp "$work/openwrt/plugin-packages.py" "$sdk/package/opl-netfleet/"
  cp "$work/openwrt/plugin_payload.py" "$sdk/package/opl-netfleet/"
  cp "$work/openwrt/compile-plugins.py" "$sdk/package/opl-netfleet/"
  cp "$work/LICENSE" "$sdk/package/opl-netfleet/LICENSE"
  cp -R "$work/openwrt/files" "$sdk/package/opl-netfleet/"
  mkdir -p "$sdk/package/opl-netfleet/plugins"
  python3 - "$work/plugins" "$sdk/package/opl-netfleet/plugins" <<'PY'
import json, shutil, sys
from pathlib import Path
src, dst = Path(sys.argv[1]), Path(sys.argv[2])
for manifest_path in sorted(src.glob('*/manifest.json')):
    manifest = json.loads(manifest_path.read_text())
    if manifest.get('schema') == 'opl-netfleet-service-plugin.v1':
        shutil.copytree(manifest_path.parent, dst / manifest_path.parent.name)
PY
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

prepare_ucode_host() {
  (cd "$sdk" && ./scripts/feeds update base && ./scripts/feeds install -p base ucode)
  "$make_bin" -C "$sdk" package/feeds/base/ucode/host/compile V=s
  # SDK hostpkg tools may retain an absolute RPATH from a previous build location.
  # Keep resolution local to this SDK instead of relying on the host's libraries.
  export LD_LIBRARY_PATH="$sdk/staging_dir/hostpkg/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  "$sdk/staging_dir/hostpkg/bin/ucode" -L "$sdk/staging_dir/hostpkg/lib/ucode/*.so" \
    -e "import * as fs from 'fs'; import * as socket from 'socket'; print('sdk_ucode_ready\\n');" ||
    die 'SDK UCode compiler or fs/socket modules cannot execute after preparation'
}

if [[ -n "$reuse_feed" ]]; then
  mkdir -p "$work/trusted"
  cp "$sdk/public-key.pem" "$work/trusted/opl-netfleet-apk.pem"
  python3 - "$repo_dir" "$reuse_feed" "$commit" "$build_target_arch" "$version" "$release" "$luci_version" "$luci_release" "$core_lock" "$plugins_filter" "$work/reuse-plan.json" <<'PYREUSE'
import hashlib, json, subprocess, sys
from pathlib import Path

repo_dir, reuse_dir, commit, arch, version, release, luci_version, luci_release, core_lock, plugins_filter, out_path = sys.argv[1:]
reuse_root = Path(reuse_dir)
prev_manifest = json.loads((reuse_root / 'manifest.json').read_text())
if prev_manifest.get('schema') != 'opl-netfleet-package-manifest.v2':
    raise SystemExit('reuse feed manifest schema is unsupported')
if prev_manifest.get('package_format') != 'apk' or prev_manifest.get('build_target_arch') != arch:
    raise SystemExit('reuse feed format or architecture mismatches SDK')
prev_commit = prev_manifest.get('source_commit', '')
subprocess.run(['git', '-C', repo_dir, 'cat-file', '-e', f'{prev_commit}^{{commit}}'], check=True)
nr_meta = prev_manifest.get('native_runtime') or {}
nr_path = reuse_root / nr_meta.get('name', 'native-runtime.json')
if not nr_path.is_file() or hashlib.sha256(nr_path.read_bytes()).hexdigest() != nr_meta.get('sha256'):
    raise SystemExit('reuse feed native-runtime receipt mismatches manifest')
prev_nr_data = json.loads(nr_path.read_text())
if prev_nr_data.get('ok') is not True:
    raise SystemExit('reuse feed native-runtime receipt is not ok')
prev_nr = {item['package']: item for item in prev_nr_data.get('packages', [])}
prev_artifacts = {item['package']: item for item in prev_manifest.get('artifacts', [])}
prev_deps = {item['package']: item for item in prev_manifest.get('dependency_artifacts', [])}

extra_plugin_files = {
    'platform-openwrt': ['openwrt/files/etc/config/netfleet'],
    'mihomo': ['openwrt/files/usr/share/opl-netfleet/nikki', 'openwrt/files/etc/init.d/opl-netfleet-core'],
    'configuration': ['openwrt/files/etc/opl-netfleet'],
    'components': ['openwrt/files/etc/init.d/opl-netfleet-update-recovery'],
    'maintenance': ['openwrt/files/usr/libexec/opl-netfleet-transfer'],
    'status': ['openwrt/files/usr/libexec/rpcd/opl-netfleet'],
    'scheduler': ['openwrt/files/etc/init.d/opl-netfleet'],
}
shared_packaging_paths = ['openwrt/Makefile', 'openwrt/plugin-packages.py', 'openwrt/plugin_payload.py', 'openwrt/compile-plugins.py']

def check_artifact(item, require_nr=True):
    p = reuse_root / item['name']
    if not p.is_file():
        return None
    data = p.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    if digest != item.get('sha256') or len(data) != item.get('size'):
        return None
    if require_nr:
        nr = prev_nr.get(item['package'])
        if not nr or nr.get('artifact') != item['name'] or nr.get('sha256') != digest:
            return None
    return str(p)

def paths_unchanged(paths):
    res = subprocess.run(['git', '-C', repo_dir, 'diff', '--quiet', prev_commit, commit, '--', *paths])
    return res.returncode == 0

plugin_manifests = {}
for mpath in sorted((Path(repo_dir) / 'plugins').glob('*/manifest.json')):
    pass
# Read plugin manifests from extracted workdir instead of possibly dirty working tree.
work_plugins = Path(core_lock).parents[2] / 'plugins'
for mpath in sorted(work_plugins.glob('*/manifest.json')):
    m = json.loads(mpath.read_text())
    if m.get('schema') == 'opl-netfleet-service-plugin.v1':
        plugin_manifests[m['id']] = m

reused = {}
skip_plugins = []
selected_plugins = []
build_luci = False

if plugins_filter:
    tokens = [t for t in plugins_filter.split(',') if t]
    rebuilt_pkgs = set()
    for token in tokens:
        if token == 'luci':
            build_luci = True
            rebuilt_pkgs.add('luci-app-netfleet')
        else:
            selected_plugins.append(token)
            rebuilt_pkgs.add(plugin_manifests[token]['package'])
    for pkg_name, item in list(prev_artifacts.items()) + list(prev_deps.items()):
        if pkg_name in rebuilt_pkgs:
            continue
        p = check_artifact(item, require_nr=(pkg_name in prev_artifacts))
        if not p:
            raise SystemExit(f'reuse feed missing valid artifact for untouched package: {pkg_name}')
        reused[pkg_name] = p
else:
    for plugin_id, manifest in sorted(plugin_manifests.items()):
        pkg_name = manifest['package']
        prev = prev_artifacts.get(pkg_name)
        if not prev:
            continue
        if prev.get('version') != manifest['version'] or prev.get('release', '') != release:
            continue
        p = check_artifact(prev, require_nr=True)
        if not p:
            continue
        watch = [*shared_packaging_paths, f'plugins/{plugin_id}', *extra_plugin_files.get(plugin_id, [])]
        if paths_unchanged(watch):
            reused[pkg_name] = p
            skip_plugins.append(plugin_id)
    prev_luci = prev_artifacts.get('luci-app-netfleet')
    if prev_luci and prev_luci.get('version') == luci_version and prev_luci.get('release', '') == luci_release:
        p = check_artifact(prev_luci, require_nr=True)
        if p and paths_unchanged(['openwrt/luci-app-netfleet']):
            reused['luci-app-netfleet'] = p
    core_source = json.loads(Path(core_lock).read_text())
    prev_core = prev_deps.get('mihomo-meta')
    if (prev_core and prev_core.get('version') == core_source['version']
            and prev_core.get('package_arch') == arch and prev_core.get('upstream') == core_source):
        p = check_artifact(prev_core, require_nr=False)
        if p and paths_unchanged(['openwrt/mihomo-meta', 'openwrt/files/usr/share/opl-netfleet/nikki/LICENSE']):
            reused['mihomo-meta'] = p

plan = {
    'base_feed_commit': prev_commit,
    'base_feed_tree': prev_manifest.get('source_tree', ''),
    'prev_manifest': prev_manifest,
    'prev_nr': prev_nr,
    'reused': reused,
    'skip_plugins': skip_plugins,
    'selected_plugins': selected_plugins,
    'build_luci': build_luci,
}
Path(out_path).write_text(json.dumps(plan))
PYREUSE
  reused_verify_apks=()
  while IFS= read -r apk_path; do
    [[ -n "$apk_path" ]] || continue
    reused_verify_apks+=("$apk_path")
  done < <(python3 -c 'import json,sys; p=json.load(open(sys.argv[1])); print("\n".join(p["reused"].values()))' "$work/reuse-plan.json")
  if [[ ${#reused_verify_apks[@]} -gt 0 ]]; then
    "$sdk/staging_dir/host/bin/apk" verify --keys-dir "$work/trusted" "${reused_verify_apks[@]}" ||
      die 'reuse feed APK signature verification failed'
  fi
fi

# Incremental plugin release path (--plugins <id1,id2,...> with --reuse-feed)
if [[ -n "$plugins_filter" ]]; then
  preflight_seconds=$SECONDS
  sdk_prepare_seconds=0
  clean_seconds=0
  selected_plugins=()
  while IFS= read -r pid; do [[ -n "$pid" ]] || continue; selected_plugins+=("$pid"); done < <(
    python3 -c 'import json,sys; p=json.load(open(sys.argv[1])); print("\n".join(p["selected_plugins"]))' "$work/reuse-plan.json"
  )
  build_luci=$(python3 -c 'import json,sys; p=json.load(open(sys.argv[1])); print(1 if p["build_luci"] else 0)' "$work/reuse-plan.json")
  if [[ ${#selected_plugins[@]} -gt 0 ]]; then
    stage_opl_netfleet
    prepare_ucode_host
    sdk_prepare_seconds=$((SECONDS - preflight_seconds))
    "$make_bin" -C "$sdk" package/opl-netfleet/clean V=s
    clean_seconds=$((SECONDS - preflight_seconds - sdk_prepare_seconds))
    "$make_bin" -j"$jobs" -C "$sdk" package/opl-netfleet/compile NETFLEET_ONLY_PLUGINS="${selected_plugins[*]}" NO_DEPS=1 CONFIG_AUTOREMOVE= V=s
  fi
  if [[ "$build_luci" == 1 ]]; then
    stage_luci_app
    t_clean_start=$SECONDS
    "$make_bin" -C "$sdk" package/luci-app-netfleet/clean V=s
    clean_seconds=$((clean_seconds + SECONDS - t_clean_start))
    "$make_bin" -j"$jobs" -C "$sdk" package/luci-app-netfleet/compile NO_DEPS=1 CONFIG_AUTOREMOVE= V=s
  fi
  compile_seconds=$((SECONDS - preflight_seconds))
  product_compile_seconds=$((compile_seconds - sdk_prepare_seconds - clean_seconds))

  signed_dir=$work/signed
  mkdir -p "$signed_dir"
  rebuilt_apks=()
  rebuilt_packages=()
  for pid in "${selected_plugins[@]}"; do
    read -r pkg_name pkg_ver < <(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print(m["package"], m["version"])' "$work/plugins/$pid/manifest.json")
    artifact_ver=$pkg_ver
    [[ -z "$release" ]] || artifact_ver+="-r${release}"
    found=()
    while IFS= read -r file; do found+=("$file"); done < <(find "$sdk/bin/packages" -type f -name "${pkg_name}-${artifact_ver}.apk" -print | sort)
    [[ ${#found[@]} -eq 1 ]] || die "expected one rebuilt $pkg_name artifact, found ${#found[@]}"
    signed_apk="$signed_dir/$(basename "${found[0]}")"
    cp "${found[0]}" "$signed_apk"
    "$sdk/staging_dir/host/bin/apk" adbsign --allow-untrusted --reset-signatures --sign-key "$sdk/private-key.pem" "$signed_apk"
    rebuilt_apks+=("$signed_apk")
    rebuilt_packages+=("$pkg_name")
  done
  if [[ "$build_luci" == 1 ]]; then
    artifact_ver=$luci_version
    [[ -z "$luci_release" ]] || artifact_ver+="-r${luci_release}"
    found=()
    while IFS= read -r file; do found+=("$file"); done < <(find "$sdk/bin/packages" -type f -name "luci-app-netfleet-${artifact_ver}.apk" -print | sort)
    [[ ${#found[@]} -eq 1 ]] || die "expected one rebuilt luci-app-netfleet artifact, found ${#found[@]}"
    signed_apk="$signed_dir/$(basename "${found[0]}")"
    cp "${found[0]}" "$signed_apk"
    "$sdk/staging_dir/host/bin/apk" adbsign --allow-untrusted --reset-signatures --sign-key "$sdk/private-key.pem" "$signed_apk"
    rebuilt_apks+=("$signed_apk")
    rebuilt_packages+=("luci-app-netfleet")
  fi
  "$sdk/staging_dir/host/bin/apk" verify --keys-dir "$work/trusted" "${rebuilt_apks[@]}"
  if [[ ${#selected_plugins[@]} -gt 0 ]]; then
    compiled_plugins=()
    while IFS= read -r directory; do compiled_plugins+=("$directory"); done < <(find "$sdk/build_dir" -type d -path "*/opl-netfleet-${version}/compiled-plugins")
    [[ ${#compiled_plugins[@]} -eq 1 ]] || die 'expected one compiled plugin payload'
    cp "${compiled_plugins[0]%/*}/bytecode.json" "$work/bytecode.json"
    rm -rf "$work/source-root"
    mkdir -p "$work/source-root/usr/libexec/opl-netfleet/plugins"
    cp -R "$work/openwrt/files/." "$work/source-root/"
    for pid in "${selected_plugins[@]}"; do
      cp -R "$sdk/package/opl-netfleet/plugins/$pid" "$work/source-root/usr/libexec/opl-netfleet/plugins/"
    done
    python3 "$work/scripts/verify-native-runtime.py" --apk "$sdk/staging_dir/host/bin/apk" \
      --source-root "$work/source-root" --bytecode-manifest "$work/bytecode.json" \
      "${rebuilt_apks[@]}" >"$work/new-native-runtime.json"
  else
    python3 "$work/scripts/verify-native-runtime.py" --apk "$sdk/staging_dir/host/bin/apk" \
      "${rebuilt_apks[@]}" >"$work/new-native-runtime.json"
  fi
  cp "$sdk/public-key.pem" "$output/opl-netfleet-apk.pem"
  chmod 0600 "$output/opl-netfleet-apk.pem"
  for src_apk in "${rebuilt_apks[@]}" "${reused_verify_apks[@]}"; do
    cp "$src_apk" "$output/$(basename "$src_apk")"
    chmod 0600 "$output/$(basename "$src_apk")"
  done
  package_files=()
  while IFS= read -r apk_file; do [[ -n "$apk_file" ]] || continue; package_files+=("$apk_file"); done < <(find "$output" -maxdepth 1 -type f -name '*.apk' | sort)
  "$sdk/staging_dir/host/bin/apk" mkndx --root "$sdk" --keys-dir "$sdk" --allow-untrusted \
    --output "$output/packages.adb" --sign "$sdk/private-key.pem" "${package_files[@]}"
  [[ -s "$output/packages.adb" ]] || die 'APK feed index is empty'
  chmod 0600 "$output/packages.adb"
  python3 "$repo_dir/scripts/openwrt-feed-metadata.py" --apk "$sdk/staging_dir/host/bin/apk" \
    --index "$output/packages.adb" --architecture "$build_target_arch" --output "$output/index.json"
  python3 - "$output" "$commit" "$tree" "$build_target_arch" "$release" "$luci_release" "$work/reuse-plan.json" "${rebuilt_apks[@]}" <<'PYPRELEASE'
import hashlib, json, re, sys
from pathlib import Path

out_dir, commit, tree, arch, release, luci_release, plan_path, *rebuilt_paths = sys.argv[1:]
out = Path(out_dir)
plan = json.loads(Path(plan_path).read_text())
prev_manifest = plan['prev_manifest']
reused_map = plan['reused']
rebuilt_by_pkg = {}
for src in rebuilt_paths:
    name = Path(src).name
    dst = out / name
    m = re.fullmatch(r'(.+)-(\d+\.\d+\.\d+)(?:-r(\d+))?\.apk', name)
    if not m:
        raise SystemExit(f'unrecognized rebuilt package artifact: {name}')
    pkg, ver, rel = m.groups()
    data = dst.read_bytes()
    item = {'package': pkg, 'name': name, 'sha256': hashlib.sha256(data).hexdigest(), 'size': len(data), 'version': ver}
    if rel is not None:
        item['release'] = rel
    rebuilt_by_pkg[pkg] = item

artifacts = []
for prev_item in prev_manifest.get('artifacts', []):
    pkg = prev_item['package']
    artifacts.append(rebuilt_by_pkg[pkg] if pkg in rebuilt_by_pkg else prev_item)

def file_ref(fname):
    return {'name': fname, 'sha256': hashlib.sha256((out / fname).read_bytes()).hexdigest()}

doc = {
    'schema': 'opl-netfleet-plugin-release.v1',
    'source_commit': commit,
    'source_tree': tree,
    'build_target_arch': arch,
    'base_feed_commit': plan['base_feed_commit'],
    'base_feed_tree': plan['base_feed_tree'],
    'rebuilt_packages': sorted(rebuilt_by_pkg),
    'reused_packages': sorted(reused_map),
    'artifacts': artifacts,
    'dependency_artifacts': prev_manifest.get('dependency_artifacts', []),
    'apk_public_key': file_ref('opl-netfleet-apk.pem'),
    'feed_index': file_ref('packages.adb'),
    'feed_metadata': file_ref('index.json'),
}
target = out / 'plugin-release.json'
target.write_text(json.dumps(doc, sort_keys=True, indent=2) + '\n')
target.chmod(0o600)
PYPRELEASE
  python3 - "$output.build-timings.json" "$preflight_seconds" "$compile_seconds" "$sdk_prepare_seconds" "$clean_seconds" "$product_compile_seconds" "$SECONDS" "$work/reuse-plan.json" "${rebuilt_packages[@]}" <<'PYTIMING'
import json, sys
from pathlib import Path
out_file, preflight, compile_s, prepare, clean, prod_compile, total, plan_path, *rebuilt = sys.argv[1:]
plan = json.loads(Path(plan_path).read_text())
Path(out_file).write_text(json.dumps({
    'preflight_seconds': int(preflight),
    'compile_seconds': int(compile_s),
    'sdk_prepare_seconds': int(prepare),
    'clean_seconds': int(clean),
    'product_compile_seconds': int(prod_compile),
    'packaging_seconds': int(total) - int(preflight) - int(compile_s),
    'total_seconds': int(total),
    'rebuilt_packages': sorted(rebuilt),
    'reused_packages': sorted(plan['reused']),
}, sort_keys=True) + '\n')
PYTIMING
  printf '%s\n' "$output/plugin-release.json"
  exit 0
fi

skip_plugins=()
skip_luci=0
skip_core=0
if [[ -n "$reuse_feed" ]]; then
  while IFS= read -r pid; do [[ -n "$pid" ]] || continue; skip_plugins+=("$pid"); done < <(
    python3 -c 'import json,sys; p=json.load(open(sys.argv[1])); print("\n".join(p["skip_plugins"]))' "$work/reuse-plan.json"
  )
  skip_luci=$(python3 -c 'import json,sys; p=json.load(open(sys.argv[1])); print(1 if "luci-app-netfleet" in p["reused"] else 0)' "$work/reuse-plan.json")
  skip_core=$(python3 -c 'import json,sys; p=json.load(open(sys.argv[1])); print(1 if "mihomo-meta" in p["reused"] else 0)' "$work/reuse-plan.json")
fi

stage_opl_netfleet
[[ "$skip_luci" == 1 ]] || stage_luci_app
[[ "$skip_core" == 1 ]] || stage_mihomo_meta

preflight_seconds=$SECONDS
prepare_ucode_host
sdk_prepare_seconds=$((SECONDS - preflight_seconds))
clean_targets=(package/opl-netfleet/clean)
[[ "$skip_luci" == 1 ]] || clean_targets+=(package/luci-app-netfleet/clean)
"$make_bin" -C "$sdk" "${clean_targets[@]}" V=s
clean_seconds=$((SECONDS - preflight_seconds - sdk_prepare_seconds))
# These payloads use the prepared SDK tools, not compiled dependency libraries.
# Keep runtime APK dependencies, but do not rebuild the SDK's entire kmod set.
# Retain this build's compiled payload until FILES and native-runtime validation
# consume it; the next invocation's package clean removes it.
compile_targets=()
[[ "$skip_core" == 1 ]] || compile_targets+=(package/mihomo-meta/compile)
compile_targets+=(package/opl-netfleet/compile)
[[ "$skip_luci" == 1 ]] || compile_targets+=(package/luci-app-netfleet/compile)
make_extra_args=(NO_DEPS=1 CONFIG_AUTOREMOVE= V=s)
if [[ ${#skip_plugins[@]} -gt 0 ]]; then
  make_extra_args+=("NETFLEET_SKIP_COMPILE_PLUGINS=${skip_plugins[*]}")
fi
"$make_bin" -j"$jobs" -C "$sdk" "${compile_targets[@]}" "${make_extra_args[@]}"

compile_seconds=$((SECONDS - preflight_seconds))
product_compile_seconds=$((compile_seconds - sdk_prepare_seconds - clean_seconds))
payload=$work/payload
mkdir -p "$payload/usr/libexec" "$payload/usr/libexec/rpcd" \
  "$payload/etc/opl-netfleet" "$payload/etc/init.d" "$payload/www" \
  "$payload/usr/share/luci" "$payload/usr/share/rpcd" "$payload/usr/share/opl-netfleet"
cp -R "$work/openwrt/files/usr/libexec/opl-netfleet" "$payload/usr/libexec/"
compiled_plugins=()
while IFS= read -r directory; do compiled_plugins+=("$directory"); done < <(find "$sdk/build_dir" -type d -path "*/opl-netfleet-${version}/compiled-plugins")
[[ ${#compiled_plugins[@]} -eq 1 ]] || die 'expected one compiled plugin payload'
rm -rf "$payload/usr/libexec/opl-netfleet/plugins"
cp -R "${compiled_plugins[0]}" "$payload/usr/libexec/opl-netfleet/plugins"
cp "${compiled_plugins[0]%/*}/bytecode.json" "$work/bytecode.json"
if [[ ${#skip_plugins[@]} -gt 0 ]]; then
  for pid in "${skip_plugins[@]}"; do
    reused_plugin_apk=$(python3 - "$work/reuse-plan.json" "$pid" <<'PYGET'
import json, sys
plan = json.load(open(sys.argv[1]))
print(plan['reused'][f'opl-netfleet-plugin-{sys.argv[2]}'])
PYGET
    )
    ext_dir="$work/reuse-extract/$pid"
    mkdir -p "$ext_dir"
    "$sdk/staging_dir/host/bin/apk" --allow-untrusted extract --destination "$ext_dir" "$reused_plugin_apk" >/dev/null
    [[ -d "$ext_dir/usr/libexec/opl-netfleet/plugins/$pid" ]] || die "reused plugin payload missing: $pid"
    rm -rf "$payload/usr/libexec/opl-netfleet/plugins/$pid"
    cp -R "$ext_dir/usr/libexec/opl-netfleet/plugins/$pid" "$payload/usr/libexec/opl-netfleet/plugins/$pid"
  done
fi

cp "$work/openwrt/files/usr/libexec/opl-netfleet-transfer" "$payload/usr/libexec/"
cp "$work/openwrt/files/usr/libexec/opl-netfleet-plugin-package" "$payload/usr/libexec/"
cp "$work/openwrt/files/usr/libexec/rpcd/opl-netfleet" "$payload/usr/libexec/rpcd/opl-netfleet"
cp "$work/openwrt/files/usr/libexec/rpcd/opl-netfleet.plugins" "$payload/usr/libexec/rpcd/opl-netfleet.plugins"
cp "$work/openwrt/files/etc/init.d/opl-netfleet" "$payload/etc/init.d/opl-netfleet"
cp "$work/openwrt/files/etc/init.d/opl-netfleet-core" "$payload/etc/init.d/opl-netfleet-core"
cp "$work/openwrt/files/etc/init.d/opl-netfleet-update-recovery" "$payload/etc/init.d/opl-netfleet-update-recovery"
cp -R "$work/openwrt/files/usr/share/opl-netfleet/." "$payload/usr/share/opl-netfleet/"
cp "$work/LICENSE" "$payload/usr/share/opl-netfleet/LICENSE.Apache-2.0"
cp "$work/openwrt/files/etc/config/netfleet" "$payload/usr/share/opl-netfleet/netfleet.config"
cp -R "$work/openwrt/files/etc/opl-netfleet/." "$payload/etc/opl-netfleet/"
cp "$build_identity" "$payload/usr/share/opl-netfleet/build.json"
cp -R "$work/openwrt/luci-app-netfleet/htdocs/." "$payload/www/"
find "$payload/www" -type f -name '*.d.ts' -delete
for plugin_dir in "$payload/usr/libexec/opl-netfleet/plugins/"*; do
  python3 "$work/openwrt/plugin_payload.py" project "$plugin_dir" "$payload/www"
done
cp -R "$work/openwrt/luci-app-netfleet/root/." "$payload/"
if [[ "$package_format" != apk ]]; then
  rm -rf "$payload/usr/libexec/netfleet-firmware" "$payload/usr/share/netfleet-firmware"
  rm -f "$payload/usr/libexec/opl-netfleet-firmware" "$payload/lib/upgrade/keep.d/netfleet" \
    "$payload/www/luci-static/resources/view/netfleet/firmware.js" \
    "$payload/usr/share/luci/menu.d/luci-app-netfleet-firmware.json" \
    "$payload/usr/share/rpcd/acl.d/luci-app-netfleet-firmware.json"
fi
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
chmod 0755 "$payload/usr/libexec/opl-netfleet/plugins/components/lib/apk-fetch/wget"
if [[ "$package_format" == apk ]]; then
  chmod 0755 "$payload/usr/libexec/opl-netfleet-firmware" "$payload/usr/share/netfleet-firmware/restore-defaults"
fi
files_manifest=$output/FILES.sha256
# Hash in one process; per-file shell/awk launches are costly on an emulated SDK.
python3 - "$payload" "$files_manifest" <<'PYFILES'
import hashlib, os, sys
from pathlib import Path
root, output = map(Path, sys.argv[1:])
with output.open('w') as stream:
    for path in sorted((p for p in root.rglob('*') if p.is_file() and not p.is_symlink()), key=lambda p: os.fsencode(str(p))):
        stream.write(f'{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.relative_to(root)}\n')
PYFILES
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
artifact_reused_flags=()
product_packages=(opl-netfleet opl-netfleet-kernel luci-app-netfleet)
product_versions=("$version" "$version" "$luci_version")
while read -r package_name package_version; do
  product_packages+=("$package_name")
  product_versions+=("$package_version")
done < <(
  python3 - "$work/plugins" <<'PY'
import json, sys
from pathlib import Path
for path in sorted(Path(sys.argv[1]).glob('*/manifest.json')):
    manifest = json.loads(path.read_text())
    if path.parent.name == 'device-identity' and manifest.get('schema') == 'opl-netfleet-plugin.v1':
        continue
    if manifest['schema'] != 'opl-netfleet-service-plugin.v1':
        raise SystemExit(f'unsupported built-in plugin manifest: {path}')
    print(manifest['package'], manifest['version'])
PY
)
for package_index in "${!product_packages[@]}"; do
  package_name=${product_packages[$package_index]}
  reused_path=''
  if [[ -n "$reuse_feed" ]]; then
    reused_path=$(python3 - "$work/reuse-plan.json" "$package_name" <<'PYCHK'
import json, sys
print(json.load(open(sys.argv[1]))['reused'].get(sys.argv[2], ''))
PYCHK
    )
  fi
  if [[ -n "$reused_path" ]]; then
    artifacts+=("$reused_path")
    artifact_reused_flags+=(1)
    continue
  fi
  artifact_version=${product_versions[$package_index]}
  artifact_release=$release
  if [[ "$package_name" == luci-app-netfleet ]]; then
    artifact_version=$luci_version
    artifact_release=$luci_release
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
  artifact_reused_flags+=(0)
done
if [[ "$skip_core" == 1 ]]; then
  reused_core=$(python3 - "$work/reuse-plan.json" <<'PYCOREGET'
import json, sys
print(json.load(open(sys.argv[1]))['reused']['mihomo-meta'])
PYCOREGET
  )
  artifacts+=("$reused_core")
  artifact_reused_flags+=(1)
else
  if [[ "$package_format" == apk ]]; then
    core_pattern="mihomo-meta-${core_version}-r1.apk"
  else
    core_pattern="mihomo-meta_${core_version}-r1_${build_target_arch}.ipk"
  fi
  core_artifacts=()
  while IFS= read -r file; do core_artifacts+=("$file"); done < <(find "$sdk/bin/packages" -type f -name "$core_pattern" -print | sort)
  [[ ${#core_artifacts[@]} -eq 1 ]] || die 'expected exactly one pinned Mihomo dependency package'
  artifacts+=("${core_artifacts[0]}")
  artifact_reused_flags+=(0)
fi
bootstrap_sha256=''
public_key=''
reused_packages_list=()
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
  final_artifacts=()
  rebuilt_product_apks=()
  for idx in "${!artifacts[@]}"; do
    artifact=${artifacts[$idx]}
    is_reused=${artifact_reused_flags[$idx]}
    if [[ "$is_reused" == 1 ]]; then
      final_artifacts+=("$artifact")
      if (( idx < ${#product_packages[@]} )); then
        reused_packages_list+=("${product_packages[$idx]}")
      else
        reused_packages_list+=("mihomo-meta")
      fi
    else
      signed_artifact=$signed_dir/$(basename "$artifact")
      cp "$artifact" "$signed_artifact"
      "$sdk/staging_dir/host/bin/apk" adbsign --allow-untrusted --reset-signatures \
        --sign-key "$sdk/private-key.pem" "$signed_artifact"
      final_artifacts+=("$signed_artifact")
      if (( idx < ${#product_packages[@]} )); then
        rebuilt_product_apks+=("$signed_artifact")
      fi
    fi
  done
  cp "$public_key" "$trusted_dir/opl-netfleet-apk.pem"
  "$sdk/staging_dir/host/bin/apk" verify --keys-dir "$trusted_dir" "${final_artifacts[@]}"
  artifacts=("${final_artifacts[@]}")
  rm -rf "$work/source-root"
  mkdir -p "$work/source-root"
  cp -R "$work/openwrt/files/." "$work/source-root/"
  mkdir -p "$work/source-root/usr/libexec/opl-netfleet/plugins"
  cp -R "$sdk/package/opl-netfleet/plugins/." "$work/source-root/usr/libexec/opl-netfleet/plugins/"
  if [[ ${#rebuilt_product_apks[@]} -gt 0 ]]; then
    python3 "$work/scripts/verify-native-runtime.py" --apk "$sdk/staging_dir/host/bin/apk" \
      --source-root "$work/source-root" --bytecode-manifest "$work/bytecode.json" \
      "${rebuilt_product_apks[@]}" >"$work/rebuilt-native-runtime.json"
  else
    printf '{"ok":true,"packages":[]}\n' >"$work/rebuilt-native-runtime.json"
  fi
  if [[ -n "$reuse_feed" ]]; then
    python3 - "$work/rebuilt-native-runtime.json" "$work/reuse-plan.json" "$output/native-runtime.json" "${product_packages[@]}" <<'PYMERGENR'
import json, sys
from pathlib import Path

rebuilt_path, plan_path, out_path, *ordered = sys.argv[1:]
rebuilt_entries = {item['package']: item for item in json.loads(Path(rebuilt_path).read_text())['packages']}
prev_entries = json.loads(Path(plan_path).read_text())['prev_nr']
merged = []
for pkg in ordered:
    if pkg in rebuilt_entries:
        merged.append(rebuilt_entries[pkg])
    elif pkg in prev_entries:
        merged.append(prev_entries[pkg])
    else:
        raise SystemExit(f'missing native-runtime entry for package: {pkg}')
Path(out_path).write_text(json.dumps({'ok': True, 'packages': merged}) + '\n')
PYMERGENR
  else
    cp "$work/rebuilt-native-runtime.json" "$output/native-runtime.json"
  fi
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
  python3 "$repo_dir/scripts/openwrt-feed-metadata.py" --apk "$sdk/staging_dir/host/bin/apk" \
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
python3 - "$output.build-timings.json" "$preflight_seconds" "$compile_seconds" "$sdk_prepare_seconds" "$clean_seconds" "$product_compile_seconds" "$SECONDS" "${reused_packages_list[@]}" <<'PYTIMING'
import json, sys
from pathlib import Path
out_file, preflight, compile_s, prepare, clean, prod_compile, total, *reused = sys.argv[1:]
Path(out_file).write_text(json.dumps({
    'preflight_seconds': int(preflight),
    'compile_seconds': int(compile_s),
    'sdk_prepare_seconds': int(prepare),
    'clean_seconds': int(clean),
    'product_compile_seconds': int(prod_compile),
    'packaging_seconds': int(total) - int(preflight) - int(compile_s),
    'total_seconds': int(total),
    'reused_packages': sorted(reused),
}, sort_keys=True) + '\n')
PYTIMING
printf '%s\n' "$output/manifest.json"
