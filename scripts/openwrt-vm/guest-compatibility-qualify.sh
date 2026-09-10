#!/bin/sh
set -eu
umask 077
commit=${1:?}
tree=${2:?}
feed_url=${3:-}

if [ -f /tmp/compat-runtime/native-runtime.json ]; then
 exec sh /tmp/guest-compatibility-native-qualify.sh "$commit" "$tree" "$feed_url" "${4:?}"
fi

test "$(uname -m)" = aarch64
test "$(readlink /var)" = tmp
ip route replace default via 192.168.1.2
printf 'nameserver 192.168.1.3\n' >/etc/resolv.conf
apk update >&2
apk add python3 python3-pip libstdcpp ca-bundle coreutils-timeout ip-full conntrack scapy openssl-util kmod-veth kmod-nft-tproxy kmod-nft-socket curl ucode-mod-fs ucode-mod-uci ucode-mod-socket ucode-mod-ubus ucode-mod-uloop >&2
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
identity = root / 'device-identity-manifest.json'
if identity.exists():
    m = json.loads(identity.read_text())
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
else
 mkdir -p /usr/libexec /etc/opl-netfleet
 cp -R /tmp/openwrt/https-compat/files/. /
 cp /tmp/compat-runtime/haproxy /usr/libexec/opl-netfleet-compat/haproxy
 cp -R /tmp/openwrt/files/usr/libexec/opl-netfleet /usr/libexec/
cp /tmp/openwrt/files/usr/libexec/opl-netfleet-plugin-package /usr/libexec/
chmod 0755 /usr/libexec/opl-netfleet-plugin-package
 cp /tmp/openwrt/files/etc/config/netfleet /etc/config/netfleet
 cp /tmp/openwrt/files/etc/init.d/opl-netfleet-core /etc/init.d/opl-netfleet-core
 mkdir -p /usr/share/opl-netfleet
 cp -R /tmp/openwrt/files/usr/share/opl-netfleet/. /usr/share/opl-netfleet/
 gzip -dc /tmp/mihomo-linux-arm64-v1.19.30.gz >/tmp/compat-mihomo
 ln -s /tmp/compat-mihomo /usr/bin/mihomo
 ln -s /tmp/yq_linux_arm64-v4.53.6 /usr/bin/yq
 chmod 0755 /tmp/compat-mihomo /tmp/yq_linux_arm64-v4.53.6
