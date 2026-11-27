#!/bin/sh
# Qualify Release Bundle fault-injection, zero-interruption upgrade, manual rollback, and crash recovery on 25.12.5 (apk) and 24.10.2 (opkg).
. "$(dirname -- "$0")/guest-common.sh"

source_commit=${1:?}
source_tree=${2:?}
manifest_sha=${3:?}
probe_port=${4:?}
feed_url=${5:?}
work=/tmp/netfleet-bundle-fixture
candidate=$work/feed
helper_pids=

mkdir -p "$work/bin" "$candidate"

guest_check_receipt() {
	[ "$stage" = complete ] && [ -s "$work/qualification.json" ]
}
guest_on_failure() {
	echo "OpenWrt Release Bundle qualification failed at stage: $stage" >&2
	ls -la /usr/share/opl-netfleet /usr/share/opl-netfleet/releases /etc/opl-netfleet/package-transactions >&2 || true
	readlink /usr/share/opl-netfleet/current >&2 || true
	readlink /usr/share/opl-netfleet/previous >&2 || true
	for file in "$work"/*.json "$work"/*.log /etc/opl-netfleet/package-transactions/pending.json /etc/opl-netfleet/package-transactions/request.json /etc/opl-netfleet/package-transactions/*/log /etc/opl-netfleet/package-transactions/*/journal.json; do
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

set_feed() {
	subpath=$1
	tmpf=/etc/opl-netfleet/release-feed.json.tmp.$$
	umask 077
	printf '{"schema":"opl-netfleet-release-feed.v1","url":"%s/bundle-fixtures/%s","allow_insecure":true}\n' "$feed_url" "$subpath" >"$tmpf"
	chmod 0600 "$tmpf"
	mv -f "$tmpf" /etc/opl-netfleet/release-feed.json
}

wait_rpcd_ready() {
	for attempt in $(seq 1 25); do
		if ubus -v list opl-netfleet >/dev/null 2>&1 && ubus -v list opl-netfleet.plugins >/dev/null 2>&1; then
			return 0
		fi
		sleep 1
	done
	return 1
}

wait_pkg_op() {
	wanted=$1
	for attempt in $(seq 1 90); do
		if ! ubus -t 10 call opl-netfleet operation_get '{}' >"$work/op.json" 2>/dev/null; then
			sleep 1
			continue
		fi
		op_id=$(jsonfilter -i "$work/op.json" -e '@.result.packages.id' 2>/dev/null || true)
		op_state=$(jsonfilter -i "$work/op.json" -e '@.result.packages.state' 2>/dev/null || true)
		op_error=$(jsonfilter -i "$work/op.json" -e '@.result.packages.error' 2>/dev/null || true)
		if [ "$op_id" = "$wanted" ]; then
			case "$op_state" in succeeded|failed|interrupted) return 0 ;; esac
		fi
		sleep 1
	done
	echo "Bundle operation $wanted did not finish in time" >&2
	return 1
}

run_op() {
	method=$1
	payload=${2:-'{}'}
	expected_state=$3
	expected_error=${4:-}
	ubus -t 20 call opl-netfleet "$method" "$payload" >"$work/start.json"
	assert_json "$work/start.json" '@.ok' true
	op_id=$(jsonfilter -i "$work/start.json" -e '@.result.operation.id')
	[ -n "$op_id" ]
	wait_pkg_op "$op_id"
	[ "$op_state" = "$expected_state" ] || {
		echo "Expected $method state=$expected_state, got state=$op_state error=$op_error" >&2
		return 1
	}
	if [ -n "$expected_error" ]; then
		[ "$op_error" = "$expected_error" ] || {
			echo "Expected $method error=$expected_error, got error=$op_error" >&2
			return 1
		}
	fi
}

assert_live_runtime() {
	expected_version=$1
	wait_rpcd_ready
	[ "$(readlink /usr/share/opl-netfleet/current)" = "releases/$expected_version" ]
	assert_json /usr/share/opl-netfleet/build.json '@.version' "$expected_version"
	[ "$(pidof mihomo 2>/dev/null || true)" = "$pid_before" ]
	ubus -t 20 call opl-netfleet status '{}' >"$work/status.json"
	assert_json "$work/status.json" '@.ok' true
	assert_json "$work/status.json" '@.result.active' true
	assert_json "$work/status.json" '@.result.build.version' "$expected_version"
	assert_json "$work/status.json" '@.result.build.source_commit' "$source_commit"
	ubus -t 20 call opl-netfleet.plugins plugins_list '{}' >"$work/plugins.json"
	assert_json "$work/plugins.json" '@.ok' true
	ubus -t 20 call opl-netfleet probe '{}' >"$work/probe.json"
	assert_json "$work/probe.json" '@.ok' true
	assert_json "$work/probe.json" '@.result.ok' true
	[ -s "$(echo /www/luci-static/resources/netfleet/bundle/plugins/product-ui/*/resources/components.js)" ]
	direct_probe
}

