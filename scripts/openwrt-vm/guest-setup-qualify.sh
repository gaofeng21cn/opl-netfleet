#!/bin/sh
# Exercise the public first-install path on a disposable VM without Nikki.
set -eu
umask 077
source_commit=${1:?}
source_tree=${2:?}
probe_port=${3:?}
feed_url=${4:-}
work=/tmp/netfleet-setup-fixture
candidate=$work/feed
main=/usr/libexec/opl-netfleet/main.uc
gateway=/usr/libexec/opl-netfleet/application/native_gateway.uc
lock=/var/lock/opl-netfleet-deploy.lock
stage=precondition
helper_pids=
package_checks=

test -f /tmp/netfleet-setup-vm-authorized
test ! -e /etc/init.d/nikki
test ! -e /etc/config/nikki
test ! -e /etc/config/netfleet
test ! -e /etc/opl-netfleet/backend.json
test ! -e /etc/opl-netfleet/policy.json
test ! -e /etc/opl-netfleet/evidence.json
test ! -e /etc/opl-netfleet/native
test ! -e /var/run/opl-netfleet-core
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
	/etc/init.d/opl-netfleet disable >/dev/null 2>&1
	/etc/init.d/opl-netfleet-core stop >/dev/null 2>&1
	/etc/init.d/opl-netfleet-core disable >/dev/null 2>&1
	for pid in $helper_pids; do kill "$pid" >/dev/null 2>&1; done
	ubus call network.interface.wan remove >/dev/null 2>&1
	ip netns del nf-setup-upstream >/dev/null 2>&1
	ip link del nf-setup-uplink >/dev/null 2>&1
	nft delete table ip netfleet_setup_fixture >/dev/null 2>&1
	if [ "$rc" -eq 0 ] && { [ "$stage" != complete ] || [ ! -s "$work/qualification.json" ]; }; then rc=1; fi
	if [ "$rc" -ne 0 ]; then
		echo "Native setup qualification failed at: $stage" >&2
		for file in "$work"/*-result.json "$work"/*.log; do
			[ ! -f "$file" ] || { echo "--- $file" >&2; tail -60 "$file" >&2; }
		done
		ubus call service list '{"name":"opl-netfleet-core"}' >&2
		logread | tail -60 >&2
	fi
	exit "$rc"
}
trap finish EXIT INT TERM
run_main() {
	# The lock stays in the parent shell, never in procd or its children.
	(
		exec 9>"$lock"
		flock 9
		ucode "$main" "$@" 9>&-
	)
}
assert_json() { [ "$(jsonfilter -i "$1" -e "$2")" = "$3" ]; }
digest() { sha256sum "$1" | awk '{print $1}'; }
package_identity() {
	apk info -e opl-netfleet luci-app-netfleet mihomo-meta >>"$work/packages.log" 2>&1
	assert_json /usr/share/opl-netfleet/build.json '@.source_commit' "$source_commit"
	assert_json /usr/share/opl-netfleet/build.json '@.source_tree' "$source_tree"
	[ "$(readlink /usr/bin/mihomo)" = /usr/libexec/mihomo ]
	while read -r expected path extra; do
		[ -n "$expected" ] || continue
		[ -z "${extra:-}" ]
		[ -f "/$path" ]
		[ "$(digest "/$path")" = "$expected" ]
	done <"$candidate/FILES.sha256"
}
direct_probe() {
	curl -fsS --noproxy '*' --connect-timeout 2 --max-time 8 \
		--cacert /tmp/local-probe.crt "https://192.168.1.2:$probe_port/generate_204"
}
setup_request() {
	ucode -e '
		import { readfile, writefile } from "fs";
		const plan = json(readfile(ARGV[0]));
		if (plan?.result?.ready != true || type(plan.result.revision) != "string") exit(1);
		const body = { request: { confirmed: true, revision: plan.result.revision,
			source: { id: "setup", name: "VM Setup", url: ARGV[2] } } };
		exit(writefile(ARGV[1], sprintf("%J", body)) ? 0 : 1);
	' "$1" "$2" "$3"
	chmod 0600 "$2"
}
unconfigured() {
	test ! -e /etc/config/netfleet
	test ! -e /etc/opl-netfleet/backend.json
	test ! -e /etc/opl-netfleet/policy.json
	test ! -e /etc/opl-netfleet/evidence.json
	test ! -e /etc/opl-netfleet/native
	test ! -e /var/run/opl-netfleet-core
	! /etc/init.d/opl-netfleet-core enabled
	! /etc/init.d/opl-netfleet enabled
	! /etc/init.d/opl-netfleet running
	ucode "$gateway" status >"$work/clean-result.json"
	assert_json "$work/clean-result.json" '@.result.clean' true
	assert_json "$work/clean-result.json" '@.result.core_running' false
}

stage=dependencies
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
ip route replace default via 192.168.1.2 dev br-lan
printf 'nameserver 192.168.1.3\n' >/etc/resolv.conf
: >"$work/packages.log"
for attempt in 1 2 3; do
	apk --timeout 120 update >>"$work/packages.log" 2>&1 || true
	if apk --timeout 120 add curl flock ip-full kmod-veth kmod-nft-tproxy kmod-nft-socket \
		ucode-mod-fs ucode-mod-uci ucode-mod-ubus ucode-mod-uloop >>"$work/packages.log" 2>&1; then
		break
	fi
	[ "$attempt" -lt 3 ] || exit 1
	sleep "$((attempt * 2))"
done
if [ -n "$feed_url" ]; then
	stage=signed_package_install
	mkdir -p "$candidate"
	for artifact in manifest.json install-netfleet.sh FILES.sha256; do
		uclient-fetch -q -O "$candidate/$artifact" "$feed_url/$artifact"
	done
	assert_json "$candidate/manifest.json" '@.source_commit' "$source_commit"
	assert_json "$candidate/manifest.json" '@.source_tree' "$source_tree"
	assert_json "$candidate/manifest.json" '@.package_format' apk
	[ "$(digest "$candidate/install-netfleet.sh")" = "$(jsonfilter -i "$candidate/manifest.json" -e '@.feed_bootstrap.sha256')" ]
	[ "$(digest "$candidate/FILES.sha256")" = "$(jsonfilter -i "$candidate/manifest.json" -e '@.files_manifest.sha256')" ]
	NETFLEET_FEED_BASE="$feed_url" NETFLEET_ALLOW_INSECURE_FEED=1 \
		sh "$candidate/install-netfleet.sh" >>"$work/packages.log" 2>&1
	[ -s /etc/apk/keys/opl-netfleet-apk.pem ]
	[ "$(cat /etc/apk/repositories.d/opl-netfleet.list)" = "$feed_url/packages.adb" ]
	package_identity
else
	gzip -dc /tmp/mihomo-linux-arm64-v1.19.30.gz >"$work/bin/mihomo"
	chmod 0755 "$work/bin/mihomo"
	ln -s "$work/bin/mihomo" /usr/bin/mihomo
	cp /tmp/yq_linux_arm64-v4.53.6 "$work/bin/yq"
	chmod 0755 "$work/bin/yq"
	ln -s "$work/bin/yq" /usr/bin/yq
	cp -R /tmp/openwrt/files/usr/libexec/opl-netfleet /usr/libexec/
	mkdir -p /usr/share/opl-netfleet /etc/opl-netfleet
	cp -R /tmp/openwrt/files/usr/share/opl-netfleet/nikki /usr/share/opl-netfleet/
	cp /tmp/openwrt/files/etc/config/netfleet /usr/share/opl-netfleet/netfleet.config
	cp /tmp/openwrt/files/etc/init.d/opl-netfleet-core /etc/init.d/opl-netfleet-core
	cp /tmp/openwrt/files/etc/init.d/opl-netfleet /etc/init.d/opl-netfleet
	chmod 0755 "$main" /usr/libexec/opl-netfleet/supervisor.uc "$gateway" /etc/init.d/opl-netfleet-core /etc/init.d/opl-netfleet
fi
# Source diagnostics already hold the core in tmpfs; share those bytes while
# retaining a distinct helper process name. APK installs live on another mount.
if [ -n "$feed_url" ]; then
	cp "$(readlink -f /usr/bin/mihomo)" "$work/bin/nf-setup-proxy"
else
	ln "$work/bin/mihomo" "$work/bin/nf-setup-proxy"
fi
chmod 0755 "$work/bin/nf-setup-proxy"
if [ -n "$feed_url" ]; then
	! /etc/init.d/opl-netfleet-core enabled
	! /etc/init.d/opl-netfleet enabled
	! /etc/init.d/opl-netfleet running
else
	/etc/init.d/opl-netfleet-core disable
	/etc/init.d/opl-netfleet disable
fi
cat /tmp/local-probe.crt >>/etc/ssl/certs/ca-certificates.crt
printf '192.168.1.2 netfleet-probe.test www.gstatic.com\n' >>/etc/hosts

stage=real_upstream
ip netns add nf-setup-upstream
ip netns exec nf-setup-upstream ip link add nf-setup-peer type veth peer name nf-setup-uplink netns 1
ip link set nf-setup-uplink up
ip netns exec nf-setup-upstream ip link set lo up
ip netns exec nf-setup-upstream ip link set nf-setup-peer up
ip netns exec nf-setup-upstream ip addr add 198.18.1.2/30 dev nf-setup-peer
ip netns exec nf-setup-upstream ip route add default via 198.18.1.1
ubus call network add_dynamic '{"name":"wan","proto":"static","device":"nf-setup-uplink","ipaddr":["198.18.1.1/30"],"dns":["198.18.1.2"]}' >"$work/wan-result.json"
ubus call network.interface.wan up >>"$work/wan-result.json"
for attempt in 1 2 3 4 5; do
	[ "$(ubus call network.interface.wan status | jsonfilter -e '@.up')" != true ] || break
	sleep 1
done
ubus call network.interface.wan status >"$work/wan-status-result.json"
assert_json "$work/wan-status-result.json" '@.up' true
assert_json "$work/wan-status-result.json" '@["dns-server"][0]' 198.18.1.2
ip -j route get 198.18.1.2 >"$work/resolver-route-result.json"
assert_json "$work/resolver-route-result.json" '@[0].dev' nf-setup-uplink
uci set firewall.nfsetup=zone
uci set firewall.nfsetup.name=nfsetup
uci add_list firewall.nfsetup.device=nf-setup-uplink
uci set firewall.nfsetup.input=ACCEPT
uci set firewall.nfsetup.output=ACCEPT
uci set firewall.nfsetup.forward=ACCEPT
uci set firewall.nfsetup_forward=forwarding
uci set firewall.nfsetup_forward.src=nfsetup
uci set firewall.nfsetup_forward.dest=lan
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
nft -s list table ip netfleet_setup_fixture >"$work/foreign.before.nft"
ip netns exec nf-setup-upstream dnsmasq --keep-in-foreground --port=53 \
	--listen-address=198.18.1.2 --bind-interfaces --no-resolv --no-hosts \
	--address=/netfleet-probe.test/192.168.1.2 --address=/www.gstatic.com/192.168.1.2 \
	--pid-file="$work/dns.pid" >"$work/dns.log" 2>&1 &
helper_pids="$helper_pids $!"
cat >"$work/helper.json" <<'EOF'
{"mixed-port":1081,"allow-lan":true,"bind-address":"198.18.1.2","external-controller":"198.18.1.2:19091","mode":"direct","log-level":"warning","ipv6":false,"hosts":{"netfleet-probe.test":"192.168.1.2","www.gstatic.com":"192.168.1.2"}}
EOF
ip netns exec nf-setup-upstream "$work/bin/nf-setup-proxy" -d "$work" -f "$work/helper.json" >"$work/helper.log" 2>&1 &
helper_pids="$helper_pids $!"
for attempt in $(seq 1 15); do
	if curl -fsS --socks5-hostname 198.18.1.2:1081 --max-time 4 https://www.gstatic.com/generate_204 >/dev/null; then break; fi
	[ "$attempt" -lt 15 ] || exit 1
	sleep 1
done
direct_probe

stage=setup_read_only
unconfigured
run_main native-setup-get >"$work/setup-get-result.json"
assert_json "$work/setup-get-result.json" '@.ok' true
assert_json "$work/setup-get-result.json" '@.result.ready' true
unconfigured

stage=failed_download_rollback
setup_request "$work/setup-get-result.json" "$work/missing-request.json" \
	"https://192.168.1.2:$probe_port/native-subscriptions/missing?token=vm-only-credential"
run_main native-setup-apply "$work/missing-request.json" >"$work/missing-result.json" || true
assert_json "$work/missing-result.json" '@.ok' false
assert_json "$work/missing-result.json" '@.result.rollback.ok' true
unconfigured
direct_probe

stage=successful_setup
run_main native-setup-get >"$work/setup-retry-result.json"
assert_json "$work/setup-retry-result.json" '@.result.ready' true
setup_request "$work/setup-retry-result.json" "$work/setup-request.json" \
	"https://192.168.1.2:$probe_port/native-subscriptions/setup?token=vm-only-credential"
run_main native-setup-apply "$work/setup-request.json" >"$work/setup-apply-result.json"
assert_json "$work/setup-apply-result.json" '@.ok' true
assert_json "$work/setup-apply-result.json" '@.result.state' native_ready
assert_json "$work/setup-apply-result.json" '@.result.onboarding_required' true
assert_json /etc/opl-netfleet/backend.json '@.kind' native-mihomo
[ "$(uci -q get netfleet.config.profile)" = subscription:setup ]
[ "$(uci -q get netfleet.mixin.outbound_interface)" = wan ]
[ "$(uci -q get netfleet.netfleet_dns_0.nameserver)" = 198.18.1.2 ]
/etc/init.d/opl-netfleet-core enabled
ucode "$gateway" status >"$work/gateway-ready-result.json"
assert_json "$work/gateway-ready-result.json" '@.result.ready' true
run_main onboarding-get >"$work/onboarding-get-result.json"
assert_json "$work/onboarding-get-result.json" '@.result.ready' true
assert_json "$work/onboarding-get-result.json" '@.result.required' true

stage=shared_onboarding
ucode -e '
	import { readfile, writefile } from "fs";
	const plan = json(readfile(ARGV[0]));
	exit(writefile(ARGV[1], sprintf("%J", { request: { confirmed: true, revision: plan.result.revision } })) ? 0 : 1);
' "$work/onboarding-get-result.json" "$work/onboarding-request.json"
chmod 0600 "$work/onboarding-request.json"
run_main onboarding-apply "$work/onboarding-request.json" >"$work/onboarding-apply-result.json"
assert_json "$work/onboarding-apply-result.json" '@.ok' true
assert_json "$work/onboarding-apply-result.json" '@.result.state' active
run_main status >"$work/active-status-result.json"
assert_json "$work/active-status-result.json" '@.result.runtime.mihomo_running' true
assert_json "$work/active-status-result.json" '@.result.runtime.controller_available' true
run_main probe >"$work/active-probe-result.json"
assert_json "$work/active-probe-result.json" '@.ok' true
curl -fsS --socks5-hostname 127.0.0.1:7890 --max-time 10 https://www.gstatic.com/generate_204
direct_probe

if [ -n "$feed_url" ]; then
	stage=native_package_upgrade
	profile_before=$(uci -q get netfleet.config.profile)
	config_before=$(digest /etc/config/netfleet)
	cache_before=$(digest /etc/opl-netfleet/native/subscriptions/setup.yaml)
	policy_before=$(digest /etc/opl-netfleet/policy.json)
	core_before=$(digest /usr/libexec/mihomo)
	apk --timeout 300 fix --reinstall opl-netfleet luci-app-netfleet >>"$work/packages.log" 2>&1
	[ ! -e /tmp/opl-netfleet-package-upgrade-state ]
	[ "$(uci -q get netfleet.config.profile)" = "$profile_before" ]
	[ "$(digest /etc/config/netfleet)" = "$config_before" ]
	[ "$(digest /etc/opl-netfleet/native/subscriptions/setup.yaml)" = "$cache_before" ]
	[ "$(digest /etc/opl-netfleet/policy.json)" = "$policy_before" ]
	[ "$(digest /usr/libexec/mihomo)" = "$core_before" ]
	package_identity
	/etc/init.d/opl-netfleet enabled
	/etc/init.d/opl-netfleet running
	/etc/init.d/opl-netfleet-core enabled
	ucode "$gateway" status >"$work/upgraded-gateway-result.json"
	assert_json "$work/upgraded-gateway-result.json" '@.result.ready' true
	run_main probe >"$work/upgraded-probe-result.json"
	assert_json "$work/upgraded-probe-result.json" '@.ok' true
	curl -fsS --socks5-hostname 127.0.0.1:7890 --max-time 10 https://www.gstatic.com/generate_204
fi

stage=disable_and_cleanup
run_main disable >"$work/disable-result.json"
assert_json "$work/disable-result.json" '@.ok' true
[ "$(uci -q get netfleet.config.profile)" = subscription:setup ]
ucode "$gateway" status >"$work/recovery-result.json"
assert_json "$work/recovery-result.json" '@.result.ready' true
/etc/init.d/opl-netfleet stop
/etc/init.d/opl-netfleet-core stop
for attempt in $(seq 1 10); do
	ucode "$gateway" status >"$work/stopped-result.json"
	[ "$(jsonfilter -i "$work/stopped-result.json" -e '@.result.core_running')" != false ] || break
	sleep 1
done
assert_json "$work/stopped-result.json" '@.result.clean' true
assert_json "$work/stopped-result.json" '@.result.core_running' false
direct_probe
nft -s list table ip netfleet_setup_fixture >"$work/foreign.after.nft"
cmp "$work/foreign.before.nft" "$work/foreign.after.nft"
test ! -e /etc/init.d/nikki
test ! -e /etc/config/nikki

if [ -n "$feed_url" ]; then
	stage=native_package_remove
	source_before=$(uci -q get netfleet.setup.url)
	[ -n "$source_before" ]
	apk --timeout 300 del luci-app-netfleet opl-netfleet >>"$work/packages.log" 2>&1
	! apk info -e opl-netfleet >/dev/null 2>&1
	! apk info -e luci-app-netfleet >/dev/null 2>&1
	[ ! -e "$main" ]
	[ ! -e /etc/init.d/opl-netfleet-core ]
	[ "$(uci -q get netfleet.setup.url)" = "$source_before" ]
	[ "$(uci -q get netfleet.config.profile)" = subscription:setup ]
	[ "$(digest /etc/opl-netfleet/native/subscriptions/setup.yaml)" = "$cache_before" ]
	[ "$(digest /etc/opl-netfleet/policy.json)" = "$policy_before" ]
	assert_json /etc/opl-netfleet/backend.json '@.kind' native-mihomo
	[ -z "$(pidof mihomo 2>/dev/null || true)" ]
	! nft list table inet netfleet >/dev/null 2>&1
	! ip -4 rule show | grep -q 'lookup 11900'
	! ip -6 rule show | grep -q 'lookup 11900'
	[ -z "$(ip -4 route show table 11900 2>/dev/null || true)" ]
	[ -z "$(ip -6 route show table 11900 2>/dev/null || true)" ]
	direct_probe
	package_checks=',"signed_package_install":true,"installed_build_identity":true,"native_package_upgrade":true,"upgrade_preserves_private_state":true,"upgrade_gateway_ready":true,"package_remove_clean":true,"remove_preserves_private_sources":true'
fi

stage=complete
printf '{"schema_version":1,"ok":true,"source_commit":"%s","source_tree":"%s","scope":"native-mihomo-first-install","production_ready":false,"checks":{"nikki_absent":true,"real_netifd_upstream":true,"get_read_only":true,"failed_download_rollback":true,"failed_setup_direct_usable":true,"native_setup":true,"gateway_ready":true,"shared_onboarding":true,"shared_probe":true,"proxy_traffic":true,"disable_restores_subscription":true,"stop_cleans_dataplane":true,"direct_after_stop":true,"foreign_nft_unchanged":true%s}}\n' \
	"$source_commit" "$source_tree" "$package_checks" >"$work/qualification.json"
cat "$work/qualification.json"
