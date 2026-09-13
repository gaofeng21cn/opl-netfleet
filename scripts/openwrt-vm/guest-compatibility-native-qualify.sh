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
# Repository transport failures are retried only before any NetFleet installation.
index_ready=0
for attempt in 1 2 3; do
 if apk --timeout 15 update >>"$work/packages.log" 2>&1; then index_ready=1;break;fi
done
test "$index_ready" = 1
apk add curl ca-bundle openssl-util coreutils-timeout ucode-mod-fs ucode-mod-digest ucode-mod-uloop kmod-veth libatomic1 >>"$work/packages.log" 2>&1
ucode - "$commit" "$tree" <<'UC'
import * as fs from 'fs';
import {sha256} from 'digest';
const root='/tmp/compat-runtime';
const identity=fs.readfile('/tmp/compat-device-identity.json');
for(let name in ['compat-manifest.json','device-identity-manifest.json']) {
 const m=json(fs.readfile(root+'/'+name));
 const expected=name=='device-identity-manifest.json'&&identity?json(identity):{source_commit:ARGV[0],source_tree:ARGV[1]};
 if(name=='device-identity-manifest.json'&&identity&&sprintf('%J',m)!=sprintf('%J',expected)) die('native_identity_manifest_mismatch');
 if(m.source_commit!=expected.source_commit||m.source_tree!=expected.source_tree||fs.basename(m.artifact)!=m.artifact||sha256(fs.readfile(root+'/'+m.artifact))!=m.sha256) die('native_package_identity_mismatch');
}
UC
stage=install
curl -fsS "$feed_url/install-netfleet.sh" -o "$work/install.sh"
NETFLEET_FEED_BASE="$feed_url" NETFLEET_ALLOW_INSECURE_FEED=1 sh "$work/install.sh" >>"$work/packages.log" 2>&1
cp /tmp/compat-runtime/compat-public-key.pem /etc/apk/keys/netfleet-native-test.pem
apk verify /tmp/compat-runtime/*.apk >>"$work/packages.log" 2>&1
# Exercise the public full-profile installer against the same signed optional feed.
# This loopback server exists only in the isolated guest and is stopped after install.
uhttpd -f -p 127.0.0.1:18081 -h /tmp/compat-runtime >"$work/optional-feed.log" 2>&1 &
optional_feed_pid=$!
for attempt in $(seq 1 20); do
 curl -fsS http://127.0.0.1:18081/compat-packages.adb -o /dev/null && break
 sleep 1
done
NETFLEET_INSTALL_PROFILE=full NETFLEET_FEED_BASE="$feed_url" \
 NETFLEET_COMPAT_FEED_BASE=http://127.0.0.1:18081 NETFLEET_ALLOW_INSECURE_FEED=1 \
 sh "$work/install.sh" >>"$work/packages.log" 2>&1
kill "$optional_feed_pid"
if [ -f /tmp/compat-runtime/retained-base/retained-base.json ]; then
 stage=retained_base
 touch /tmp/netfleet-retained-base-vm-authorized
 ucode /tmp/tests/https_retained_base.uc >"$work/retained-base.json" 2>"$work/retained-base.log"
fi
/usr/libexec/opl-netfleet/main.uc compatibility-get >"$work/default-off.json"
test "$(jsonfilter -i "$work/default-off.json" -e '@.result.requested')" = false
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
ucode /tmp/tests/https_native_profile.uc /usr/libexec/opl-netfleet-compat >"$work/profile-test.log" 2>&1
NETFLEET_COMPAT_PROFILE=1 ucode /tmp/tests/https_native_profile.uc /usr/libexec/opl-netfleet-compat >>"$work/profile-test.log" 2>&1
ucode /tmp/tests/async_process_capture.uc /usr/libexec/opl-netfleet /usr/libexec/opl-netfleet-compat >"$work/async-capture.log" 2>&1
ucode /tmp/tests/async_health_socket.uc /usr/libexec/opl-netfleet-compat >>"$work/async-capture.log" 2>&1
ucode /tmp/tests/https_native_health.uc /usr/libexec/opl-netfleet-compat >"$work/health-fields.log" 2>&1
ucode /tmp/tests/https_native_policy_bounds.uc /usr/libexec/opl-netfleet-compat >"$work/policy-bounds.log" 2>&1
ucode /tmp/tests/https_native_identity_time.uc /usr/libexec/opl-netfleet-compat /usr/libexec/opl-netfleet/plugins/device-identity/resources/identity.uc >"$work/identity-time.log" 2>&1
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
# New raw I/O fixture owns only disposable tables before the base is activated.
nft -f - <<'NFT'
table inet netfleet {
 set lan_inbound_device { type ifname; elements = { "br-lan", "nf-observe" }; }
 chain mangle_prerouting_lan { ct mark & 0x01000000 != 0 return; }
}
NFT
nft list table inet netfleet_compat >/dev/null 2>&1 && nft delete table inet netfleet_compat
nft -f - <<'NFT'
table inet netfleet_compat {
 set targets4 { type ipv4_addr . ipv4_addr . inet_service; flags interval,timeout; timeout 10s; }
 set targets6 { type ipv6_addr . ipv6_addr . inet_service; flags interval,timeout; timeout 10s; }
}
NFT
NETFLEET_ISOLATED_NATIVE_TEST=1 ucode /tmp/tests/interception_io_kernel.uc >"$work/native-io.log" 2>&1
nft delete table inet netfleet
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
const benchmark=fs.readfile('/tmp/https-native-network/benchmark.json');
printf('%J\n',{ok:true,source_commit:ARGV[0],source_tree:ARGV[1],checks:{...(fs.stat('/tmp/compat-runtime/upgrade.json')?{engine_package_cycle:true}:{}),...(fs.stat('/tmp/compat-runtime/retained-base/retained-base.json')?{retained_base_packages:json(fs.readfile('/tmp/compat-native-fixture/retained-base.json'))?.ok===true}:{}),dual_stack_probe_faults:true,native_kernel_io:true,native_dependency_closure:true,real_control_entry:true,procd_launcher:true,local_h1_to_h2:true,resource_limits:true,resource_pressure:true,user_disable:true,uninstall_reinstall:true,stable_ca:true,base_configuration_unchanged:true,local_address_rotation:true,address_conflict_expiry:true,dual_stack_kernel_lease:true,real_gateway_h2:true,original_routing:true,sni_and_unknown_device_bypass:true,address_update_without_restart:true,streaming_upload_and_sse:true,cancellation_and_business_errors:true,simultaneous_stall_fail_open:true,third_fault_latch:true,manual_recovery:true,base_pid_unchanged:true},profile:json(fs.readfile('/tmp/https-native-network/profile.json')),metrics:json(fs.readfile('/tmp/https-native-network/performance.json')),benchmark:benchmark?json(benchmark):null,production_ready:false});
UC
