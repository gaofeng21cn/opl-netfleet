#!/bin/sh
# Qualify zero-SDK IPK + opkg installation, native setup/TProxy/DNS, Fail-Open, and uninstall on OpenWrt 24.10.2.
. "$(dirname -- "$0")/guest-common.sh"

source_commit=${1:?}
source_tree=${2:?}
manifest_sha=${3:?}
probe_port=${4:?}
feed_url=${5:?}
work=/tmp/netfleet-opkg-fixture
candidate=$work/feed
helper_pids=

command -v opkg >/dev/null 2>&1
! command -v apk >/dev/null 2>&1
test ! -e /etc/init.d/nikki
test ! -e /etc/config/nikki
test -z "$(pidof mihomo 2>/dev/null || true)"
mkdir -p "$work/bin" "$candidate"

guest_check_receipt() {
	[ "$stage" = complete ] && [ -s "$work/qualification.json" ]
}
guest_on_failure() {
	echo "OpenWrt 24.10 opkg qualification failed at stage: $stage" >&2
	for file in "$work"/*.log "$work"/*-result.json /etc/opkg/customfeeds.conf /etc/opkg/distfeeds.conf; do
		[ ! -f "$file" ] || { echo "--- $file" >&2; tail -80 "$file" >&2; }
	done
	opkg status opl-netfleet luci-app-netfleet mihomo-meta >&2 || true
	logread | tail -80 >&2 || true
}
guest_cleanup() {
	[ ! -x /etc/init.d/opl-netfleet ] || /etc/init.d/opl-netfleet stop >/dev/null 2>&1 || true
	[ ! -x /etc/init.d/opl-netfleet-core ] || /etc/init.d/opl-netfleet-core stop >/dev/null 2>&1 || true
	for pid in $helper_pids; do kill "$pid" >/dev/null 2>&1 || true; done
	ubus call network.interface.wan remove >/dev/null 2>&1 || true
	ip netns del nf-setup-upstream >/dev/null 2>&1 || true
	ip netns del nf-setup-client >/dev/null 2>&1 || true
	ip link del nf-setup-lan >/dev/null 2>&1 || true
	ip -6 addr del fd77:9::1/64 dev br-lan >/dev/null 2>&1 || true
	ip link del nf-setup-uplink >/dev/null 2>&1 || true
	nft delete table ip netfleet_setup_fixture >/dev/null 2>&1 || true
}
guest_setup_trap

direct_probe() {
	curl -fsS --noproxy '*' --connect-timeout 2 --max-time 8 \
		--cacert /tmp/local-probe.crt "https://192.168.1.2:$probe_port/generate_204" || return 1
	if [ -e "$work/client-ready" ]; then
		ip netns exec nf-setup-client nslookup -type=A www.gstatic.com 192.168.1.1 >>"$work/client-dns.log" 2>&1 || return 1
		ip netns exec nf-setup-client curl -fsS --noproxy '*' --max-time 8 \
			http://198.18.1.2:19091/version >>"$work/client-ipv4.log" || return 1
		ip netns exec nf-setup-client curl -gfsS --noproxy '*' --max-time 8 \
			'http://[fd77:a::2]:19091/version' >>"$work/client-ipv6.log" || return 1
		ip netns exec nf-setup-client curl -fsS --noproxy '*' --max-time 10 \
			--cacert /tmp/local-probe.crt --resolve netfleet-probe.test:19443:198.18.1.2 \
			https://netfleet-probe.test:19443/generate_204 || return 1
		ip netns exec nf-setup-client curl -fsS --noproxy '*' --max-time 10 \
			--cacert /tmp/local-probe.crt --resolve 'netfleet-probe.test:19443:[fd77:a::2]' \
			https://netfleet-probe.test:19443/generate_204 || return 1
	fi
	return 0
}

stage=opkg_prerequisites
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
ip route replace default via 192.168.1.2 dev br-lan
printf 'nameserver 192.168.1.3\n' >/etc/resolv.conf
: >"$work/packages.log"
for attempt in 1 2 3; do
	opkg update >>"$work/packages.log" 2>&1 || true
	if opkg install usign curl socat kmod-veth >>"$work/packages.log" 2>&1 && command -v usign >/dev/null 2>&1 && curl --version >>"$work/packages.log" 2>&1; then
		break
	fi
	[ "$attempt" -lt 3 ] || exit 1
	sleep "$((attempt * 2))"
done

stage=signed_ipk_install
uclient-fetch -q -O "$candidate/manifest.json" "$feed_url/manifest.json"
uclient-fetch -q -O "$candidate/install-netfleet.sh" "$feed_url/install-netfleet.sh"
[ "$(digest "$candidate/manifest.json")" = "$manifest_sha" ]
assert_json "$candidate/manifest.json" '@.source_commit' "$source_commit"
assert_json "$candidate/manifest.json" '@.source_tree' "$source_tree"
assert_json "$candidate/manifest.json" '@.package_format' ipk

NETFLEET_FEED_BASE="$feed_url" NETFLEET_ALLOW_INSECURE_FEED=1 \
	sh "$candidate/install-netfleet.sh" >>"$work/packages.log" 2>&1

expected_key_id=$(jsonfilter -i "$candidate/manifest.json" -e '@.usign_key_id')
[ -s "/etc/opkg/keys/$expected_key_id" ]
grep -Fq "src/gz opl_netfleet $feed_url" /etc/opkg/customfeeds.conf
assert_json /etc/opl-netfleet/release-feed.json '@.url' "$feed_url"

opkg list-installed | grep -Eq '^opl-netfleet - '
opkg list-installed | grep -Eq '^luci-app-netfleet - '
opkg list-installed | grep -Eq '^mihomo-meta - '
[ "$(readlink /usr/bin/mihomo)" = /usr/libexec/mihomo ]

stage=bundle_layout_and_rpc_readback
expected_ver=$(jsonfilter -i "$candidate/manifest.json" -e '@.package_version')
[ "$(readlink /usr/share/opl-netfleet/current)" = "releases/$expected_ver" ]
assert_json /usr/share/opl-netfleet/shell.json '@.shell_version' "$expected_ver"
assert_json /usr/share/opl-netfleet/build.json '@.source_commit' "$source_commit"
assert_json /usr/share/opl-netfleet/build.json '@.source_tree' "$source_tree"
assert_json /usr/share/opl-netfleet/build.json '@.delivery' release-bundle
[ -e /www/luci-static/resources/netfleet/bundle/plugins/product-ui ]
[ -f "$(echo /www/luci-static/resources/netfleet/bundle/plugins/product-ui/*/resources/components.js)" ]
! /etc/init.d/opl-netfleet enabled
! /etc/init.d/opl-netfleet running
! /etc/init.d/opl-netfleet-core enabled
! /etc/init.d/opl-netfleet-core running

