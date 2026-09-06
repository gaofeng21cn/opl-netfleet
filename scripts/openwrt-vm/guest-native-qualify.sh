#!/bin/sh
# Exercise the shipped native owner inside an isolated, disposable OpenWrt VM.
set -eu
umask 077
commit=${1:?}
tree=${2:?}
probe_port=${3:?}
work=/tmp/netfleet-native-fixture
main=/usr/libexec/opl-netfleet/main.uc
gateway=/usr/libexec/opl-netfleet/application/native_gateway.uc
lock=/var/lock/opl-netfleet-deploy.lock
stage=precondition
fixture_pids=
test -f /tmp/netfleet-native-vm-authorized
test ! -e /etc/init.d/nikki
test -z "$(pidof mihomo 2>/dev/null || true)"
mkdir -p "$work/bin"
finish() {
	rc=$?
	trap - EXIT INT TERM
	set +e
	if [ "$rc" -ne 0 ]; then
		secret=$(uci -q get netfleet.mixin.api_secret)
		for endpoint in proxies providers/proxies; do
			curl -fsS --noproxy '*' --max-time 3 -H "Authorization: Bearer $secret" \
				"http://127.0.0.1:9090/$endpoint" >"$work/controller-${endpoint%%/*}.log"
		done
	fi
	/etc/init.d/opl-netfleet stop >/dev/null 2>&1
	/etc/init.d/opl-netfleet-core stop >/dev/null 2>&1
	for pid in $fixture_pids; do kill "$pid" 2>/dev/null; done
	ubus call network.interface.wan remove >/dev/null 2>&1
	ubus call network.interface.nfclient remove >/dev/null 2>&1
	ip netns del nf-client 2>/dev/null
	ip netns del nf-upstream 2>/dev/null
	ip link del nf-lan 2>/dev/null
	ip link del nf-uplink 2>/dev/null
	nft delete table ip netfleet_native_fixture 2>/dev/null
	nft delete table ip6 netfleet_native_fixture 2>/dev/null
	if [ "$rc" -ne 0 ]; then
		echo "Native runtime qualification failed at: $stage" >&2
		for file in "$work"/*.log "$work"/*-result.json; do
			[ ! -f "$file" ] || { echo "--- $file" >&2; tail -60 "$file" >&2; }
		done
		ubus call service list '{"name":"opl-netfleet-core"}' >&2
	fi
	exit "$rc"
}
trap finish EXIT INT TERM
run_main() { flock "$lock" ucode "$main" "$@"; }
assert_json() { [ "$(jsonfilter -i "$1" -e "$2")" = "$3" ]; }

stage=dependencies
ip route replace default via 192.168.1.2 dev br-lan
printf 'nameserver 192.168.1.3\n' >/etc/resolv.conf
apk --timeout 120 update >"$work/packages.log" 2>&1 || true
apk --timeout 120 add curl unzip coreutils-timeout ip-full kmod-veth kmod-nft-tproxy kmod-nft-socket socat bind-dig \
	ucode-mod-fs ucode-mod-uci ucode-mod-ubus ucode-mod-uloop >>"$work/packages.log" 2>&1
gzip -dc /tmp/mihomo-linux-arm64-v1.19.30.gz >"$work/bin/mihomo"
chmod 0755 "$work/bin/mihomo"
ln -s "$work/bin/mihomo" /usr/bin/mihomo
ln "$work/bin/mihomo" "$work/bin/nf-proxy-fixture"
cp /tmp/yq_linux_arm64-v4.53.6 "$work/bin/yq"
chmod 0755 "$work/bin/yq"
export PATH="$work/bin:/usr/sbin:/usr/bin:/sbin:/bin"
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
cp -R /tmp/openwrt/files/usr/libexec/opl-netfleet /usr/libexec/
mkdir -p /usr/share/opl-netfleet /etc/opl-netfleet/native/profiles /etc/opl-netfleet/native/subscriptions
cp -R /tmp/openwrt/files/usr/share/opl-netfleet/nikki /usr/share/opl-netfleet/
cp /tmp/openwrt/files/etc/config/netfleet /etc/config/netfleet
cp /tmp/openwrt/files/etc/init.d/opl-netfleet-core /etc/init.d/opl-netfleet-core
cp /tmp/openwrt/files/etc/init.d/opl-netfleet /etc/init.d/opl-netfleet
chmod 0755 "$main" /usr/libexec/opl-netfleet/supervisor.uc "$gateway" /etc/init.d/opl-netfleet-core /etc/init.d/opl-netfleet
chmod 0700 /etc/opl-netfleet/native /etc/opl-netfleet/native/profiles /etc/opl-netfleet/native/subscriptions
chmod 0600 /etc/config/netfleet
stage=source_contracts
for contract in /tmp/tests/*_contract.uc; do ucode "$contract" >>"$work/contracts.log" 2>&1; done
printf '{"kind":"native-mihomo"}\n' >/etc/opl-netfleet/backend.json
ucode /tmp/tests/backend_contract.uc native-mihomo >>"$work/contracts.log" 2>&1
cat /tmp/local-probe.crt >>/etc/ssl/certs/ca-certificates.crt
printf '192.168.1.2 netfleet-probe.test www.gstatic.com\n' >>/etc/hosts

stage=isolated_lan
ip netns add nf-client
ip link add nf-lan type veth peer name nf-peer
ip link set nf-peer netns nf-client
ip link set nf-lan up
ip netns exec nf-client ip link set lo up
ip netns exec nf-client ip addr add 198.18.0.2/30 dev nf-peer
ip netns exec nf-client ip -6 addr add 2001:db8:1::2/64 dev nf-peer nodad
ip netns exec nf-client ip link set nf-peer up
ubus call network add_dynamic '{"name":"nfclient","proto":"static","device":"nf-lan","ipaddr":["198.18.0.1/30"],"ip6addr":["2001:db8:1::1/64"]}' >"$work/nfclient-result.json"
ip netns exec nf-client ip route add default via 198.18.0.1
ip netns exec nf-client ip -6 route add default via 2001:db8:1::1
# A disposable real netifd WAN supplies the upstream API. QEMU's isolated
# br-lan remains the actual default route; no ubus or networking stubs are used.
ip netns add nf-upstream
ip netns exec nf-upstream ip link add nf-wan-peer type veth peer name nf-uplink netns 1
ip link set nf-uplink up
ip netns exec nf-upstream ip link set lo up
ip netns exec nf-upstream ip link set nf-wan-peer up
ip netns exec nf-upstream ip addr add 198.18.1.2/30 dev nf-wan-peer
ip netns exec nf-upstream ip addr add 198.19.0.1/32 dev lo
ip netns exec nf-upstream ip -6 addr add 2001:db8:3::2/64 dev nf-wan-peer nodad
ip netns exec nf-upstream ip -6 addr add 2001:db8:2::1/128 dev lo nodad
ip netns exec nf-upstream ip route add default via 198.18.1.1
ip netns exec nf-upstream ip -6 route add default via 2001:db8:3::1
ubus call network add_dynamic '{"name":"wan","proto":"static","device":"nf-uplink","ipaddr":["198.18.1.1/30"],"ip6addr":["2001:db8:3::1/64"]}' >"$work/wan-result.json"
ubus call network.interface.wan up >>"$work/wan-result.json"
for attempt in 1 2 3 4 5; do
	[ "$(ubus call network.interface.wan status | jsonfilter -e '@.up')" != true ] || break
	sleep 1
done
[ "$(ubus call network.interface.wan status | jsonfilter -e '@.up')" = true ]
ip route add 198.19.0.1/32 via 198.18.1.2 dev nf-uplink
ip -6 route add 2001:db8:2::1/128 via 2001:db8:3::2 dev nf-uplink
ip -6 route add 2001:db8:ffff::/48 via 2001:db8:3::2 dev nf-uplink
uci set firewall.nfexperiment=zone
uci set firewall.nfexperiment.name=nfexperiment
uci add_list firewall.nfexperiment.device=nf-lan
uci add_list firewall.nfexperiment.device=nf-uplink
uci set firewall.nfexperiment.input=ACCEPT
uci set firewall.nfexperiment.output=ACCEPT
uci set firewall.nfexperiment.forward=ACCEPT
uci set firewall.nfexperiment_forward=forwarding
uci set firewall.nfexperiment_forward.src=nfexperiment
uci set firewall.nfexperiment_forward.dest=lan
/etc/init.d/firewall reload >"$work/firewall.log" 2>&1
# Only router-originated traffic can reach these synthetic destinations.
# Forwarded requests fail unless the real native TProxy path terminates them.
nft -f - <<EOF
table ip netfleet_native_fixture {
	chain output {
		type nat hook output priority -101; policy accept;
		meta mark & 0x20000000 != 0 ip daddr 198.19.0.1 tcp dport $probe_port dnat to 192.168.1.2:$probe_port
	}
	chain forward {
		type filter hook forward priority -1; policy accept;
		iifname "nf-lan" ip daddr 198.19.0.1 counter reject
	}
	chain postrouting {
		type nat hook postrouting priority 101; policy accept;
		ip saddr { 198.18.0.0/30, 198.18.1.0/30 } oifname "br-lan" masquerade
	}
}
table ip6 netfleet_native_fixture {
	chain output {
		type nat hook output priority -101; policy accept;
		meta mark & 0x20000000 != 0 ip6 daddr 2001:db8:2::1 tcp dport $probe_port dnat to [::1]:$probe_port
	}
	chain forward {
		type filter hook forward priority -1; policy accept;
		iifname "nf-lan" ip6 daddr 2001:db8:2::1 counter reject
	}
}
EOF
nft -s list table ip netfleet_native_fixture >"$work/foreign4.nft"
nft -s list table ip6 netfleet_native_fixture >"$work/foreign6.nft"
dnsmasq --keep-in-foreground --port=1054 --listen-address=127.0.0.1 --bind-interfaces \
	--no-resolv --no-hosts --address=/native-proof.test/203.0.113.42 \
	--address=/netfleet-probe.test/192.168.1.2 --address=/www.gstatic.com/192.168.1.2 \
	--pid-file="$work/dns.pid" >"$work/dns.log" 2>&1 &
fixture_pids="$fixture_pids $!"
ip netns exec nf-upstream dnsmasq --keep-in-foreground --port=19999 \
	--listen-address=198.19.0.1,2001:db8:2::1 --bind-interfaces --no-resolv --no-hosts \
	--address=/native-udp.test/203.0.113.43 --pid-file="$work/upstream-dns.pid" >"$work/udp.log" 2>&1 &
fixture_pids="$fixture_pids $!"
socat TCP6-LISTEN:"$probe_port",bind=::1,ipv6only=1,reuseaddr,fork TCP4:192.168.1.2:"$probe_port" >"$work/tcp6.log" 2>&1 &
fixture_pids="$fixture_pids $!"
cat >"$work/helper.json" <<'EOF'
{"mixed-port":1081,"external-controller":"127.0.0.1:19091","mode":"direct","log-level":"warning","ipv6":true,"routing-mark":536870912}
EOF
"$work/bin/nf-proxy-fixture" -d "$work" -f "$work/helper.json" >"$work/helper.log" 2>&1 &
fixture_pids="$fixture_pids $!"

stage=fixture_configuration
uci set netfleet.config.profile=file:fixture.json
uci set netfleet.mixin.api_secret=native-vm-fixture
uci set netfleet.mixin.dns_listen='[::]:1053'
uci delete netfleet.proxy.lan_inbound_interface
uci add_list netfleet.proxy.lan_inbound_interface=nfclient
uci add_list netfleet.proxy.bypass_fwmark=0x20000000/0x20000000
uci commit netfleet
chmod 0600 /etc/config/netfleet
cat >/etc/opl-netfleet/native/profiles/fixture.json <<'EOF'
{"proxy-groups":[{"name":"Outbound","type":"select","proxies":["DIRECT"]}],"rules":["MATCH,Outbound"],"dns":{"enable":true,"nameserver":["udp://127.0.0.1:1054"]},"hosts":{"netfleet-probe.test":"192.168.1.2","www.gstatic.com":"192.168.1.2"}}
EOF
cat >/etc/opl-netfleet/policy.json <<EOF
{
 "schema_version":2,"main":{"target":"vm-fixture","enabled":true},
 "policy_source":{"kind":"profile","ref":"file:fixture.json"},
 "recovery_profile":{"ref":"file:fixture.json"},
 "bindings":{"Outbound":{"capability":"standard","kind":"entry"}},
 "providers":{"fixture":{"section":"fixture","enabled":true,"role":"primary"}},
 "regions":{"test":{"mode":"automatic","display_name":"Test"}},
 "provider_regions":{"fixture":[{"region":"test","filter":"native-region"}]},
 "capabilities":{"standard":{"enabled":true,"mode":"automatic"}},
 "selection":{"region_switch_margin_ms":150,"leaf_switch_margin_ms":150},
 "automation":{"enabled":true,"selection_interval_seconds":300,"subscription_refresh_enabled":true,"subscription_refresh_interval_seconds":3600,"poll_interval_seconds":5,"startup_grace_seconds":120,"runtime_grace_seconds":30},
 "evidence":{"path":"/etc/opl-netfleet/evidence.json"},
 "checks":{"provider_healthcheck_timeout_ms":5000,"latency":{"method":"mihomo_delay","url":"https://192.168.1.2:$probe_port/generate_204","timeout_ms":3000,"expected_status":204}},
 "fail_open":{"healthcheck":{"path_probe_id":"test","guard_probe_id":"test","timeout_ms":3000,"interval_seconds":30,"max_failed_times":1},"probes":[{"id":"test","url":"https://192.168.1.2:$probe_port/generate_204","expected_status":204}]}
}
EOF
stage=subscription_owner
ucode /tmp/tests/native_runtime_integration.uc "$probe_port" >"$work/subscriptions.log" 2>&1

helper_bytes() { curl -fsS --noproxy '*' http://127.0.0.1:19091/connections | jsonfilter -e '@.downloadTotal'; }
tcp_probe() {
	client=$1
	family=$2
	destination=198.19.0.1
	[ "$family" != 6 ] || destination='[2001:db8:2::1]'
	if [ "$client" = lan ]; then
		ip netns exec nf-client curl -fsS --noproxy '*' --connect-timeout 2 --max-time 8 \
			--cacert /tmp/local-probe.crt --resolve "netfleet-probe.test:$probe_port:$destination" \
			"https://netfleet-probe.test:$probe_port/generate_204"
	else
		curl -fsS --noproxy '*' --connect-timeout 2 --max-time 8 \
			--cacert /tmp/local-probe.crt --resolve "netfleet-probe.test:$probe_port:$destination" \
			"https://netfleet-probe.test:$probe_port/generate_204"
	fi
}
direct_probe() {
	ip netns exec nf-client curl -fsS --noproxy '*' --connect-timeout 2 --max-time 8 \
		--cacert /tmp/local-probe.crt "https://192.168.1.2:$probe_port/generate_204"
}
assert_foreign() {
	nft -s list table ip netfleet_native_fixture | cmp - "$work/foreign4.nft"
	nft -s list table ip6 netfleet_native_fixture | cmp - "$work/foreign6.nft"
}
assert_clean() {
	if nft list table inet netfleet >/dev/null 2>&1; then return 1; fi
	for family in 4 6; do
		if ip -"$family" rule show | grep -q '11900:'; then return 1; fi
		[ -z "$(ip -"$family" route show table 11900 2>/dev/null)" ] || return 1
	done
	[ -z "$(pidof mihomo 2>/dev/null || true)" ] || return 1
	assert_foreign
}
wait_ready() {
	for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
		ucode "$gateway" status >"$work/gateway-result.json"
		if assert_json "$work/gateway-result.json" '@.result.ready' true; then return 0; fi
		sleep 1
	done
	return 1
}
wait_clean() {
	for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
		if assert_clean; then return 0; fi
		sleep 1
	done
	return 1
}
stage=negative_control
direct_probe >"$work/direct-before.log" 2>&1
if tcp_probe lan 4 >"$work/bypass4.log" 2>&1; then exit 1; fi
if tcp_probe lan 6 >"$work/bypass6.log" 2>&1; then exit 1; fi
stage=shared_compile
run_main validate >"$work/validate-result.json"
run_main compile >"$work/compile-result.json"
stage=baseline_owner
run_main prepare-recovery file:fixture.json restart >"$work/prepare-result.json"
wait_ready
stage=shared_enable
run_main enable vm >"$work/enable-result.json"
wait_ready
run_main select standard auto vm >"$work/select-result.json"
ucode "$main" status >"$work/status-result.json"
assert_json "$work/status-result.json" '@.result.active' true
test ! -e /etc/init.d/nikki
stage=network_management
sh /tmp/guest-network-management-qualify.sh "$work/network-management" >"$work/network-management.json" 2>"$work/network-management.stderr"
assert_json "$work/network-management.json" '@.ok' true
stage=dashboard_management
sh /tmp/guest-rules-dashboard-qualify.sh >"$work/dashboard-management.json" 2>"$work/dashboard-management.stderr"
assert_json "$work/dashboard-management.json" '@.ok' true
ubus call service list '{"name":"opl-netfleet-core"}' >"$work/service-result.json"
core_pid=$(jsonfilter -i "$work/service-result.json" -e '@["opl-netfleet-core"].instances.core.pid')
tr '\0' ' ' <"/proc/$core_pid/cmdline" | grep -Fq '/etc/opl-netfleet/native/run/config.yaml'
test -e /etc/opl-netfleet/native/run/controller.sock
for family in 4 6; do
	ip -"$family" rule show | grep -q '11900:'
	ip -"$family" route show table 11900 | grep -q 'local default dev lo'
done
stage=runtime_subscription_edit
ucode /tmp/tests/native_runtime_integration.uc active >"$work/subscriptions-active.log" 2>&1
stage=owner_conflict
nft -s list table inet netfleet >"$work/owner.nft"
if ucode "$gateway" prepare >"$work/conflict-result.json"; then exit 1; fi
kill -0 "$core_pid"
nft -s list table inet netfleet | cmp - "$work/owner.nft"
for client in lan router; do
	for family in 4 6; do
		stage="${client}_ipv${family}_tcp"
		before=$(helper_bytes)
		tcp_probe "$client" "$family" >"$work/$stage.log" 2>&1
		[ "$(helper_bytes)" -gt "$before" ]
		stage="${client}_ipv${family}_udp"
		before=$(helper_bytes)
		destination=198.19.0.1
		[ "$family" != 6 ] || destination=2001:db8:2::1
		if [ "$client" = lan ]; then
			answer=$(ip netns exec nf-client dig +notcp +short +tries=1 +time=3 -p 19999 "@$destination" native-udp.test)
		else
			answer=$(dig +notcp +short +tries=1 +time=3 -p 19999 "@$destination" native-udp.test)
		fi
		printf '%s\n' "$answer" >"$work/$stage.log"
		[ "$answer" = 203.0.113.43 ]
		[ "$(helper_bytes)" -gt "$before" ]
		for transport in +notcp +tcp; do
			stage="${client}_ipv${family}_dns_${transport}"
			dns=203.0.113.53
			[ "$family" != 6 ] || dns=2001:db8:ffff::53
			if [ "$client" = lan ]; then
				ip netns exec nf-client dig "$transport" +short +tries=1 +time=3 "@$dns" native-proof.test >"$work/$stage.log"
			else
				dig "$transport" +short +tries=1 +time=3 "@$dns" native-proof.test >"$work/$stage.log"
			fi
			grep -qx 203.0.113.42 "$work/$stage.log"
		done
	done
done
stage=shared_refresh
cache=/etc/opl-netfleet/native/subscriptions/fixture.yaml
before_digest=$(sha256sum "$cache")
before_mtime=$(ucode -e 'import { stat } from "fs"; print(stat(ARGV[0]).mtime);' "$cache")
run_main refresh vm >"$work/refresh-result.json"
[ "$(sha256sum "$cache")" = "$before_digest" ]
[ "$(ucode -e 'import { stat } from "fs"; print(stat(ARGV[0]).mtime);' "$cache")" = "$before_mtime" ]
ucode "$main" status >"$work/refreshed-result.json"
assert_json "$work/refreshed-result.json" '@.result.active' true
ucode "$main" subscriptions-get >"$work/subscriptions-result.json"
assert_json "$work/subscriptions-result.json" '@.result.sources[0].pending_update' false
stage=shared_disable
run_main disable vm >"$work/disable-result.json"
assert_json "$work/disable-result.json" '@.result.state' native_profile
[ "$(uci get netfleet.config.profile)" = file:fixture.json ]
ucode "$main" status >"$work/disabled-result.json"
assert_json "$work/disabled-result.json" '@.result.active' false
stage=normal_stop
/etc/init.d/opl-netfleet-core stop
wait_clean
direct_probe >"$work/direct-after-stop.log" 2>&1
/etc/init.d/opl-netfleet-core stop
assert_clean
stage=core_failure
/etc/init.d/opl-netfleet-core start
wait_ready
ubus call service list '{"name":"opl-netfleet-core"}' >"$work/service-result.json"
core_pid=$(jsonfilter -i "$work/service-result.json" -e '@["opl-netfleet-core"].instances.core.pid')
kill -KILL "$core_pid"
sleep 1
wait_ready
ubus call service list '{"name":"opl-netfleet-core"}' >"$work/service-result.json"
[ "$(jsonfilter -i "$work/service-result.json" -e '@["opl-netfleet-core"].instances.core.pid')" != "$core_pid" ]
stage=firewall_reload
/etc/init.d/firewall reload >>"$work/firewall.log" 2>&1
wait_ready
assert_foreign
direct_probe >"$work/direct-after-respawn.log" 2>&1
stage=respawn_exhaustion
# One failure already occurred; five more exhaust procd's retry budget.
for crash in 2 3 4 5 6; do
	ubus call service list '{"name":"opl-netfleet-core"}' >"$work/service-result.json"
	core_pid=$(jsonfilter -i "$work/service-result.json" -e '@["opl-netfleet-core"].instances.core.pid')
	kill -KILL "$core_pid"
	sleep 1
	if [ "$crash" -lt 6 ]; then wait_ready; fi
done
wait_clean
sleep 6
assert_clean
direct_probe >"$work/direct-after-exhaustion.log" 2>&1
/etc/init.d/opl-netfleet-core stop
wait_clean
direct_probe >"$work/direct-after-crash.log" 2>&1
stage=invalid_config
cp /etc/opl-netfleet/native/profiles/fixture.json "$work/valid.json"
printf '{broken' >/etc/opl-netfleet/native/profiles/fixture.json
if /etc/init.d/opl-netfleet-core start >"$work/invalid-result.json" 2>&1; then sleep 1; fi
assert_clean
cp "$work/valid.json" /etc/opl-netfleet/native/profiles/fixture.json
stage=management_receipts
ucode -e 'import { readfile } from "fs";
	for (let path in ARGV) {
		const detail = json(readfile(path));
		if (detail.ok != true || !length(keys(detail.checks ?? {}))) exit(1);
		for (let passed in values(detail.checks)) if (passed != true) exit(1);
	}' "$work/network-management.json" "$work/dashboard-management.json"
stage=complete
printf '{"ok":true,"scope":"native-mihomo-runtime","production_ready":false,"source_commit":"%s","source_tree":"%s","checks":{"source_contracts":true,"native_subscription_crud":true,"subscription_download":true,"subscription_failed_cache_retained":true,"subscription_identity_isolation":true,"subscription_private_storage":true,"subscription_active_edit_guard":true,"subscription_same_content_mtime":true,"no_nikki":true,"shared_compile":true,"shared_enable":true,"shared_select":true,"shared_refresh":true,"shared_disable":true,"procd_owner":true,"controller":true,"owner_conflict_zero_mutation":true,"ipv4_negative_control":true,"ipv6_negative_control":true,"lan_ipv4_tcp":true,"lan_ipv4_udp":true,"lan_ipv6_tcp":true,"lan_ipv6_udp":true,"router_ipv4_tcp":true,"router_ipv4_udp":true,"router_ipv6_tcp":true,"router_ipv6_udp":true,"lan_ipv4_dns_tcp_udp":true,"lan_ipv6_dns_tcp_udp":true,"router_ipv4_dns_tcp_udp":true,"router_ipv6_dns_tcp_udp":true,"normal_stop_cleanup":true,"repeated_stop":true,"crash_recovery_or_cleanup":true,"direct_after_stop":true,"direct_after_crash":true,"invalid_config_no_interception":true,"foreign_rules_preserved":true}}\n' "$commit" "$tree"
