#!/usr/bin/env bash
set -euo pipefail
sdk=${1:?OpenWrt SDK path required}
key=${2:?APK signing key required}
output=${3:?output directory required}
ref=${4:-HEAD}
identity_from=${NETFLEET_COMPAT_IDENTITY_FROM:-}
repo=$(cd "$(dirname "$0")/../.." && pwd)
commit=$(git -C "$repo" rev-parse "$ref^{commit}")
tree=$(git -C "$repo" rev-parse "$commit^{tree}")
test -f "$sdk/Makefile"
test -f "$key"
mkdir -p "$output"
work=$(mktemp -d)
package=opl-netfleet-https-compat
identity_package=opl-netfleet-plugin-device-identity
for name in "$package" "$identity_package" opl-netfleet mihomo-meta; do
  test ! -e "$sdk/package/$name"
done
restore() {
  rm -rf "$sdk/package/$package" "$sdk/package/$identity_package" "$sdk/package/opl-netfleet" "$sdk/package/mihomo-meta"
  for name in private-key.pem public-key.pem .config; do
    rm -f "$sdk/$name"
    test ! -f "$work/$name" || cp -p "$work/$name" "$sdk/$name"
  done
  rm -rf "$work"
}
trap restore EXIT
for name in private-key.pem public-key.pem .config; do
  test ! -f "$sdk/$name" || cp -p "$sdk/$name" "$work/$name"
done
git -C "$repo" archive "$commit" openwrt plugins/device-identity scripts/netfleet-plugin.py scripts/verify-native-runtime.py | tar -xf - -C "$work"
cp -R "$work/openwrt/https-compat" "$sdk/package/$package"
cp "$work/openwrt/native/atomic-replace.c" "$sdk/package/$package/src/"
if [ -z "$identity_from" ]; then
  python3 "$work/scripts/netfleet-plugin.py" package-source "$work/plugins/device-identity" "$sdk/package/$identity_package" --license Apache-2.0
fi
mkdir -p "$sdk/package/opl-netfleet"
cp "$work/openwrt/Makefile" "$sdk/package/opl-netfleet/"
cp "$work/openwrt/plugin-packages.py" "$sdk/package/opl-netfleet/"
cp "$work/openwrt/plugin_payload.py" "$sdk/package/opl-netfleet/"
cp -R "$work/openwrt/files" "$sdk/package/opl-netfleet/"
cp -R "$work/openwrt/mihomo-meta" "$sdk/package/mihomo-meta"
(cd "$sdk" && ./scripts/feeds install -p base openssl ca-bundle libmnl libnftnl libjson-c ucode libmd)
cp "$key" "$sdk/private-key.pem"
chmod 0600 "$sdk/private-key.pem"
"$sdk/staging_dir/host/bin/openssl" ec -in "$sdk/private-key.pem" -pubout >"$sdk/public-key.pem"
make -C "$sdk" "package/$package/clean" V=s
jobs=${NETFLEET_COMPAT_BUILD_JOBS:-8}
[[ "$jobs" =~ ^[1-9][0-9]*$ ]]
# Build real library metadata without optional kernel crypto engines.
make -C "$sdk" -j"$jobs" package/toolchain/compile package/feeds/base/openssl/compile \
  CONFIG_OPENSSL_ENGINE= CONFIG_OPENSSL_ENGINE_BUILTIN_DEVCRYPTO= \
  CONFIG_PACKAGE_libopenssl-devcrypto= CONFIG_PACKAGE_libopenssl-afalg= \
  CONFIG_PACKAGE_libopenssl-padlock= NO_DEPS=1 V=s
# Native module headers and small wire libraries must come from real SDK builds.
# Only the ucode core/headers are needed here; optional module dependencies are
# provided by the base image and are not rebuilt by this optional-package lane.
make -C "$sdk" -j"$jobs" package/feeds/base/libmnl/compile package/feeds/base/libnftnl/compile \
  package/feeds/base/libjson-c/compile package/feeds/base/libmd/compile PKG_BUILD_FLAGS=no-lto NO_DEPS=1 V=s