ubus -t 20 call opl-netfleet status '{}' >"$work/rpc-status.json"
assert_json "$work/rpc-status.json" '@.ok' true
assert_json "$work/rpc-status.json" '@.result.build.source_commit' "$source_commit"
ubus -t 20 call opl-netfleet.plugins plugins_list '{}' >"$work/rpc-plugins.json"
assert_json "$work/rpc-plugins.json" '@.ok' true
ucode -e '
	import { readfile } from "fs";
	const list = json(readfile(ARGV[0])).result.plugins;
	const status = filter(list, p => p.id == "status")[0];
	if (!status || status.asset_scope != "bundle" || status.state != "available") exit(1);
' "$work/rpc-plugins.json"

ucode "$main" components-get >"$work/components-get.json"
assert_json "$work/components-get.json" '@.ok' true
assert_json "$work/components-get.json" '@.result.supported' false
assert_json "$work/components-get.json" '@.result.unsupported_reason' opkg_read_only
assert_json "$work/components-get.json" '@.result.package_manager' opkg
ucode -e '
	import { readfile } from "fs";
	const r = json(readfile(ARGV[0])).result;
	for (let id in ["netfleet", "luci", "mihomo"]) {
		const c = filter(r.components, row => row.id == id)[0];
		if (!c || !c.installed_version) exit(1);
	}
	for (let dep in r.dependencies) if (!dep.available) exit(1);
' "$work/components-get.json"

stage=real_upstream_and_client
cp "$(readlink -f /usr/bin/mihomo)" "$work/bin/nf-setup-proxy"
chmod 0755 "$work/bin/nf-setup-proxy"
cat /tmp/local-probe.crt >>/etc/ssl/certs/ca-certificates.crt
printf '192.168.1.2 netfleet-probe.test www.gstatic.com www.cloudflare.com\n' >>/etc/hosts

ip netns add nf-setup-upstream
ip netns exec nf-setup-upstream ip link add nf-setup-peer type veth peer name nf-setup-uplink netns 1
ip link set nf-setup-uplink up
ip netns exec nf-setup-upstream ip link set lo up
ip netns exec nf-setup-upstream ip link set nf-setup-peer up
ip netns exec nf-setup-upstream ip addr add 198.18.1.2/30 dev nf-setup-peer
ip netns exec nf-setup-upstream ip -6 addr add fd77:a::2/64 dev nf-setup-peer nodad
ip netns exec nf-setup-upstream ip route add default via 198.18.1.1
ip netns exec nf-setup-upstream ip -6 route add default via fd77:a::1
ubus call network add_dynamic '{"name":"wan","proto":"static","device":"nf-setup-uplink","ipaddr":["198.18.1.1/30"],"ip6addr":["fd77:a::1/64"],"dns":["198.18.1.2"]}' >"$work/wan-result.json"
ubus call network.interface.wan up >>"$work/wan-result.json"
for attempt in 1 2 3 4 5; do
	[ "$(ubus call network.interface.wan status | jsonfilter -e '@.up')" != true ] || break
	sleep 1
