#!/bin/sh
set -eu
umask 077
commit=${1:?}
tree=${2:?}
feed_url=${3:-}

test "$(uname -m)" = aarch64
test "$(readlink /var)" = tmp
ip route replace default via 192.168.1.2
printf 'nameserver 192.168.1.3\n' >/etc/resolv.conf
apk update >&2
apk add python3 python3-pip libstdcpp ca-bundle coreutils-timeout ip-full kmod-veth kmod-nft-tproxy kmod-nft-socket curl ucode-mod-fs ucode-mod-uci ucode-mod-ubus ucode-mod-uloop >&2
vendor=/tmp/compat-runtime/vendor
if [ -f /tmp/compat-runtime/compat-manifest.json ]; then
 test -n "$feed_url"
 python3 - "$commit" "$tree" <<'PY'
import hashlib, json, sys
from pathlib import Path
root = Path('/tmp/compat-runtime')
m = json.loads((root / 'compat-manifest.json').read_text())
assert (m['source_commit'], m['source_tree']) == tuple(sys.argv[1:])
assert Path(m['artifact']).name == m['artifact']
assert hashlib.sha256((root / m['artifact']).read_bytes()).hexdigest() == m['sha256']
PY
 curl -fsS "$feed_url/install-netfleet.sh" -o /tmp/install-netfleet.sh
 NETFLEET_FEED_BASE="$feed_url" NETFLEET_ALLOW_INSECURE_FEED=1 sh /tmp/install-netfleet.sh >&2
 cp /tmp/compat-runtime/compat-public-key.pem /etc/apk/keys/netfleet-compat-test.pem
 apk verify /tmp/compat-runtime/*.apk >&2
 apk add /tmp/compat-runtime/*.apk >&2
 apk info -e opl-netfleet opl-netfleet-https-compat luci-app-netfleet >&2
 vendor=/usr/lib/opl-netfleet-compat/vendor
else
 mkdir -p /usr/lib/opl-netfleet-compat /usr/libexec /etc/opl-netfleet
 ln -s "$vendor" /usr/lib/opl-netfleet-compat/vendor
 cp -R /tmp/openwrt/https-compat/files/. /
 cp -R /tmp/openwrt/files/usr/libexec/opl-netfleet /usr/libexec/
 cp /tmp/openwrt/files/etc/config/netfleet /etc/config/netfleet
 cp /tmp/openwrt/files/etc/init.d/opl-netfleet-core /etc/init.d/opl-netfleet-core
 mkdir -p /usr/share/opl-netfleet
 cp -R /tmp/openwrt/files/usr/share/opl-netfleet/nikki /usr/share/opl-netfleet/
 gzip -dc /tmp/mihomo-linux-arm64-v1.19.30.gz >/tmp/compat-mihomo
 ln -s /tmp/compat-mihomo /usr/bin/mihomo
 ln -s /tmp/yq_linux_arm64-v4.53.6 /usr/bin/yq
 chmod 0755 /tmp/compat-mihomo /tmp/yq_linux_arm64-v4.53.6
fi
export PYTHONPATH="$vendor"
launcher=/usr/libexec/opl-netfleet-compat/mitmdump
chmod 0755 "$launcher"
"$launcher" --version >&2
python3 -m pip install --break-system-packages --target /tmp/compat-test-deps hypercorn==0.18.0 httpx==0.28.1 >&2
export PYTHONPATH="$vendor:/tmp/compat-test-deps"
export PATH=/usr/libexec/opl-netfleet-compat:$PATH
python3 /tmp/tests/https_compat_protocol.py >&2
touch /tmp/netfleet-compat-vm-authorized
python3 /tmp/tests/https_compat_kernel.py >&2
chmod 0755 /etc/init.d/opl-netfleet-compat /usr/libexec/opl-netfleet-compat/mitmdump
python3 /tmp/tests/https_compat_controller.py >&2
chmod 0755 /etc/init.d/opl-netfleet-core
python3 /tmp/tests/https_compat_native.py >&2
du -sk "$vendor" >&2
if [ -f /tmp/compat-runtime/compat-manifest.json ]; then
 sha256sum /etc/opl-netfleet/compatibility/ca/mitmproxy-ca.pem >/tmp/compat-ca.sha256
 apk add --force-reinstall /tmp/compat-runtime/*.apk >&2
 sha256sum -c /tmp/compat-ca.sha256 >&2
 apk del opl-netfleet-https-compat >&2
 sha256sum -c /tmp/compat-ca.sha256 >&2
 ! nft list table inet netfleet_compat 2>/dev/null
 test ! -x /usr/libexec/opl-netfleet-compat/mitmdump
 ubus call system board >/dev/null
fi
python3 - "$commit" "$tree" <<'PY'
import json, sys
from pathlib import Path
print(json.dumps({"ok": True, "source_commit": sys.argv[1], "source_tree": sys.argv[2],
                  "checks": {"musl_runtime": True, "protocol_wire": True, "kernel_lease": True, "controller_procd": True, "native_egress": True},
                  "signed_package_lifecycle": Path('/tmp/compat-runtime/compat-manifest.json').exists(), "production_ready": False}))
PY
