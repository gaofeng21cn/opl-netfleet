#!/bin/sh
set -eu
umask 077
commit=${1:?}
tree=${2:?}

test "$(uname -m)" = aarch64
test "$(readlink /var)" = tmp
ip route replace default via 192.168.1.2
printf 'nameserver 192.168.1.3\n' >/etc/resolv.conf
apk update >&2
apk add python3 python3-pip libstdcpp ca-bundle ip-full kmod-veth kmod-nft-tproxy kmod-nft-socket curl ucode-mod-fs ucode-mod-uci ucode-mod-ubus ucode-mod-uloop >&2
export PYTHONPATH=/tmp/compat-runtime/vendor
launcher=/tmp/openwrt/https-compat/files/usr/libexec/opl-netfleet-compat/mitmdump
chmod 0755 "$launcher"
"$launcher" --version >&2
python3 -m pip install --break-system-packages --target /tmp/compat-test-deps hypercorn==0.18.0 httpx==0.28.1 >&2
export PYTHONPATH=/tmp/compat-runtime/vendor:/tmp/compat-test-deps
export PATH=/tmp/openwrt/https-compat/files/usr/libexec/opl-netfleet-compat:$PATH
python3 /tmp/tests/https_compat_protocol.py >&2
touch /tmp/netfleet-compat-vm-authorized
python3 /tmp/tests/https_compat_kernel.py >&2
mkdir -p /usr/lib/opl-netfleet-compat /usr/libexec /etc/opl-netfleet
ln -s /tmp/compat-runtime/vendor /usr/lib/opl-netfleet-compat/vendor
cp -R /tmp/openwrt/https-compat/files/. /
cp -R /tmp/openwrt/files/usr/libexec/opl-netfleet /usr/libexec/
cp /tmp/openwrt/files/etc/config/netfleet /etc/config/netfleet
chmod 0755 /etc/init.d/opl-netfleet-compat /usr/libexec/opl-netfleet-compat/mitmdump
python3 /tmp/tests/https_compat_controller.py >&2
cp /tmp/openwrt/files/etc/init.d/opl-netfleet-core /etc/init.d/opl-netfleet-core
chmod 0755 /etc/init.d/opl-netfleet-core
mkdir -p /usr/share/opl-netfleet
cp -R /tmp/openwrt/files/usr/share/opl-netfleet/nikki /usr/share/opl-netfleet/
gzip -dc /tmp/mihomo-linux-arm64-v1.19.30.gz >/usr/bin/mihomo
cp /tmp/yq_linux_arm64-v4.53.6 /usr/bin/yq
chmod 0755 /usr/bin/mihomo /usr/bin/yq
python3 /tmp/tests/https_compat_native.py >&2
du -sk /tmp/compat-runtime/vendor >&2
python3 - "$commit" "$tree" <<'PY'
import json, sys
print(json.dumps({"ok": True, "source_commit": sys.argv[1], "source_tree": sys.argv[2],
                  "checks": {"musl_runtime": True, "protocol_wire": True, "kernel_lease": True, "controller_procd": True, "native_egress": True}, "production_ready": False}))
PY
