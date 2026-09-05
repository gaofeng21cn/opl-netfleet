#!/bin/sh
# Disposable native data-plane experiment. Never installed by either package.
set -eu
umask 077

commit=${1:?}
tree=${2:?}
probe_port=${3:?}
work=/tmp/netfleet-native-fixture
stage=precondition
helper_pid=
dns_pid=
udp_pid=
test -f /tmp/netfleet-native-vm-authorized
test ! -e /etc/init.d/nikki
test -z "$(pidof mihomo 2>/dev/null || true)"
mkdir -p "$work/bin" "$work/run"

finish() {
	rc=$?
	trap - EXIT INT TERM
	set +e
	/etc/init.d/netfleet-native-vm stop >/dev/null 2>&1
	ucode /usr/libexec/opl-netfleet/main.uc native-core-stop >/dev/null 2>&1
	for pid in "$helper_pid" "$dns_pid" "$udp_pid"; do
		[ -z "$pid" ] || kill "$pid" 2>/dev/null
	done
	ip netns del nf-client 2>/dev/null
	ip link del nf-lan 2>/dev/null
	nft delete table ip netfleet_native_fixture 2>/dev/null
	if [ "$rc" -ne 0 ]; then
		echo "Native experiment failed at: $stage" >&2
		for file in "$work"/*.log "$work"/source-*.json "$work/proxies.json" "$work/delay.json"; do
			[ ! -f "$file" ] || { echo "--- $file" >&2; tail -60 "$file" >&2; }
		done
	fi
	exit "$rc"
}
trap finish EXIT INT TERM

stage=dependencies
ip route replace default via 192.168.1.2 dev br-lan
printf 'nameserver 192.168.1.3\n' >/etc/resolv.conf
apk --timeout 120 update >"$work/packages.log" 2>&1 || true
apk --timeout 120 add curl ip-full kmod-veth kmod-nft-tproxy kmod-nft-socket socat bind-dig \
	>>"$work/packages.log" 2>&1
gzip -dc /tmp/mihomo-linux-arm64-v1.19.30.gz >"$work/bin/mihomo"
chmod 0755 "$work/bin/mihomo"
ln -s "$work/bin/mihomo" /usr/bin/mihomo
ln "$work/bin/mihomo" "$work/bin/nf-proxy-fixture"
cp /tmp/yq_linux_arm64-v4.53.6 "$work/bin/yq"
chmod 0755 "$work/bin/yq"
export PATH="$work/bin:/usr/sbin:/usr/bin:/sbin:/bin"
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY

stage=isolated_lan
ip netns add nf-client
ip link add nf-lan type veth peer name nf-peer
ip link set nf-peer netns nf-client
ip addr add 198.18.0.1/30 dev nf-lan
ip link set nf-lan up
ip netns exec nf-client ip link set lo up
ip netns exec nf-client ip addr add 198.18.0.2/30 dev nf-peer
ip netns exec nf-client ip link set nf-peer up
ip netns exec nf-client ip route add default via 198.18.0.1
# Give only the disposable LAN endpoint an explicit fw4 zone.
uci set firewall.nfexperiment=zone
uci set firewall.nfexperiment.name=nfexperiment
uci add_list firewall.nfexperiment.device=nf-lan
uci set firewall.nfexperiment.input=ACCEPT
uci set firewall.nfexperiment.output=ACCEPT
uci set firewall.nfexperiment.forward=ACCEPT
uci set firewall.nfexperiment_forward=forwarding
uci set firewall.nfexperiment_forward.src=nfexperiment
uci set firewall.nfexperiment_forward.dest=lan
/etc/init.d/firewall reload >"$work/firewall.log" 2>&1
# The fixture redirects only router-originated traffic to local test servers.
# A forwarded client request to the test address must fail without TProxy.
nft -f - <<EOF
table ip netfleet_native_fixture {
	chain output {
		type nat hook output priority -101; policy accept;
		ip daddr 198.19.0.1 tcp dport $probe_port dnat to 192.168.1.2:$probe_port
		ip daddr 198.19.0.1 udp dport 19999 dnat to 127.0.0.1:19999
	}
	chain forward {
		type filter hook forward priority -1; policy accept;
		iifname "nf-lan" ip daddr 198.19.0.1 counter reject
	}
	chain postrouting {
		type nat hook postrouting priority 101; policy accept;
		ip saddr 198.18.0.0/30 oifname "br-lan" masquerade
	}
}
EOF
nft -s list table ip netfleet_native_fixture >"$work/foreign-rules.txt"
dnsmasq --keep-in-foreground --port=1053 --listen-address=127.0.0.1 --bind-interfaces \
	--no-resolv --no-hosts --address=/native-proof.test/203.0.113.42 \
	--pid-file="$work/dns.pid" >"$work/dns.log" 2>&1 &
dns_pid=$!
socat UDP4-RECVFROM:19999,bind=127.0.0.1,fork EXEC:/bin/cat >"$work/udp.log" 2>&1 &
udp_pid=$!
cat >"$work/helper.json" <<'EOF'
{"mixed-port":1081,"external-controller":"127.0.0.1:19091","mode":"direct","log-level":"warning","ipv6":false}
EOF
"$work/bin/nf-proxy-fixture" -d "$work" -f "$work/helper.json" >"$work/helper.log" 2>&1 &
helper_pid=$!

stage=compile_without_nikki
cp -R /tmp/openwrt/files/usr/libexec/opl-netfleet /usr/libexec/
mkdir -p /etc/opl-netfleet
cat /tmp/local-probe.crt >>/etc/ssl/certs/ca-certificates.crt
main=/usr/libexec/opl-netfleet/main.uc
stage=source_contracts
for contract in /tmp/tests/*_contract.uc; do
	ucode "$contract" >>"$work/contracts.log" 2>&1
done
stage=native_source_owner
ucode "$main" native-sources-get >"$work/source-empty.json"
cat >"$work/sources.json" <<EOF
{"schema_version":1,"sources":[{"id":"fixture","display_name":"VM source","enabled":true,"url":"https://192.168.1.2:$probe_port/native-subscriptions/valid?token=vm-only-credential"}]}
EOF
chmod 0600 "$work/sources.json"
ucode -e 'import { validate } from "/usr/libexec/opl-netfleet/core/native_sources.uc"; import { readfile } from "fs"; const result = validate(json(readfile(ARGV[0]))); if (!result.ok) die(sprintf("%J", result));' "$work/sources.json"
ucode "$main" native-sources-set "$work/sources.json" >"$work/source-set.json"
ucode "$main" native-sources-refresh >"$work/source-refresh.json"
[ "$(jsonfilter -i "$work/source-refresh.json" -e '@.result.sources[0].ready')" = true ]
[ "$(jsonfilter -i "$work/source-refresh.json" -e '@.result.sources[0].last_result')" = updated ]
ucode "$main" native-sources-refresh fixture >"$work/source-unchanged.json"
[ "$(jsonfilter -i "$work/source-unchanged.json" -e '@.result.sources[0].last_result')" = unchanged ]
cache=/etc/opl-netfleet/native/cache/fixture.json
ucode -e 'import { stat } from "fs"; if ((stat(ARGV[0]).mode & 0777) != 0600 || (stat("/etc/opl-netfleet/native").mode & 0777) != 0700) die("private modes");' "$cache"
if grep -q 'vm-only-credential' "$work/source-set.json" "$work/source-refresh.json" "$cache"; then exit 1; fi
if jsonfilter -i "$cache" -e '@.dns' | grep -q .; then exit 1; fi
ucode /tmp/tests/native_sources_integration.uc >"$work/source-integration.log" 2>&1
stage=compile_without_nikki
cat >"$work/compile.uc" <<'EOF'
import { compile } from "/usr/libexec/opl-netfleet/core/compiler.uc";
import * as fs from "fs";
const dir = "/tmp/netfleet-native-fixture";
const probe_url = ARGV[0];
const cache = "/etc/opl-netfleet/native/cache/fixture.json";
const nodes = json(fs.readfile(cache));
const source = {
 "proxy-groups": [{ name: "Outbound", type: "select", proxies: ["DIRECT"] }],
 rules: ["MATCH,Outbound"]
};
const policy = {
 schema_version: 2, main: { target: "vm-fixture", enabled: true },
 policy_source: { kind: "profile", ref: "file:fixture.json" },
 recovery_profile: { ref: "file:fixture.json" },
 bindings: { Outbound: { capability: "standard", kind: "entry" } },
 providers: { fixture: { section: "fixture", enabled: true, role: "primary" } },
 regions: { test: { mode: "automatic", display_name: "Test", flag: "ZZ" } },
 provider_regions: { fixture: [{ region: "test", filter: "native-region" }] },
 capabilities: { standard: { enabled: true, mode: "manual" } },
 selection: { region_switch_margin_ms: 150, leaf_switch_margin_ms: 150 },
 checks: { provider_healthcheck_timeout_ms: 2000, latency: { method: "mihomo_delay", url: probe_url, timeout_ms: 1000, expected_status: 204 } },
 fail_open: { healthcheck: { path_probe_id: "test", guard_probe_id: "test", timeout_ms: 1000, interval_seconds: 300, max_failed_times: 2 },
  probes: [{ id: "test", url: probe_url, expected_status: 204 }] }
};
const result = compile(source, policy, "fixture", "fixture", "fixture", {
 fixture: { path: cache, runtime_path: cache, profile: nodes }
});
if (!result.ok) die(sprintf("%J", result.errors));
const config = result.profile;
config["mixed-port"] = 17890;
config["tproxy-port"] = 17893;
config["external-controller"] = "127.0.0.1:19090";
config.secret = "native-vm-fixture";
config["allow-lan"] = true;
config["bind-address"] = "*";
config.ipv6 = false;
config.mode = "rule";
config["log-level"] = "info";
config.dns = { enable: true, listen: "0.0.0.0:1054", "enhanced-mode": "redir-host", ipv6: false, nameserver: ["udp://127.0.0.1:1053"] };
fs.writefile(`${dir}/run/config.json`, sprintf("%J", config));
fs.writefile(`${dir}/manifest.json`, sprintf("%J", result.manifest));
EOF
cat /tmp/local-probe.crt >>/etc/ssl/certs/ca-certificates.crt
printf '192.168.1.2 netfleet-probe.test\n' >>/etc/hosts
ucode "$work/compile.uc" "https://192.168.1.2:$probe_port/generate_204" >"$work/compile.log" 2>&1
SAFE_PATHS=/etc/opl-netfleet/native/cache mihomo -t -d "$work/run" -f "$work/run/config.json" >"$work/validate.log" 2>&1

stage=native_core_lifecycle
nft -s list ruleset >"$work/core-before.nft"
ip -4 rule show >"$work/core-before.rules"
ucode /tmp/tests/native_core_integration.uc "$probe_port" >"$work/core-integration.log" 2>&1
nft -s list ruleset | cmp - "$work/core-before.nft"
ip -4 rule show | cmp - "$work/core-before.rules"
test -z "$(pidof mihomo 2>/dev/null || true)"
test ! -e /etc/opl-netfleet/native/core/controller.sock

stage=service_owner
# This disposable owner intentionally has no boot enable, migration or refresh.
cat >"$work/owner.sh" <<'EOF'
#!/bin/sh
set -eu
work=/tmp/netfleet-native-fixture
export SAFE_PATHS=/etc/opl-netfleet/native/cache
child=
cleanup() {
	trap - EXIT INT TERM
	rm -f "$work/ready"
	nft delete table ip opl_netfleet_native_vm 2>/dev/null || true
	ip -4 rule del pref 11900 fwmark 0x40000000/0x40000000 lookup 11900 2>/dev/null || true
	ip -4 route del local default dev lo table 11900 2>/dev/null || true
	if [ -n "$child" ]; then kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; fi
}
# A conflicting owner is rejected before any network mutation.
test -z "$(pidof mihomo 2>/dev/null || true)"
test ! -e /etc/init.d/nikki
if nft list table ip opl_netfleet_native_vm >/dev/null 2>&1; then exit 1; fi
"$work/bin/mihomo" -t -d "$work/run" -f "$work/run/config.json" >"$work/validate.log" 2>&1
trap cleanup EXIT
trap 'exit 0' INT TERM
"$work/bin/mihomo" -d "$work/run" -f "$work/run/config.json" >"$work/core.log" 2>&1 &
child=$!
echo "$child" >"$work/core.pid"
ready=false
for attempt in 1 2 3 4 5 6 7 8 9 10; do
	if curl -fsS --noproxy '*' -H 'Authorization: Bearer native-vm-fixture' \
		--max-time 1 http://127.0.0.1:19090/version >"$work/version.json"; then ready=true; break; fi
	kill -0 "$child"
	sleep 1
done
[ "$ready" = true ]
ip -4 route add local default dev lo table 11900
ip -4 rule add pref 11900 fwmark 0x40000000/0x40000000 lookup 11900
nft -f - <<'NFT'
table ip opl_netfleet_native_vm {
	chain dns {
		type nat hook prerouting priority -101; policy accept;
		iifname "nf-lan" meta l4proto { tcp, udp } th dport 53 counter redirect to :1054
	}
	chain proxy {
		type filter hook prerouting priority -149; policy accept;
		iifname "nf-lan" meta l4proto { tcp, udp } th dport 53 return
		iifname "nf-lan" ip daddr 198.19.0.1 meta l4proto { tcp, udp } counter tproxy to :17893 meta mark set 0x40000000 accept
	}
}
NFT
touch "$work/ready"
wait "$child"
EOF
chmod 0755 "$work/owner.sh"
cat >/etc/init.d/netfleet-native-vm <<'EOF'
#!/bin/sh /etc/rc.common
USE_PROCD=1
start_service() {
	procd_open_instance core
	procd_set_param command /tmp/netfleet-native-fixture/owner.sh
	procd_set_param stdout 0
	procd_set_param stderr 1
	procd_set_param term_timeout 5
	procd_close_instance
}
stop_service() {
	nft delete table ip opl_netfleet_native_vm 2>/dev/null || true
	ip -4 rule del pref 11900 fwmark 0x40000000/0x40000000 lookup 11900 2>/dev/null || true
	ip -4 route del local default dev lo table 11900 2>/dev/null || true
}
EOF
chmod 0755 /etc/init.d/netfleet-native-vm
start_native() {
	/etc/init.d/netfleet-native-vm start
	for attempt in 1 2 3 4 5 6 7 8 9 10; do
		[ ! -f "$work/ready" ] || return 0
		sleep 1
	done
	return 1
}
assert_clean() {
	if nft list table ip opl_netfleet_native_vm >/dev/null 2>&1; then return 1; fi
	if ip -4 rule show | grep -q '11900:'; then return 1; fi
	[ -z "$(ip -4 route show table 11900 2>/dev/null)" ] || return 1
	[ -z "$(pidof mihomo 2>/dev/null || true)" ] || return 1
	nft -s list table ip netfleet_native_fixture | cmp - "$work/foreign-rules.txt"
}
wait_clean() {
	for attempt in 1 2 3 4 5 6; do
		if assert_clean; then return 0; fi
		sleep 1
	done
	return 1
}
tcp_probe() {
	ip netns exec nf-client curl -fsS --noproxy '*' --connect-timeout 2 --max-time 5 \
		--cacert /tmp/local-probe.crt --resolve "netfleet-probe.test:$probe_port:198.19.0.1" \
		"https://netfleet-probe.test:$probe_port/generate_204"
}
direct_probe() {
	ip netns exec nf-client curl -fsS --noproxy '*' --connect-timeout 2 --max-time 5 \
		--cacert /tmp/local-probe.crt --resolve "netfleet-probe.test:$probe_port:192.168.1.2" \
		"https://netfleet-probe.test:$probe_port/generate_204"
}
stage=negative_control
direct_probe >"$work/direct-before.log" 2>&1
if tcp_probe >"$work/bypass.log" 2>&1; then exit 1; fi
start_native
stage=owner_readback
ubus call service list '{"name":"netfleet-native-vm"}' >"$work/service.json"
[ "$(jsonfilter -i "$work/service.json" -e '@["netfleet-native-vm"].instances.core.running')" = true ]
core_pid=$(cat "$work/core.pid")
tr '\0' ' ' <"/proc/$core_pid/cmdline" | grep -Fq "$work/run/config.json"
stage=owner_conflict
nft -s list table ip opl_netfleet_native_vm >"$work/owner-rules.txt"
if sh "$work/owner.sh" >"$work/conflict.log" 2>&1; then exit 1; fi
[ -f "$work/ready" ]
kill -0 "$core_pid"
nft -s list table ip opl_netfleet_native_vm | cmp - "$work/owner-rules.txt"
curl -fsS --noproxy '*' -H 'Authorization: Bearer native-vm-fixture' \
	http://127.0.0.1:19090/proxies >"$work/proxies.json"
grep -q 'native-region-node' "$work/proxies.json"
stage=provider_readiness
ucode -e '
 import { url_path_segment } from "/usr/libexec/opl-netfleet/adapters/mihomo.uc";
 import { shell_quote } from "/usr/libexec/opl-netfleet/adapters/uci.uc";
 import { readfile } from "fs";
 const manifest = json(readfile("/tmp/netfleet-native-fixture/manifest.json"));
 for (let group in manifest.generated_groups.standard.candidate_groups)
   if (system("curl -fsS --noproxy \x27*\x27 -X DELETE -H \x27Authorization: Bearer native-vm-fixture\x27 " +
     shell_quote("http://127.0.0.1:19090/proxies/" + url_path_segment(group.name))) != 0) die("candidate reset failed");
' >"$work/reset.log" 2>&1
curl -fsS --noproxy '*' --max-time 8 -H 'Authorization: Bearer native-vm-fixture' \
	http://127.0.0.1:19090/providers/proxies/NETFLEET-SOURCE-fixture/healthcheck >"$work/health.log"
curl -fsS --noproxy '*' --max-time 8 -H 'Authorization: Bearer native-vm-fixture' --get \
	--data-urlencode "url=https://192.168.1.2:$probe_port/generate_204" --data-urlencode timeout=3000 \
	http://127.0.0.1:19090/group/standard/delay >"$work/delay.json"
# Select the compiled region through the actual controller, then require the
# helper's byte counters to move so a DIRECT fallback cannot pass this proof.
ucode -e '
 import * as fs from "fs";
 const m = json(fs.readfile("/tmp/netfleet-native-fixture/manifest.json"));
 print(sprintf("%J", { name: m.generated_groups.standard.region_groups[0].name }));
' >"$work/choice.json"
curl -fsS --noproxy '*' -X PUT -H 'Authorization: Bearer native-vm-fixture' \
	-H 'Content-Type: application/json' --data-binary "@$work/choice.json" \
	http://127.0.0.1:19090/proxies/standard
helper_bytes() {
	curl -fsS --noproxy '*' http://127.0.0.1:19091/connections | jsonfilter -e '@.downloadTotal'
}
before_bytes=$(helper_bytes)
stage=lan_tcp
tcp_probe >"$work/tcp.log" 2>&1
[ "$(helper_bytes)" -gt "$before_bytes" ]
stage=lan_udp
before_bytes=$(helper_bytes)
answer=$(printf 'native-udp-proof\n' | ip netns exec nf-client socat -T 2 - UDP4:198.19.0.1:19999)
[ "$answer" = native-udp-proof ]
[ "$(helper_bytes)" -gt "$before_bytes" ]
stage=lan_dns
ip netns exec nf-client dig +short +tries=1 +time=2 @203.0.113.53 native-proof.test >"$work/dns-udp.log"
grep -qx 203.0.113.42 "$work/dns-udp.log"
ip netns exec nf-client dig +tcp +short +tries=1 +time=2 @203.0.113.53 native-proof.test >"$work/dns-tcp.log"
grep -qx 203.0.113.42 "$work/dns-tcp.log"
stage=normal_stop
/etc/init.d/netfleet-native-vm stop
wait_clean
direct_probe >"$work/direct-after-stop.log" 2>&1
/etc/init.d/netfleet-native-vm stop
assert_clean
stage=core_failure
start_native
kill -KILL "$(cat "$work/core.pid")"
for attempt in 1 2 3 4 5; do
	[ -f "$work/ready" ] || break
	sleep 1
done
wait_clean
direct_probe >"$work/direct-after-crash.log" 2>&1
stage=invalid_config
cp "$work/run/config.json" "$work/valid.json"
printf '{broken' >"$work/run/config.json"
/etc/init.d/netfleet-native-vm restart
sleep 2
assert_clean
cp "$work/valid.json" "$work/run/config.json"
stage=complete
printf '{"ok":true,"scope":"native-ipv4-experiment","production_ready":false,"source_commit":"%s","source_tree":"%s","checks":{"source_contracts":true,"source_cli_download":true,"source_unchanged_cache":true,"source_failure_retains_cache":true,"source_identity_isolation":true,"source_partial_refresh":true,"source_removal_cleanup":true,"source_lock_zero_mutation":true,"source_private_storage":true,"source_no_credentials_in_output":true,"no_nikki":true,"shared_compiler":true,"config_validation":true,"procd_owner":true,"controller":true,"owner_conflict_zero_mutation":true,"bypass_negative_control":true,"provider_proxy_traffic":true,"lan_tcp_tproxy":true,"lan_udp_tproxy":true,"lan_dns_udp":true,"lan_dns_tcp":true,"normal_stop_cleanup":true,"repeated_stop":true,"core_crash_cleanup":true,"direct_after_stop":true,"direct_after_crash":true,"invalid_config_no_interception":true,"foreign_rules_preserved":true}}\n' "$commit" "$tree"
