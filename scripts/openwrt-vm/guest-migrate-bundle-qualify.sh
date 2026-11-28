#!/bin/sh
# Qualify atomic 28-pkg (v0.9.32) -> Path B Release Bundle thin-shell migration on OpenWrt 25.12.5.
. "$(dirname -- "$0")/guest-common.sh"

source_commit=${1:?}
source_tree=${2:?}
manifest_sha=${3:?}
probe_port=${4:?}
feed_url=${5:?}
work=/tmp/netfleet-migrate-bundle-fixture
legacy_url="$feed_url/legacy-feed"
helper_pids=

command -v apk >/dev/null 2>&1
mkdir -p "$work/bin"

guest_check_receipt() {
	[ "$stage" = complete ] && [ -s "$work/qualification.json" ]
}
guest_on_failure() {
	echo "OpenWrt 28-pkg -> thin-shell migration failed at stage: $stage" >&2
	apk list --installed | grep -E '^(opl-netfleet|luci-app-netfleet|mihomo-meta)' >&2 || true
	ls -la /usr/share/opl-netfleet /etc/opl-netfleet >&2 || true
	readlink /usr/share/opl-netfleet/current >&2 || true
	for file in "$work"/*.json "$work"/*.log /tmp/opl-netfleet-package-upgrade-state; do
		[ ! -f "$file" ] || { echo "--- $file" >&2; tail -80 "$file" >&2; }
	done
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

stage=prerequisites
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
ip route replace default via 192.168.1.2 dev br-lan
printf 'nameserver 192.168.1.3\n' >/etc/resolv.conf
: >"$work/packages.log"

for attempt in 1 2 3; do
	apk --timeout 120 update >>"$work/packages.log" 2>&1 || true
	if apk --timeout 120 add usign curl flock coreutils-timeout ip-full socat kmod-veth kmod-nft-tproxy kmod-nft-socket \
		ucode-mod-fs ucode-mod-digest ucode-mod-uci ucode-mod-socket ucode-mod-ubus ucode-mod-uloop >>"$work/packages.log" 2>&1 && command -v usign >/dev/null 2>&1; then
		break
	fi
	[ "$attempt" -lt 3 ] || exit 1
	sleep "$((attempt * 2))"
done

stage=install_legacy_28_pkg
uclient-fetch -q -O "$work/legacy-install.sh" "$legacy_url/install-netfleet.sh"
NETFLEET_FEED_BASE="$legacy_url" NETFLEET_ALLOW_INSECURE_FEED=1 \
	sh "$work/legacy-install.sh" >>"$work/packages.log" 2>&1
apk info -e opl-netfleet-kernel >/dev/null 2>&1
apk info -e opl-netfleet-plugin-components >/dev/null 2>&1
[ ! -e /usr/share/opl-netfleet/shell.json ]

stage=setup_legacy_active
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

run_main native-setup-get >"$work/setup-get.json"
assert_json "$work/setup-get.json" '@.ok' true
ucode -e '
	import { readfile, writefile } from "fs";
	const plan = json(readfile(ARGV[0]));
	exit(writefile(ARGV[1], sprintf("%J", { request: { confirmed: true, revision: plan.result.revision, source: { id: "setup", name: "VM Setup", url: ARGV[2] } } })) ? 0 : 1);
' "$work/setup-get.json" "$work/setup-req.json" "https://192.168.1.2:$probe_port/native-subscriptions/setup?token=vm-only-credential"
chmod 0600 "$work/setup-req.json"
run_main native-setup-apply "$work/setup-req.json" >"$work/setup-apply.json"
assert_json "$work/setup-apply.json" '@.ok' true
run_main onboarding-get >"$work/onboard-get.json"
ucode -e '
	import { readfile, writefile } from "fs";
	const plan = json(readfile(ARGV[0]));
	exit(writefile(ARGV[1], sprintf("%J", { request: { confirmed: true, revision: plan.result.revision } })) ? 0 : 1);
' "$work/onboard-get.json" "$work/onboard-req.json"
chmod 0600 "$work/onboard-req.json"
run_main onboarding-apply "$work/onboard-req.json" >"$work/onboard-apply.json"
assert_json "$work/onboard-apply.json" '@.ok' true
assert_json "$work/onboard-apply.json" '@.result.state' active
policy_sha_before=$(digest /etc/opl-netfleet/policy.json)

stage=migrate_to_thin_shell
uclient-fetch -q -O "$work/manifest.json" "$feed_url/manifest.json"
[ "$(digest "$work/manifest.json")" = "$manifest_sha" ]
expected_ver=$(jsonfilter -i "$work/manifest.json" -e '@.package_version')
uclient-fetch -q -O "$work/install-netfleet.sh" "$feed_url/install-netfleet.sh"
NETFLEET_FEED_BASE="$feed_url" NETFLEET_ALLOW_INSECURE_FEED=1 \
	sh "$work/install-netfleet.sh" >>"$work/packages.log" 2>&1

stage=verify_migrated_state
! apk info -e opl-netfleet-kernel >/dev/null 2>&1
if apk info 2>/dev/null | grep -Eq '^opl-netfleet-plugin-'; then
	echo "Legacy built-in plugin packages remain installed after migration" >&2
	apk info | grep -E '^opl-netfleet' >&2
	exit 1
fi
apk info -e opl-netfleet >/dev/null 2>&1
apk info -e luci-app-netfleet >/dev/null 2>&1
[ ! -e /tmp/opl-netfleet-package-upgrade-state ]
[ ! -e /tmp/opl-netfleet-microkernel-migration ]
assert_json /usr/share/opl-netfleet/shell.json '@.shell_version' "$expected_ver"
[ "$(readlink /usr/share/opl-netfleet/current)" = "releases/$expected_ver" ]
assert_json /usr/share/opl-netfleet/build.json '@.source_commit' "$source_commit"
assert_json /usr/share/opl-netfleet/build.json '@.delivery' release-bundle
[ "$(digest /etc/opl-netfleet/policy.json)" = "$policy_sha_before" ]

for attempt in $(seq 1 25); do
	if ubus -v list opl-netfleet >/dev/null 2>&1 && ubus -v list opl-netfleet.plugins >/dev/null 2>&1; then
		break
	fi
	[ "$attempt" -lt 25 ] || exit 1
	sleep 1
done

ubus -t 20 call opl-netfleet status '{}' >"$work/status.json"
assert_json "$work/status.json" '@.ok' true
assert_json "$work/status.json" '@.result.active' true
assert_json "$work/status.json" '@.result.build.source_commit' "$source_commit"
ubus -t 20 call opl-netfleet probe '{}' >"$work/probe.json"
assert_json "$work/probe.json" '@.ok' true
assert_json "$work/probe.json" '@.result.ok' true
ubus -t 20 call opl-netfleet components_get '{}' >"$work/cget.json"
assert_json "$work/cget.json" '@.ok' true
assert_json "$work/cget.json" '@.result.delivery_mode' release-bundle
assert_json "$work/cget.json" '@.result.capabilities.release_bundle' true
direct_probe

stage=complete
printf '{"schema_version":1,"ok":true,"source_commit":"%s","source_tree":"%s","manifest_sha256":"%s","scope":"openwrt-25.12-migrate-bundle","checks":{"legacy_28pkg_installed":true,"migrated_to_thin_shell":true,"legacy_plugins_removed":true,"policy_preserved":true,"active_service_restored":true,"dns_and_tproxy_probe":true,"release_bundle_active":true}}\n' \
	"$source_commit" "$source_tree" "$manifest_sha" >"$work/qualification.json"
cat "$work/qualification.json"