done
uci set firewall.nfsetup=zone
uci set firewall.nfsetup.name=nfsetup
uci add_list firewall.nfsetup.device=nf-setup-uplink
uci set firewall.nfsetup.input=ACCEPT
uci set firewall.nfsetup.output=ACCEPT
uci set firewall.nfsetup.forward=ACCEPT
uci set firewall.nfsetup_forward=forwarding
uci set firewall.nfsetup_forward.src=nfsetup
uci set firewall.nfsetup_forward.dest=lan
uci set firewall.nfsetup_client=forwarding
uci set firewall.nfsetup_client.src=lan
uci set firewall.nfsetup_client.dest=nfsetup
uci commit firewall
/etc/init.d/firewall reload >"$work/firewall.log" 2>&1
nft -f - <<EOF
table ip netfleet_setup_fixture {
	chain prerouting {
		type nat hook prerouting priority -101; policy accept;
		iifname "nf-setup-uplink" ip daddr 192.168.1.2 tcp dport 443 dnat to 192.168.1.2:$probe_port
	}
	chain postrouting {
		type nat hook postrouting priority 101; policy accept;
		ip saddr 198.18.1.0/30 oifname "br-lan" masquerade
	}
}
EOF
ip netns exec nf-setup-upstream dnsmasq --keep-in-foreground --port=53 \
	--listen-address=198.18.1.2 --bind-interfaces --no-resolv --no-hosts \
	--address=/netfleet-probe.test/192.168.1.2 --address=/www.gstatic.com/192.168.1.2 --address=/www.cloudflare.com/192.168.1.2 \
	--pid-file="$work/dns.pid" >"$work/dns.log" 2>&1 &
helper_pids="$helper_pids $!"
cat >"$work/helper.json" <<'EOF'
{"mixed-port":1081,"allow-lan":true,"bind-address":"*","external-controller":"[::]:19091","mode":"direct","log-level":"warning","ipv6":true,"hosts":{"netfleet-probe.test":"192.168.1.2","www.gstatic.com":"192.168.1.2","www.cloudflare.com":"192.168.1.2"}}
EOF
ip netns exec nf-setup-upstream "$work/bin/nf-setup-proxy" -d "$work" -f "$work/helper.json" >"$work/helper.log" 2>&1 &
helper_pids="$helper_pids $!"
ip netns exec nf-setup-upstream socat 'TCP6-LISTEN:19443,ipv6only=0,reuseaddr,fork' \
	"TCP4:192.168.1.2:$probe_port" >"$work/tls-endpoint.log" 2>&1 &
helper_pids="$helper_pids $!"
for attempt in $(seq 1 15); do
	if curl -fsS --socks5-hostname 198.18.1.2:1081 --max-time 4 https://www.gstatic.com/generate_204 >/dev/null; then break; fi
	[ "$attempt" -lt 15 ] || exit 1
	sleep 1
done
ip netns add nf-setup-client
ip netns exec nf-setup-client sysctl -q -w net.ipv6.conf.all.accept_ra=0 \
	net.ipv6.conf.default.accept_ra=0 net.ipv6.conf.default.autoconf=0
ip netns exec nf-setup-client ip link add nf-setup-client type veth peer name nf-setup-lan netns 1
ip link set nf-setup-lan master br-lan
ip link set nf-setup-lan up
ip -6 addr add fd77:9::1/64 dev br-lan nodad
ip netns exec nf-setup-client ip link set lo up
ip netns exec nf-setup-client ip link set nf-setup-client up
ip netns exec nf-setup-client ip addr add 192.168.1.20/24 dev nf-setup-client
ip netns exec nf-setup-client ip -6 addr add fd77:9::2/64 dev nf-setup-client nodad
ip netns exec nf-setup-client ip route add default via 192.168.1.1
ip netns exec nf-setup-client ip -6 route add default via fd77:9::1
touch "$work/client-ready"
for attempt in $(seq 1 10); do
	if direct_probe >>"$work/client-ready.log" 2>&1; then break; fi
	[ "$attempt" -lt 10 ] || exit 1
	sleep 1
done