make -C "$sdk" -j"$jobs" package/feeds/base/ucode/compile \
  CONFIG_PACKAGE_ucode-mod-fs=y CONFIG_PACKAGE_ucode-mod-digest=y \
  CONFIG_PACKAGE_ucode-mod-math= CONFIG_PACKAGE_ucode-mod-nl80211= CONFIG_PACKAGE_ucode-mod-resolv= \
  CONFIG_PACKAGE_ucode-mod-rtnl= CONFIG_PACKAGE_ucode-mod-struct= CONFIG_PACKAGE_ucode-mod-ubus= \
  CONFIG_PACKAGE_ucode-mod-uci= CONFIG_PACKAGE_ucode-mod-uloop= CONFIG_PACKAGE_ucode-mod-debug= \
  CONFIG_PACKAGE_ucode-mod-log= CONFIG_PACKAGE_ucode-mod-zlib= CONFIG_PACKAGE_ucode-mod-socket= NO_DEPS=1 V=s
make -C "$sdk" -j"$jobs" "package/$package/download" "package/$package/compile" NO_DEPS=1 V=s
if [ -z "$identity_from" ]; then
  make -C "$sdk" "package/$identity_package/clean" V=s
  make -C "$sdk" -j"$jobs" "package/$identity_package/compile" NO_DEPS=1 V=s
fi
mapfile -t packages < <(find "$sdk/bin/packages" -type f -name "$package-*.apk")
test "${#packages[@]}" = 1
cp "${packages[0]}" "$output/"
cp "$sdk/public-key.pem" "$output/compat-public-key.pem"
mkdir -p "$work/trusted"
cp "$sdk/public-key.pem" "$work/trusted/compat-public-key.pem"
artifact="$output/${packages[0]##*/}"
if [ -n "$identity_from" ]; then
  mapfile -t identity_packages < <(find "$identity_from" -maxdepth 1 -type f -name "$identity_package-*.apk")
  cp "$identity_from/device-identity-manifest.json" "$output/"
else
  mapfile -t identity_packages < <(find "$sdk/bin/packages" -type f -name "$identity_package-*.apk")
fi
test "${#identity_packages[@]}" = 1
cp "${identity_packages[0]}" "$output/"
identity_artifact="$output/${identity_packages[0]##*/}"
"$sdk/staging_dir/host/bin/apk" adbsign --allow-untrusted --reset-signatures \
  --sign-key "$sdk/private-key.pem" "$artifact"
"$sdk/staging_dir/host/bin/apk" verify --keys-dir "$work/trusted" "$artifact"
if [ -z "$identity_from" ]; then
  "$sdk/staging_dir/host/bin/apk" adbsign --allow-untrusted --reset-signatures --sign-key "$sdk/private-key.pem" "$identity_artifact"
fi
"$sdk/staging_dir/host/bin/apk" verify --keys-dir "$work/trusted" "$identity_artifact"
python3 "$work/scripts/verify-native-runtime.py" --apk "$sdk/staging_dir/host/bin/apk" "$artifact" "$identity_artifact" >"$output/native-runtime.json"
python3 - "$output" "$commit" "$tree" "${packages[0]##*/}" "${identity_packages[0]##*/}" "$identity_from" <<'PY'
import hashlib, json, sys
from pathlib import Path
output, commit, tree, name, identity, identity_from = sys.argv[1:]
path = Path(output)
(path / 'compat-manifest.json').write_text(json.dumps({'source_commit': commit, 'source_tree': tree,
    'architecture': 'aarch64_generic', 'engine': 'haproxy', 'engine_version': '3.2.21',
    'artifact': name, 'sha256': hashlib.sha256((path / name).read_bytes()).hexdigest(),
    'native_runtime': {'name': 'native-runtime.json', 'sha256': hashlib.sha256((path / 'native-runtime.json').read_bytes()).hexdigest()}}, sort_keys=True) + '\n')
if identity_from:
    stored = json.loads((path / 'device-identity-manifest.json').read_text())
    if stored.get('artifact') != identity or stored.get('sha256') != hashlib.sha256((path / identity).read_bytes()).hexdigest():
        raise SystemExit('Retained device identity artifact mismatch')
else:
    (path / 'device-identity-manifest.json').write_text(json.dumps({'source_commit': commit, 'source_tree': tree,
        'artifact': identity, 'sha256': hashlib.sha256((path / identity).read_bytes()).hexdigest()}, sort_keys=True) + '\n')
PY

# Optional feed is a separate composition: the default product never pulls it in.
"$sdk/staging_dir/host/bin/apk" mkndx --root "$sdk" --keys-dir "$sdk" --allow-untrusted \
  --output "$output/compat-packages.adb" --sign "$sdk/private-key.pem" "$artifact" "$identity_artifact"
