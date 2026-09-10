#!/bin/sh
# Native-runtime diagnostic lane; no Python is installed in this guest.
set -eu
umask 077
commit=${1:?}
tree=${2:?}
feed_url=${3:?}
probe_port=${4:?}
work=/tmp/compat-native-fixture
mkdir -p "$work"
stage=dependencies
failure() {
 rc=$?
 [ "$rc" -eq 0 ] && return
 printf 'Native compatibility failed at %s\n' "$stage" >&2
 ubus call service list '{"name":"opl-netfleet-compat"}' >&2 || true
 for file in /var/run/opl-netfleet-compat/state.json "$work"/*.log; do
  [ ! -f "$file" ] || tail -35 "$file" >&2
 done
}
trap failure EXIT
test "$(uname -m)" = aarch64
test "$(readlink /var)" = tmp
ip route replace default via 192.168.1.2
printf 'nameserver 192.168.1.3\n' >/etc/resolv.conf
apk update >"$work/packages.log" 2>&1
apk add curl ca-bundle openssl-util coreutils-timeout ucode-mod-fs ucode-mod-digest ucode-mod-uloop kmod-veth >>"$work/packages.log" 2>&1
ucode - "$commit" "$tree" <<'UC'
import * as fs from 'fs';
import {sha256} from 'digest';
const root='/tmp/compat-runtime';
for(let name in ['compat-manifest.json','device-identity-manifest.json']) {
 const m=json(fs.readfile(root+'/'+name));
 if(m.source_commit!=ARGV[0]||m.source_tree!=ARGV[1]||fs.basename(m.artifact)!=m.artifact||sha256(fs.readfile(root+'/'+m.artifact))!=m.sha256) die('native_package_identity_mismatch');
}
UC
stage=install
curl -fsS "$feed_url/install-netfleet.sh" -o "$work/install.sh"
NETFLEET_FEED_BASE="$feed_url" NETFLEET_ALLOW_INSECURE_FEED=1 sh "$work/install.sh" >>"$work/packages.log" 2>&1
cp /tmp/compat-runtime/compat-public-key.pem /etc/apk/keys/netfleet-native-test.pem
apk verify /tmp/compat-runtime/*.apk >>"$work/packages.log" 2>&1
apk add /tmp/compat-runtime/*.apk >>"$work/packages.log" 2>&1
check_native() {
 ! command -v python3 >/dev/null
 ! command -v python >/dev/null
 ! command -v node >/dev/null
 apk info >"$work/installed-packages"
 ! grep -E '^(python|pypy|libpython|nodejs|node-)' "$work/installed-packages"
 test -z "$(find /usr/libexec/opl-netfleet-compat /usr/libexec/opl-netfleet/plugins -name '*.py' -o -name '*.pyc')"
}
check_native
mkdir -p /etc/opl-netfleet
printf '{"kind":"native-mihomo"}\n' >/etc/opl-netfleet/backend.json
chmod 0600 /etc/opl-netfleet/backend.json
cp /usr/share/opl-netfleet/netfleet.config /etc/config/netfleet
chmod 0600 /etc/config/netfleet
sha256sum /etc/config/netfleet >/tmp/compat-base-before.sha256
stage=control_entry
ucode /tmp/tests/async_process_capture.uc /usr/libexec/opl-netfleet /usr/libexec/opl-netfleet-compat >"$work/async-capture.log" 2>&1
ucode /tmp/tests/async_health_socket.uc /usr/libexec/opl-netfleet-compat >>"$work/async-capture.log" 2>&1
ucode /tmp/tests/https_native_health.uc /usr/libexec/opl-netfleet-compat >"$work/health-fields.log" 2>&1
ucode /tmp/tests/https_native_policy_bounds.uc /usr/libexec/opl-netfleet-compat >"$work/policy-bounds.log" 2>&1
ucode /tmp/tests/https_native_guest.uc load >"$work/load.log" 2>&1
ucode /tmp/tests/device_identity_native_entry.uc /usr/libexec/opl-netfleet/plugins/device-identity/control >"$work/identity.log" 2>&1
ucode /tmp/tests/device_identity_native.uc /usr/libexec/opl-netfleet /usr/libexec/opl-netfleet/plugins/device-identity/resources/neighbor >>"$work/identity.log" 2>&1
NETFLEET_ISOLATED_NATIVE_TEST=1 sh /tmp/tests/native-neighbor-wire.sh /usr/libexec/opl-netfleet/plugins/device-identity/resources/neighbor >>"$work/identity.log" 2>&1
ucode /tmp/tests/https_native_recovery.uc /usr/libexec/opl-netfleet-compat >"$work/recovery.log" 2>&1
ucode /tmp/tests/https_native_guest.uc enable >"$work/enable.log" 2>&1
stage=procd
for attempt in $(seq 1 40); do
 if /usr/libexec/opl-netfleet-compat/tls-probe local /var/run/opl-netfleet-compat 0 "$(id -u netfleet-compat)" >"$work/probe.json"; then break; fi
 sleep 1
done
test "$(jsonfilter -i "$work/probe.json" -e '@.ok')" = true
ubus call service list '{"name":"opl-netfleet-compat"}' >"$work/procd.json"
test "$(jsonfilter -i "$work/procd.json" -e '@["opl-netfleet-compat"].instances.engine.running')" = true
test "$(jsonfilter -i "$work/procd.json" -e '@["opl-netfleet-compat"].instances.manager.running')" = true
for group in netfleet-compat netfleet-compat-manager; do
 test "$(cat /sys/fs/cgroup/$group/cpu.max)" = '50000 100000'
 test "$(cat /sys/fs/cgroup/$group/memory.swap.max)" = 0
 cat /sys/fs/cgroup/$group/cpu.stat >"$work/$group-cpu-before"
 cat /sys/fs/cgroup/$group/memory.current >"$work/$group-rss"
done
sha256sum /etc/opl-netfleet/compatibility/ca/mitmproxy-ca.pem >"$work/ca.sha256"
sleep 10
stage=kernel_lease
# Stop only this optional manager while exercising the installed gateway service.
ubus call service delete '{"name":"opl-netfleet-compat","instance":"manager"}'
mkdir -p /etc/opl-netfleet/native/run /var/run/opl-netfleet-core
chmod 0700 /etc/opl-netfleet/native /etc/opl-netfleet/native/run /var/run/opl-netfleet-core
printf '{"rules":["MATCH,DIRECT"]}' >/etc/opl-netfleet/native/run/config.yaml
engine_pid=$(jsonfilter -i "$work/procd.json" -e '@["opl-netfleet-compat"].instances.engine.pid')
nft add table inet base_fixture
ucode /tmp/tests/interception_native_kernel.uc "$engine_pid" /usr/libexec/opl-netfleet netfleet-compat >"$work/leases.log" 2>&1
nft list table inet base_fixture >/dev/null
nft delete table inet base_fixture
/etc/init.d/opl-netfleet-compat start >>"$work/enable.log" 2>&1
stage=disable
ucode /tmp/tests/https_native_guest.uc disable >"$work/disable.log" 2>&1
for attempt in $(seq 1 15); do
 ubus call service list '{"name":"opl-netfleet-compat"}' >"$work/procd.json"
 [ "$(jsonfilter -i "$work/procd.json" -e '@["opl-netfleet-compat"].instances.engine.running')" = true ] || break
 sleep 1
done
test "$(jsonfilter -i "$work/procd.json" -e '@["opl-netfleet-compat"].instances.engine.running')" != true
sha256sum -c /tmp/compat-base-before.sha256 >&2
stage=uninstall
apk del opl-netfleet-https-compat >>"$work/packages.log" 2>&1
test ! -e /usr/libexec/opl-netfleet-compat/launcher
sha256sum -c "$work/ca.sha256" >&2
stage=reinstall
apk add /tmp/compat-runtime/opl-netfleet-https-compat-*.apk >>"$work/packages.log" 2>&1
check_native
sha256sum -c "$work/ca.sha256" >&2
sha256sum -c /tmp/compat-base-before.sha256 >&2
ucode /tmp/tests/https_native_guest.uc state >"$work/final.json"
test "$(jsonfilter -i "$work/final.json" -e '@.requested')" = false
test "$(jsonfilter -i "$work/final.json" -e '@.intercepting')" = false
stage=network
touch /tmp/netfleet-compat-vm-authorized
sh /tmp/tests/https_native_network.sh "$probe_port" >"$work/network.log" 2>&1
stage=complete
ucode - "$commit" "$tree" <<'UC'
import * as fs from 'fs';
printf('%J\n',{ok:true,source_commit:ARGV[0],source_tree:ARGV[1],checks:{native_dependency_closure:true,real_control_entry:true,procd_launcher:true,local_h1_to_h2:true,resource_limits:true,user_disable:true,uninstall_reinstall:true,stable_ca:true,base_configuration_unchanged:true,local_address_rotation:true,address_conflict_expiry:true,dual_stack_kernel_lease:true,real_gateway_h2:true,original_routing:true,sni_and_unknown_device_bypass:true,address_update_without_restart:true,streaming_upload_and_sse:true,cancellation_and_business_errors:true,simultaneous_stall_fail_open:true,third_fault_latch:true,manual_recovery:true,base_pid_unchanged:true},metrics:json(fs.readfile('/tmp/https-native-network/performance.json')),production_ready:false});
UC