stage=prerequisites
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
ip route replace default via 192.168.1.2 dev br-lan
printf 'nameserver 192.168.1.3\n' >/etc/resolv.conf
: >"$work/packages.log"

if command -v apk >/dev/null 2>&1; then
	pkg_mgr=apk
	for attempt in 1 2 3; do
		apk --timeout 120 update >>"$work/packages.log" 2>&1 || true
		if apk --timeout 120 add usign curl flock coreutils-timeout ip-full socat kmod-veth kmod-nft-tproxy kmod-nft-socket \
			ucode-mod-fs ucode-mod-digest ucode-mod-uci ucode-mod-socket ucode-mod-ubus ucode-mod-uloop >>"$work/packages.log" 2>&1 && command -v usign >/dev/null 2>&1; then
			break
		fi
		[ "$attempt" -lt 3 ] || exit 1
		sleep "$((attempt * 2))"
	done
else
	pkg_mgr=opkg
	for attempt in 1 2 3; do
		opkg update >>"$work/packages.log" 2>&1 || true
		if opkg install usign curl socat kmod-veth >>"$work/packages.log" 2>&1 && command -v usign >/dev/null 2>&1 && curl --version >>"$work/packages.log" 2>&1; then
			break
		fi
		[ "$attempt" -lt 3 ] || exit 1
		sleep "$((attempt * 2))"
	done
fi

stage=install_candidate
uclient-fetch -q -O "$candidate/manifest.json" "$feed_url/manifest.json"
uclient-fetch -q -O "$candidate/install-netfleet.sh" "$feed_url/install-netfleet.sh"
uclient-fetch -q -O "$work/fixtures-meta.json" "$feed_url/bundle-fixtures/fixtures-meta.json"
[ "$(digest "$candidate/manifest.json")" = "$manifest_sha" ]
assert_json "$candidate/manifest.json" '@.source_commit' "$source_commit"
assert_json "$candidate/manifest.json" '@.source_tree' "$source_tree"

NETFLEET_FEED_BASE="$feed_url" NETFLEET_ALLOW_INSECURE_FEED=1 \
	sh "$candidate/install-netfleet.sh" >>"$work/packages.log" 2>&1

orig_ver=$(jsonfilter -i "$work/fixtures-meta.json" -e '@.orig_version')
next_ver=$(jsonfilter -i "$work/fixtures-meta.json" -e '@.next_version')
wait_rpcd_ready
[ "$(readlink /usr/share/opl-netfleet/current)" = "releases/$orig_ver" ]
assert_json /usr/share/opl-netfleet/shell.json '@.shell_version' "$orig_ver"
[ -f /usr/share/opl-netfleet/keys/release-bundle.pub ]

stage=setup_native_active
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
assert_json "$work/setup-get.json" '@.result.ready' true
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

pid_before=$(pidof mihomo)
[ -n "$pid_before" ]
assert_live_runtime "$orig_ver"

stage=fault_bad_signature
set_feed bad-sig
run_op components_check '{}' failed bundle_signature_invalid
assert_live_runtime "$orig_ver"

stage=fault_high_min_shell
set_feed high-min-shell
run_op components_check '{}' succeeded
ubus -t 20 call opl-netfleet components_get '{}' >"$work/cget-shell.json"
assert_json "$work/cget-shell.json" '@.result.shell_upgrade_required' true
run_op components_update "{\"component\":\"netfleet\",\"version\":\"$next_ver\"}" failed shell_upgrade_required
assert_live_runtime "$orig_ver"