stage=native_setup_and_takeover
run_main native-setup-get >"$work/setup-get-result.json"
assert_json "$work/setup-get-result.json" '@.ok' true
assert_json "$work/setup-get-result.json" '@.result.ready' true
ucode -e '
	import { readfile, writefile } from "fs";
	const plan = json(readfile(ARGV[0]));
	exit(writefile(ARGV[1], sprintf("%J", { request: { confirmed: true, revision: plan.result.revision, source: { id: "setup", name: "VM Setup", url: ARGV[2] } } })) ? 0 : 1);
' "$work/setup-get-result.json" "$work/setup-request.json" "https://192.168.1.2:$probe_port/native-subscriptions/setup?token=vm-only-credential"
chmod 0600 "$work/setup-request.json"
run_main native-setup-apply "$work/setup-request.json" >"$work/setup-apply-result.json"
assert_json "$work/setup-apply-result.json" '@.ok' true
run_main onboarding-get >"$work/onboarding-get-result.json"
ucode -e '
	import { readfile, writefile } from "fs";
	const plan = json(readfile(ARGV[0]));
	exit(writefile(ARGV[1], sprintf("%J", { request: { confirmed: true, revision: plan.result.revision } })) ? 0 : 1);
' "$work/onboarding-get-result.json" "$work/onboarding-request.json"
chmod 0600 "$work/onboarding-request.json"
run_main onboarding-apply "$work/onboarding-request.json" >"$work/onboarding-apply-result.json"
assert_json "$work/onboarding-apply-result.json" '@.ok' true
assert_json "$work/onboarding-apply-result.json" '@.result.state' active
run_main status >"$work/status-active.json"
assert_json "$work/status-active.json" '@.result.runtime.mihomo_running' true
run_main probe >"$work/probe-active.json"
assert_json "$work/probe-active.json" '@.ok' true
curl -fsS --socks5-hostname 127.0.0.1:7890 --max-time 10 https://www.gstatic.com/generate_204
direct_probe

stage=fail_open_disable_and_remove
run_main disable >"$work/disable-result.json"
assert_json "$work/disable-result.json" '@.ok' true
! /etc/init.d/opl-netfleet running >/dev/null 2>&1 || /etc/init.d/opl-netfleet stop
! /etc/init.d/opl-netfleet-core running >/dev/null 2>&1 || /etc/init.d/opl-netfleet-core stop
for attempt in $(seq 1 10); do
	ucode "$main" native-gateway-status >"$work/stopped-result.json"
	[ "$(jsonfilter -i "$work/stopped-result.json" -e '@.result.core_running')" != false ] || break
	sleep 1
done
assert_json "$work/stopped-result.json" '@.result.clean' true
assert_json "$work/stopped-result.json" '@.result.core_running' false
direct_probe

policy_before=$(digest /etc/opl-netfleet/policy.json)
opkg remove luci-app-netfleet opl-netfleet mihomo-meta >>"$work/packages.log" 2>&1
! opkg list-installed | grep -Eq '^(opl-netfleet|luci-app-netfleet|mihomo-meta) '
[ ! -e "$main" ]
[ ! -e /usr/share/opl-netfleet/current ]
[ ! -e /etc/init.d/opl-netfleet-core ]
[ "$(digest /etc/opl-netfleet/policy.json)" = "$policy_before" ]
[ -z "$(pidof mihomo 2>/dev/null || true)" ]
! nft list table inet netfleet >/dev/null 2>&1
direct_probe

stage=existing_core_preservation
printf '#!/bin/sh\necho custom-mihomo\n' >/usr/bin/mihomo
chmod 0755 /usr/bin/mihomo
custom_sha=$(digest /usr/bin/mihomo)
NETFLEET_FEED_BASE="$feed_url" NETFLEET_ALLOW_INSECURE_FEED=1 \
	sh "$candidate/install-netfleet.sh" >>"$work/packages.log" 2>&1
opkg list-installed | grep -Eq '^opl-netfleet - '
opkg list-installed | grep -Eq '^luci-app-netfleet - '
! opkg list-installed | grep -Eq '^mihomo-meta '
[ "$(digest /usr/bin/mihomo)" = "$custom_sha" ]
opkg remove luci-app-netfleet opl-netfleet >>"$work/packages.log" 2>&1
rm -f /usr/bin/mihomo

stage=complete
printf '{"schema_version":1,"ok":true,"source_commit":"%s","source_tree":"%s","manifest_sha256":"%s","scope":"openwrt-24.10-opkg","checks":{"opkg_signed_install":true,"bundle_layout":true,"rpcd_status_and_plugins":true,"components_opkg_readonly":true,"native_setup_and_takeover":true,"dns_and_tproxy_probe":true,"fail_open_disable":true,"opkg_clean_remove":true,"existing_core_preserved":true}}\n' \
	"$source_commit" "$source_tree" "$manifest_sha" >"$work/qualification.json"
cat "$work/qualification.json"