fi
IPKG_INSTROOT=
. /lib/functions.sh
compat_gid=$(group_add_next netfleet-compat)
user_exists netfleet-compat || user_add netfleet-compat "" "$compat_gid"
chmod 0755 /usr/libexec/opl-netfleet-compat
chmod 0644 /usr/libexec/opl-netfleet-compat/*.py /usr/libexec/opl-netfleet-compat/extension.json
launcher=/usr/libexec/opl-netfleet-compat/haproxy
chmod 0755 "$launcher"
"$launcher" -vv >&2
python3 -m pip install --break-system-packages --target /tmp/compat-test-deps cryptography hypercorn==0.18.0 httpx==0.28.1 >&2
export PYTHONPATH="/tmp/compat-test-deps"
export PATH=/usr/libexec/opl-netfleet-compat:$PATH
if [ ! -f /usr/libexec/opl-netfleet/plugins/device-identity/manifest.json ]; then
 cp -R /tmp/plugins/device-identity /usr/libexec/opl-netfleet/plugins/
fi
chmod 0755 /usr/libexec/opl-netfleet/plugins/device-identity/control
# Installation leaves this optional management plugin unloaded. Exercise the
# same explicit load action as the plugin UI, without changing product defaults.
python3 - <<'PY'
import json, subprocess
from pathlib import Path
main = ['ucode', '/usr/libexec/opl-netfleet/main.uc']
inventory = json.loads(subprocess.check_output([*main, 'plugins-list']))
row = next(item for item in inventory['result']['plugins'] if item['id'] == 'https-compat' and item['instance'] == 'default')
request = Path('/tmp/compat-plugin-load.json')
request.write_text(json.dumps({'request': {'id': row['id'], 'action': 'load', 'revision': row['revision'], 'confirm': True}}))
request.chmod(0o600)
result = json.loads(subprocess.check_output([*main, 'plugin-call', str(request)]))
assert result['ok'] and result['result']['loaded'], result
PY
python3 /tmp/tests/device_identity.py >&2
python3 /tmp/tests/https_compat_identity.py >&2
python3 /tmp/tests/https_compat_protocol.py >&2
touch /tmp/netfleet-compat-vm-authorized
python3 /tmp/tests/https_compat_lease.py >&2
python3 /tmp/tests/https_compat_kernel.py >&2
chmod 0755 /etc/init.d/opl-netfleet-compat /usr/libexec/opl-netfleet-compat/haproxy
python3 /tmp/tests/https_compat_isolation.py >&2
python3 /tmp/tests/https_compat_controller.py >&2
python3 /tmp/tests/device_identity_device.py >&2
chmod 0755 /etc/init.d/opl-netfleet-core
python3 /tmp/tests/https_compat_native.py >&2
python3 - <<'PY'
import json
from pathlib import Path
group = Path('/sys/fs/cgroup/netfleet-compat')
events = dict(line.split() for line in (group / 'memory.events').read_text().splitlines())
metrics = {'engine_memory_peak_bytes': int((group / 'memory.peak').read_text()),
           'engine_memory_max_bytes': int((group / 'memory.max').read_text()),
           'engine_oom_kill': int(events['oom_kill'])}
assert metrics['engine_oom_kill'] == 0, metrics
Path('/tmp/compat-resources.json').write_text(json.dumps(metrics))
PY
du -sk /usr/libexec/opl-netfleet-compat >&2
if [ -f /tmp/compat-runtime/compat-manifest.json ]; then
 sha256sum /etc/opl-netfleet/compatibility/ca/mitmproxy-ca.pem >/tmp/compat-ca.sha256
 python3 - <<'PY'
import os, py_compile, subprocess
from pathlib import Path
source = Path('/usr/libexec/opl-netfleet-compat/isolation.py')
original, stamp = source.read_bytes(), source.stat()
stale = original.replace(b'"cpu.max": "50000 100000"})', b'"cpu.max": "20000 100000"})')
assert stale != original and len(stale) == len(original)
try:
    source.write_bytes(stale)
    os.utime(source, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
    py_compile.compile(str(source), doraise=True)
finally:
    source.write_bytes(original)
    os.utime(source, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
check = "import sys; sys.path.insert(0, '/usr/libexec/opl-netfleet-compat'); import isolation; assert '20000 100000' in isolation.constrain_manager.__code__.co_consts"
subprocess.run(['python3', '-c', check], check=True)
PY
 apk add --force-reinstall /tmp/compat-runtime/*.apk >&2
 python3 -B - <<'PY'
import sys
from pathlib import Path
root = Path('/usr/libexec/opl-netfleet-compat')
assert not list(root.rglob('*.pyc'))
sys.path.insert(0, str(root))
import isolation
assert '50000 100000' in isolation.constrain_manager.__code__.co_consts
PY
 sha256sum -c /tmp/compat-ca.sha256 >&2
 apk del opl-netfleet-https-compat >&2
 sha256sum -c /tmp/compat-ca.sha256 >&2
 ! nft list table inet netfleet_compat 2>/dev/null
 test ! -x /usr/libexec/opl-netfleet-compat/haproxy
 if [ -f /tmp/compat-runtime/device-identity-manifest.json ]; then
  apk del opl-netfleet-plugin-device-identity >&2
  test ! -f /usr/libexec/opl-netfleet/plugins/device-identity/control
 fi
 ubus call system board >/dev/null
fi
python3 - "$commit" "$tree" <<'PY'
import json, sys
from pathlib import Path
print(json.dumps({"ok": True, "source_commit": sys.argv[1], "source_tree": sys.argv[2],
                  "checks": {"musl_runtime": True, "protocol_wire": True, "kernel_lease": True, "controller_procd": True, "native_egress": True, "device_identity": True},
                  "resources": json.loads(Path('/tmp/compat-resources.json').read_text()),
                  "signed_package_lifecycle": Path('/tmp/compat-runtime/compat-manifest.json').exists(), "production_ready": False}))
PY