stage=fault_bad_prevalidate
set_feed bad-prevalidate
run_op components_check '{}' succeeded
run_op components_update "{\"component\":\"netfleet\",\"version\":\"$next_ver\"}" failed bundle_prevalidate_failed
assert_live_runtime "$orig_ver"

stage=fault_bad_verify_instant_rollback
set_feed bad-verify
run_op components_check '{}' succeeded
run_op components_update "{\"component\":\"netfleet\",\"version\":\"$next_ver\"}" failed bundle_verify_failed_rolled_back
assert_live_runtime "$orig_ver"
[ ! -d "/usr/share/opl-netfleet/releases/$next_ver" ]

stage=good_bundle_upgrade
set_feed good-upgrade
run_op components_check '{}' succeeded
ubus -t 20 call opl-netfleet components_get '{}' >"$work/cget-good.json"
assert_json "$work/cget-good.json" '@.result.components[0].update_available' true
assert_json "$work/cget-good.json" '@.result.components[0].available_version' "$next_ver"
assert_json "$work/cget-good.json" '@.result.shell_upgrade_required' false
run_op components_update "{\"component\":\"netfleet\",\"version\":\"$next_ver\"}" succeeded
[ "$(readlink /usr/share/opl-netfleet/previous)" = "releases/$orig_ver" ]
[ "$(ls -1 /usr/share/opl-netfleet/releases | wc -l)" -le 2 ]
assert_live_runtime "$next_ver"

stage=manual_rollback
run_op components_rollback '{}' succeeded
[ "$(readlink /usr/share/opl-netfleet/previous)" = "releases/$next_ver" ]
assert_live_runtime "$orig_ver"

stage=crash_recovery
set_feed good-upgrade
run_op components_check '{}' succeeded
run_op components_update "{\"component\":\"netfleet\",\"version\":\"$next_ver\"}" succeeded
assert_live_runtime "$next_ver"

tx_root=/etc/opl-netfleet/package-transactions
tx_id=$(jsonfilter -i "$tx_root/request.json" -e '@.id')
[ -n "$tx_id" ]
ucode -e '
	import * as fs from "fs";
	const tx_dir = ARGV[0], id = ARGV[1];
	const j = json(fs.readfile(tx_dir + "/journal.json"));
	j.phase = "switching";
	fs.writefile(tx_dir + "/journal.json", sprintf("%J\n", j));
	fs.chmod(tx_dir + "/journal.json", 0600);
	fs.writefile(fs.dirname(tx_dir) + "/pending.json", sprintf("%J\n", { id: id, kind: "bundle" }));
	fs.chmod(fs.dirname(tx_dir) + "/pending.json", 0600);
' "$tx_root/$tx_id" "$tx_id"
/etc/init.d/opl-netfleet-update-recovery start
for attempt in $(seq 1 60); do
	if [ ! -e "$tx_root/pending.json" ] && [ "$(readlink /usr/share/opl-netfleet/current 2>/dev/null || true)" = "releases/$orig_ver" ]; then
		break
	fi
	[ "$attempt" -lt 60 ] || { echo "Bundle crash recovery did not complete in time" >&2; exit 1; }
	sleep 1
done
assert_live_runtime "$orig_ver"
[ ! -d "/usr/share/opl-netfleet/releases/$next_ver" ]

stage=complete
printf '{"schema_version":1,"ok":true,"source_commit":"%s","source_tree":"%s","manifest_sha256":"%s","scope":"openwrt-release-bundle-%s","checks":{"bad_signature_rejected":true,"min_shell_enforced":true,"prevalidate_rejected":true,"verify_failure_instant_rollback":true,"good_upgrade_atomic_switch":true,"manual_rollback":true,"crash_recovery_rollback":true,"zero_interruption_pid":true,"generation_pruned":true}}\n' \
	"$source_commit" "$source_tree" "$manifest_sha" "$pkg_mgr" >"$work/qualification.json"
cat "$work/qualification.json"
