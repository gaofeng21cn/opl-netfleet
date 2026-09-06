#!/usr/bin/env bash
set -euo pipefail
sdk=${1:?OpenWrt SDK path required}
runtime=${2:?musl runtime path required}
key=${3:?APK signing key required}
output=${4:?output directory required}
ref=${5:-HEAD}
repo=$(cd "$(dirname "$0")/../.." && pwd)
commit=$(git -C "$repo" rev-parse "$ref^{commit}")
tree=$(git -C "$repo" rev-parse "$commit^{tree}")
test -f "$sdk/Makefile"
test -f "$runtime/vendor/mitmproxy-12.2.3.dist-info/METADATA"
test -f "$key"
mkdir -p "$output"
work=$(mktemp -d)
package=opl-netfleet-https-compat
for name in "$package" opl-netfleet mihomo-meta; do
  test ! -e "$sdk/package/$name"
done
restore() {
  rm -rf "$sdk/package/$package" "$sdk/package/opl-netfleet" "$sdk/package/mihomo-meta"
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
git -C "$repo" archive "$commit" openwrt | tar -xf - -C "$work"
cp -R "$work/openwrt/https-compat" "$sdk/package/$package"
mkdir -p "$sdk/package/opl-netfleet"
cp "$work/openwrt/Makefile" "$sdk/package/opl-netfleet/"
cp -R "$work/openwrt/files" "$sdk/package/opl-netfleet/"
cp -R "$work/openwrt/mihomo-meta" "$sdk/package/mihomo-meta"
(cd "$sdk" && ./scripts/feeds install -p base openssl ca-bundle)
(cd "$sdk" && ./scripts/feeds update -i packages && ./scripts/feeds install -p packages python3)
cp "$key" "$sdk/private-key.pem"
chmod 0600 "$sdk/private-key.pem"
"$sdk/staging_dir/host/bin/openssl" ec -in "$sdk/private-key.pem" -pubout >"$sdk/public-key.pem"
make -C "$sdk" "package/$package/clean" V=s
jobs=${NETFLEET_COMPAT_BUILD_JOBS:-8}
[[ "$jobs" =~ ^[1-9][0-9]*$ ]]
# Build real library metadata without optional kernel crypto engines.
make -C "$sdk" -j"$jobs" package/toolchain/compile package/feeds/base/openssl/compile \
  CONFIG_OPENSSL_ENGINE= CONFIG_OPENSSL_ENGINE_BUILTIN_DEVCRYPTO= \
  CONFIG_PACKAGE_libopenssl-devcrypto= NO_DEPS=1 V=s
make -C "$sdk" "package/$package/compile" NETFLEET_COMPAT_RUNTIME="$runtime" NO_DEPS=1 V=s
mapfile -t packages < <(find "$sdk/bin/packages" -type f -name "$package-*.apk")
test "${#packages[@]}" = 1
cp "${packages[0]}" "$output/"
cp "$sdk/public-key.pem" "$output/compat-public-key.pem"
mkdir -p "$work/trusted"
cp "$sdk/public-key.pem" "$work/trusted/compat-public-key.pem"
artifact="$output/${packages[0]##*/}"
"$sdk/staging_dir/host/bin/apk" adbsign --allow-untrusted --reset-signatures \
  --sign-key "$sdk/private-key.pem" "$artifact"
"$sdk/staging_dir/host/bin/apk" verify --keys-dir "$work/trusted" "$artifact"
python3 - "$output" "$commit" "$tree" "${packages[0]##*/}" <<'PY'
import hashlib, json, sys
from pathlib import Path
output, commit, tree, name = sys.argv[1:]
path = Path(output)
(path / 'compat-manifest.json').write_text(json.dumps({'source_commit': commit, 'source_tree': tree,
    'architecture': 'aarch64_generic', 'python': '3.13', 'mitmproxy': '12.2.3',
    'artifact': name, 'sha256': hashlib.sha256((path / name).read_bytes()).hexdigest()}, sort_keys=True) + '\n')
PY
