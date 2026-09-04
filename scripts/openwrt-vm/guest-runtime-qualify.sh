#!/bin/sh
set -eu
umask 077

source_commit=${1:?}
source_tree=${2:?}
probe_port=${3:?}
work=/tmp/netfleet-runtime-fixture
bin=$work/bin
metrics=$work/metrics
main=/usr/libexec/opl-netfleet/main.uc
supervisor=/usr/libexec/opl-netfleet/supervisor.uc
secret=netfleet-vm-fixture
probe_url=https://www.gstatic.com:$probe_port/generate_204
supervisor_pid=""
helper_primary_pid=""
helper_reserve_pid=""
probe_relay_pid=""
stage=bootstrap

cleanup() {
	set +e
	[ -z "$supervisor_pid" ] || kill "$supervisor_pid" >/dev/null 2>&1
	/etc/init.d/nikki stop >/dev/null 2>&1
	[ -z "$helper_primary_pid" ] || kill "$helper_primary_pid" >/dev/null 2>&1
	[ -z "$helper_reserve_pid" ] || kill "$helper_reserve_pid" >/dev/null 2>&1
	[ -z "$probe_relay_pid" ] || kill "$probe_relay_pid" >/dev/null 2>&1
}
finish() {
	rc=$?
	trap - EXIT INT TERM
	if [ "$rc" -eq 0 ] && { [ "$stage" != complete ] || [ ! -s "$work/qualification.json" ]; }; then
		echo "OpenWrt runtime qualification exited without a complete receipt at stage: $stage" >&2
		rc=1
	fi
	if [ "$rc" -ne 0 ]; then
		echo "OpenWrt runtime qualification failed at stage: $stage" >&2
		df -h /tmp /overlay >&2 || true
		for dump in "$work"/connections.json "$work"/enable.json "$work"/compile.json "$work"/refresh*.json; do
			[ ! -f "$dump" ] || { echo "--- $dump" >&2; cat "$dump" >&2; }
		done
		if [ -f "$work/enable.json" ]; then
			echo "--- enable error" >&2
			jsonfilter -i "$work/enable.json" -e '@.error' >&2 || true
			jsonfilter -i "$work/enable.json" -e '@.detail.automatic.error' >&2 || true
			jsonfilter -i "$work/enable.json" -e '@.detail.automatic.summary' >&2 || true
			jsonfilter -i "$work/enable.json" -e '@.detail.automatic.provider_measurement_ok' >&2 || true
			jsonfilter -i "$work/enable.json" -e '@.detail.automatic.provider_state_available' >&2 || true
		fi
		for log in "$work"/package-manager.log "$work"/helper-primary.log "$work"/helper-reserve.log \
			"$work"/mihomo.log "$work"/*.stderr "$work"/*.txt; do
			[ ! -f "$log" ] || { echo "--- $log" >&2; cat "$log" >&2; }
		done
	fi
	cleanup
	exit "$rc"
}
trap finish EXIT INT TERM

mkdir -p "$bin" "$metrics" /etc/nikki/subscriptions /etc/nikki/profiles/opl-netfleet \
	/etc/nikki/run /etc/opl-netfleet/policy-sources /var/lib/opl-netfleet /usr/libexec
PATH="$bin:$PATH"
export PATH

ip route replace default via 192.168.1.2 dev br-lan
grep -Fq 'netfleet-probe.test' /etc/hosts || printf '192.168.1.2 netfleet-probe.test\n127.0.0.1 www.gstatic.com\n' >>/etc/hosts
/etc/init.d/dnsmasq restart
printf 'nameserver 192.168.1.3\n' >/etc/resolv.conf
stage=install_dependencies
: >"$work/package-manager.log"
dependencies_installed=false
for dependency_attempt in 1 2 3; do
	# An unrelated feed can fail transiently even when every package needed by
	# this fixture is available from the successfully refreshed feeds.
	package_result=true
	if command -v apk >/dev/null 2>&1; then
		apk --timeout 300 update >>"$work/package-manager.log" 2>&1 || true
		apk --timeout 300 add curl flock coreutils-date socat >>"$work/package-manager.log" 2>&1 || package_result=false
	else
		opkg update >>"$work/package-manager.log" 2>&1 || true
		opkg install curl flock coreutils-date socat >>"$work/package-manager.log" 2>&1 || package_result=false
	fi
	if [ "$package_result" = true ] &&
		command -v curl >/dev/null 2>&1 &&
		command -v flock >/dev/null 2>&1 &&
		command -v socat >/dev/null 2>&1 &&
		date +%s%3N >/dev/null 2>&1; then
		dependencies_installed=true
		break
	fi
	[ "$dependency_attempt" -eq 3 ] || sleep "$((dependency_attempt * 2))"
done
[ "$dependencies_installed" = true ]
cat /tmp/local-probe.crt >>/etc/ssl/certs/ca-certificates.crt
SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
export SSL_CERT_FILE
socat TCP-LISTEN:443,bind=127.0.0.1,reuseaddr,fork TCP:192.168.1.2:"$probe_port" \
	>"$work/probe-relay.log" 2>&1 &
probe_relay_pid=$!
stage=probe_relay
for relay_attempt in 1 2 3 4 5; do
	if curl -fsS --connect-timeout 2 --max-time 5 --resolve www.gstatic.com:443:127.0.0.1 \
		https://www.gstatic.com/generate_204 >/dev/null; then
		break
	fi
	[ "$relay_attempt" -lt 5 ] || exit 1
	sleep 1
done

stage=install_runtime_decompress
gzip -dc /tmp/mihomo-linux-arm64-v1.19.30.gz >"$bin/mihomo"
rm -f /tmp/mihomo-linux-arm64-v1.19.30.gz
stage=install_runtime_links
ln "$bin/mihomo" "$bin/netfleet-test-primary"
ln "$bin/mihomo" "$bin/netfleet-test-reserve"
ln /tmp/yq_linux_arm64-v4.53.6 "$bin/yq"
chmod 0755 "$bin/mihomo" "$bin/netfleet-test-primary" "$bin/netfleet-test-reserve" "$bin/yq"
cp -R /tmp/openwrt/files/usr/libexec/opl-netfleet /usr/libexec/
cp /tmp/openwrt/files/etc/init.d/opl-netfleet /etc/init.d/opl-netfleet
cp /tmp/openwrt/files/etc/opl-netfleet/policy-sources/base-v1.json \
	/etc/opl-netfleet/policy-sources/base-v1.json
cp /tmp/openwrt/files/etc/opl-netfleet/rulesets.lock.json /etc/opl-netfleet/rulesets.lock.json
mkdir -p /etc/nikki/run/rulesets
ruleset_index=0
while :; do
	ruleset_id=$(jsonfilter -i /etc/opl-netfleet/rulesets.lock.json -e "@.rulesets[$ruleset_index].id" 2>/dev/null || true)
	[ -n "$ruleset_id" ] || break
	ruleset_url=$(jsonfilter -i /etc/opl-netfleet/rulesets.lock.json -e "@.rulesets[$ruleset_index].url")
	ruleset_size=$(jsonfilter -i /etc/opl-netfleet/rulesets.lock.json -e "@.rulesets[$ruleset_index].size_bytes")
	ruleset_sha=$(jsonfilter -i /etc/opl-netfleet/rulesets.lock.json -e "@.rulesets[$ruleset_index].sha256")
	ruleset_path=/etc/nikki/run/rulesets/$ruleset_id.mrs
	curl -fsSL --connect-timeout 10 --max-time 90 "$ruleset_url" -o "$ruleset_path"
	[ "$(wc -c <"$ruleset_path" | tr -d ' ')" = "$ruleset_size" ]
	[ "$(sha256sum "$ruleset_path" | awk '{print $1}')" = "$ruleset_sha" ]
	ruleset_index=$((ruleset_index + 1))
done
[ "$ruleset_index" -gt 0 ]
chmod 0755 "$main" "$supervisor" /etc/init.d/opl-netfleet

stage=verify_ucode_runtime
ucode -e 'print("ucode-runtime-ok\n")' >"$work/ucode-version.txt" 2>&1
grep -qx ucode-runtime-ok "$work/ucode-version.txt"
stage=verify_mihomo_runtime
mihomo -v >"$work/mihomo-version.txt" 2>&1
grep -Fq 'v1.19.30' "$work/mihomo-version.txt"
stage=verify_yq_runtime
yq --version >"$work/yq-version.txt" 2>&1
grep -Fq 'v4.53.6' "$work/yq-version.txt"
stage=verify_external_route
curl -fsS --connect-timeout 5 --max-time 10 "$probe_url" >/dev/null

real_ubus=$(command -v ubus)
real_nft=$(command -v nft)
cat >"$bin/ubus" <<EOF
#!/bin/sh
if [ "\$1 \$2 \$3" = 'call network.interface.wan status' ]; then
	printf '{"up":true}\n'
	exit 0
fi
exec "$real_ubus" "\$@"
EOF
chmod 0755 "$bin/ubus"
cat >"$bin/nft" <<EOF
#!/bin/sh
if [ "\$*" = 'list chain inet nikki lan_tproxy' ]; then
	"$real_nft" "\$@" || exit
	printf '\t\tcounter comment "tproxy to :7892"\n'
	exit 0
fi
if [ "\$*" = 'list chain inet nikki lan_dns_hijack' ]; then
	"$real_nft" "\$@" || exit
	printf '\t\tcounter comment "redirect to :1053"\n'
	exit 0
fi
exec "$real_nft" "\$@"
EOF
chmod 0755 "$bin/nft"

cat >/etc/config/nikki <<EOF
config nikki 'config'
	option enabled '1'
	option profile 'subscription:base'

config mixin 'mixin'
	option api_secret '$secret'
	option api_listen '0.0.0.0:9090'
	option allow_lan '1'
	option dns_enabled '1'
	option dns_listen '[::]:1053'

config subscription 'base'
	option name 'VM Base'
	option success '1'

config subscription 'alpha'
	option name 'Alpha'
	option success '1'
	option avaliable '50 GB'

config subscription 'beta'
	option name 'Beta'
	option success '1'

config subscription 'invalid_source'
	option name 'Invalid Policy Source Fixture'
	option success '1'

config routing 'routing'
	option tproxy_route_table '80'
	option tun_route_table '81'
	option dummy_device 'nikki-dummy'
EOF

cat >/etc/nikki/subscriptions/base.yaml <<EOF
mixed-port: 7890
tproxy-port: 7892
allow-lan: true
external-controller: 0.0.0.0:9090
secret: $secret
mode: rule
log-level: info
ipv6: false
tls:
  custom-certifactes:
    - |
EOF
sed 's/^/      /' /tmp/local-probe.crt >>/etc/nikki/subscriptions/base.yaml
cat >>/etc/nikki/subscriptions/base.yaml <<EOF
proxies:
  - name: Base SOCKS
    type: socks5
    server: 127.0.0.1
    port: 1081
proxy-groups:
  - name: VM Egress
    type: select
    proxies:
      - Base SOCKS
      - DIRECT
rules:
  - MATCH,VM Egress
EOF

cat >/etc/nikki/subscriptions/alpha.yaml <<'EOF'
proxies:
  - name: Alpha Japan 01
    type: socks5
    server: 127.0.0.1
    port: 1081
  - name: Alpha Singapore 01
    type: socks5
    server: 127.0.0.1
    port: 1081
EOF

cat >/etc/nikki/subscriptions/beta.yaml <<'EOF'
proxies:
  - name: Beta Japan 01
    type: socks5
    server: 127.0.0.1
    port: 1082
  - name: Beta Singapore 01
    type: socks5
    server: 127.0.0.1
    port: 1082
EOF

cat >/etc/nikki/subscriptions/invalid_source.yaml <<'EOF'
dns: invalid
proxy-groups:
  - name: Invalid Egress
    type: select
    proxies:
      - DIRECT
rules:
  - MATCH,Invalid Egress
EOF

cat >"$work/manual-policy.json" <<EOF
{
  "schema_version": 2,
  "main": {"target": "openwrt-vm", "enabled": true},
  "policy_source": {"kind": "bundle", "ref": "bundle:base-v1"},
  "recovery_profile": {"ref": "subscription:base"},
  "routing_rules": [
    {"kind": "domain_suffix", "value": "private.example.invalid", "capability": "standard"}
  ],
  "bindings": {"海外加速": {"capability": "standard", "kind": "entry"}},
  "providers": {
    "alpha": {"section": "alpha", "enabled": true, "role": "primary", "billing": "subscription", "quota": {"available_field": "avaliable", "total_field": "total", "used_field": "used"}},
    "beta": {"section": "beta", "enabled": true, "role": "reserve", "billing": "buyout"}
  },
  "regions": {
    "japan": {"display_name": "Japan", "mode": "automatic"},
    "singapore": {"display_name": "Singapore", "mode": "automatic"}
  },
  "provider_regions": {
    "alpha": [
      {"region": "japan", "filter": "Alpha Japan"},
      {"region": "singapore", "filter": "Alpha Singapore"}
    ],
    "beta": [
      {"region": "japan", "filter": "Beta Japan"},
      {"region": "singapore", "filter": "Beta Singapore"}
    ]
  },
  "capabilities": {
    "standard": {"display_name": "Standard Egress", "display_order": 10, "enabled": true, "mode": "automatic"}
  },
  "selection": {"region_switch_margin_ms": 150, "leaf_switch_margin_ms": 150},
  "automation": {"enabled": true, "selection_interval_seconds": 300, "subscription_refresh_enabled": true, "subscription_refresh_interval_seconds": 3600, "poll_interval_seconds": 5, "startup_grace_seconds": 120, "runtime_grace_seconds": 30},
  "checks": {
    "provider_healthcheck_timeout_ms": 20000,
    "latency": {"method": "mihomo_delay", "url": "$probe_url", "timeout_ms": 3000, "expected_status": 204},
    "quota": {"source": "nikki_subscription_metadata", "zero_is_exhausted": true}
  },
  "evidence": {"path": "/etc/opl-netfleet/evidence.json"},
  "fail_open": {
    "healthcheck": {"path_probe_id": "vm-egress", "guard_probe_id": "vm-egress", "timeout_ms": 3000, "interval_seconds": 30, "max_failed_times": 1},
    "probes": [{"id": "vm-egress", "url": "$probe_url", "expected_status": 204}]
  }
}
EOF

cat >"$work/helper-primary.json" <<'EOF'
{"socks-port":1081,"mode":"rule","log-level":"silent","ipv6":false,"hosts":{"netfleet-probe.test":"192.168.1.2","www.gstatic.com":"127.0.0.1"},"rules":["MATCH,DIRECT"]}
EOF
cat >"$work/helper-reserve.json" <<'EOF'
{"socks-port":1082,"mode":"rule","log-level":"silent","ipv6":false,"hosts":{"netfleet-probe.test":"192.168.1.2","www.gstatic.com":"127.0.0.1"},"rules":["MATCH,DIRECT"]}
EOF
cat >"$work/runtime-owner.uc" <<'EOF'
import { readfile, writefile } from "fs";

const config = json(readfile(ARGV[0]));
if (type(config) != "object") exit(1);
config["mixed-port"] = 7890;
config["tproxy-port"] = 7892;
config["allow-lan"] = true;
config.secret = ARGV[1];
config["external-controller"] = "0.0.0.0:9090";
config.hosts = { "netfleet-probe.test": "192.168.1.2", "www.gstatic.com": "127.0.0.1" };
config.dns = { enable: true, listen: "[::]:1053", nameserver: ["system"] };
config.mode = "rule";
config["log-level"] = "warning";
if (!writefile(ARGV[2], sprintf("%J", config))) exit(1);
EOF
stage=start_proxy_helpers
"$bin/netfleet-test-primary" -d "$work/helper-primary" -f "$work/helper-primary.json" >"$work/helper-primary.log" 2>&1 &
helper_primary_pid=$!
"$bin/netfleet-test-reserve" -d "$work/helper-reserve" -f "$work/helper-reserve.json" >"$work/helper-reserve.log" 2>&1 &
helper_reserve_pid=$!

cat >/etc/init.d/nikki <<'EOF'
#!/bin/sh
pidfile=/var/run/nikki/mihomo.pid
run_dir=/etc/nikki/run

profile_path() {
	profile=$(uci -q get nikki.config.profile)
	case "$profile" in
		subscription:*) printf '/etc/nikki/subscriptions/%s.yaml\n' "${profile#subscription:}" ;;
		file:*) printf '/etc/nikki/profiles/%s\n' "${profile#file:}" ;;
		*) return 1 ;;
	esac
}

running() {
	[ -s "$pidfile" ] && kill -0 "$(cat "$pidfile")" >/dev/null 2>&1
}

start_runtime() {
	[ "$(uci -q get nikki.config.enabled)" = 1 ] || return 1
	source=$(profile_path) || return 1
	[ -f "$source" ] || return 1
	mkdir -p "$run_dir" /var/run/nikki
	case "$source" in
		*.json)
			ucode /tmp/netfleet-runtime-fixture/runtime-owner.uc "$source" \
				"$(uci -q get nikki.proxy.api_secret)" "$run_dir/config.yaml" || return 1
			;;
		*) cp "$source" "$run_dir/config.yaml" || return 1 ;;
	esac
	mihomo -d "$run_dir" -f "$run_dir/config.yaml" >>/tmp/netfleet-runtime-fixture/mihomo.log 2>&1 </dev/null &
	printf '%s\n' "$!" >"$pidfile"
	for attempt in $(seq 1 20); do
		if running && netstat -lnt 2>/dev/null | grep -Eq '[[:space:]](0\.0\.0\.0:7892|:::7892)[[:space:]]'; then
			nft add table inet nikki 2>/dev/null || true
			nft add chain inet nikki lan_tproxy 2>/dev/null || true
			nft add chain inet nikki lan_dns_hijack 2>/dev/null || true
			nft add rule inet nikki lan_tproxy counter
			nft add rule inet nikki lan_dns_hijack counter
			return 0
		fi
		sleep 1
	done
	return 1
}

stop_runtime() {
	if running; then
		pid=$(cat "$pidfile")
		kill "$pid" >/dev/null 2>&1 || true
		for attempt in $(seq 1 20); do
			kill -0 "$pid" >/dev/null 2>&1 || break
			sleep 1
		done
	fi
	rm -f "$pidfile" /var/run/nikki/started.flag \
		/var/run/nikki/bridge_nf_call_iptables.flag \
			/var/run/nikki/bridge_nf_call_ip6tables.flag
	nft delete table inet nikki >/dev/null 2>&1 || true
}

case "$1" in
	start) start_runtime ;;
	stop) stop_runtime ;;
	restart) stop_runtime; start_runtime ;;
	update_subscription)
		section=$2
		case "$section" in *[!A-Za-z0-9_]*|'') exit 1 ;; esac
		[ ! -e "/tmp/netfleet-runtime-fixture/fail-$section" ] || exit 1
		candidate="/tmp/netfleet-runtime-fixture/subscription-$section.next.yaml"
		[ ! -f "$candidate" ] || cp "$candidate" "/etc/nikki/subscriptions/$section.yaml"
		;;
	running|status) running ;;
	*) exit 1 ;;
esac
EOF
chmod 0755 /etc/init.d/nikki

stage=verify_proxy_helpers
for attempt in $(seq 1 20); do
	if curl -fsS --socks5-hostname 127.0.0.1:1081 --connect-timeout 2 --max-time 5 "$probe_url" >/dev/null &&
		curl -fsS --socks5-hostname 127.0.0.1:1082 --connect-timeout 2 --max-time 5 "$probe_url" >/dev/null; then
		break
	fi
	[ "$attempt" -lt 20 ] || exit 1
	sleep 1
done
stage=start_recovery_profile
/etc/init.d/nikki start
for attempt in $(seq 1 20); do
	if curl -fsS --connect-timeout 2 --max-time 3 -H "Authorization: Bearer $secret" \
		http://127.0.0.1:9090/version >/dev/null; then
		break
	fi
	[ "$attempt" -lt 20 ] || exit 1
	sleep 1
done

run_timed() {
	label=$1
	shift
	started_ms=$(date +%s%3N)
	if ! "$@" >"$work/$label.json" 2>"$work/$label.stderr"; then
		cat "$work/$label.json" >&2
		cat "$work/$label.stderr" >&2
		return 1
	fi
	finished_ms=$(date +%s%3N)
	printf '%s\n' "$((finished_ms - started_ms))" >"$metrics/$label.ms"
	[ "$(jsonfilter -i "$work/$label.json" -e '@.ok')" = true ]
}

run_locked() {
	lock=$1
	shift
	(
		exec 9>"$lock"
		flock 9
		"$@" 9>&-
	)
}

assert_controller() {
	checkpoint=$1
	{
		printf 'profile=%s\n' "$(uci -q get nikki.config.profile || true)"
		printf 'nikki_pid=%s\n' "$(cat /var/run/nikki/mihomo.pid 2>/dev/null || true)"
		pidof mihomo 2>/dev/null || true
		ubus call service list '{"name":"opl-netfleet"}' 2>/dev/null || true
	} >"$work/$checkpoint.txt"
	curl -fsS --connect-timeout 2 --max-time 3 -H "Authorization: Bearer $secret" \
		http://127.0.0.1:9090/version >/dev/null || {
		stage=$checkpoint
		return 1
	}
}

stage=onboarding_preview
run_timed onboarding_get ucode "$main" onboarding-get
[ "$(jsonfilter -i "$work/onboarding_get.json" -e '@.result.required')" = true ]
[ "$(jsonfilter -i "$work/onboarding_get.json" -e '@.result.ready')" = true ]
[ "$(jsonfilter -i "$work/onboarding_get.json" -e '@.result.preview.entry_group')" = 'VM Egress' ]
[ "$(jsonfilter -i "$work/onboarding_get.json" -e '@.result.preview.providers[0].id')" = alpha ]
[ "$(jsonfilter -i "$work/onboarding_get.json" -e '@.result.preview.providers[1].id')" = beta ]
onboarding_revision=$(jsonfilter -i "$work/onboarding_get.json" -e '@.result.revision')
[ -n "$onboarding_revision" ]
printf '{"request":{"revision":"%s-stale","confirmed":true}}\n' "$onboarding_revision" >"$work/onboarding-stale.json"
if run_locked /var/lock/opl-netfleet-deploy.lock ucode "$main" onboarding-apply "$work/onboarding-stale.json" >"$work/onboarding-stale-result.json" 2>&1; then
	exit 1
fi
[ "$(jsonfilter -i "$work/onboarding-stale-result.json" -e '@.error')" = onboarding_revision_conflict ]
[ ! -e /etc/opl-netfleet/policy.json ]
[ "$(uci -q get nikki.config.profile)" = subscription:base ]

stage=onboarding_apply
printf '{"request":{"revision":"%s","confirmed":true}}\n' "$onboarding_revision" >"$work/onboarding-request.json"
run_timed onboarding_apply run_locked /var/lock/opl-netfleet-deploy.lock ucode "$main" onboarding-apply "$work/onboarding-request.json"
[ "$(jsonfilter -i "$work/onboarding_apply.json" -e '@.result.state')" = active ]
[ "$(uci -q get nikki.config.profile)" = file:OPL-NetFleet.json ]
/etc/init.d/opl-netfleet enabled
/etc/init.d/opl-netfleet status >/dev/null 2>&1
/etc/init.d/opl-netfleet stop
/etc/init.d/opl-netfleet disable
for attempt in $(seq 1 20); do
	if ! /etc/init.d/opl-netfleet status >/dev/null 2>&1; then
		break
	fi
	[ "$attempt" -lt 20 ] || exit 1
	sleep 1
done
run_timed onboarding_disable run_locked /var/lock/opl-netfleet-deploy.lock ucode "$main" disable vm
[ "$(uci -q get nikki.config.profile)" = subscription:base ]
assert_controller onboarding_after_disable
ucode -e 'import { remove_artifact } from "/usr/libexec/opl-netfleet/adapters/nikki.uc"; exit(remove_artifact() ? 0 : 1)'
rm -f /etc/opl-netfleet/policy.json /etc/opl-netfleet/evidence.json
cp "$work/manual-policy.json" /etc/opl-netfleet/policy.json

write_config_request() {
	output=$1
	revision=$2
	policy_source_kind=$3
	policy_source_ref=$4
	selection_interval=$5
	japan_display_name=$6
	entry_group=$7
	cat >"$output" <<EOF
{"request":{"revision":"$revision","policy_source":{"kind":"$policy_source_kind","ref":"$policy_source_ref"},"recovery_profile_ref":"subscription:base","providers":{"alpha":{"section":"alpha","enabled":true,"role":"primary","billing":"subscription","region_ids":["japan","singapore"]},"beta":{"section":"beta","enabled":true,"role":"reserve","billing":"buyout","region_ids":["japan","singapore"]}},"regions":{"japan":{"display_name":"$japan_display_name","mode":"automatic"},"singapore":{"display_name":"Singapore","mode":"automatic"}},"capabilities":{"standard":{"display_name":"Standard","enabled":true,"mode":"automatic","region_ids":["japan","singapore"],"prefer_region_from":null,"entry_group":"$entry_group","policy_groups":[]}},"routing_rules":[],"automation":{"enabled":true,"selection_interval_seconds":$selection_interval,"subscription_refresh_enabled":true,"subscription_refresh_interval_seconds":3600},"safety":{"region_switch_margin_ms":150,"leaf_switch_margin_ms":150,"runtime_grace_seconds":30,"latency_url":"$probe_url","path_probe_url":"$probe_url","guard_probe_url":"$probe_url"}}}
EOF
}

stage=connections_readback
run_timed connections ucode "$main" connections
[ "$(jsonfilter -i "$work/connections.json" -e '@.result.count')" -ge 0 ]
! grep -Eq '"(id|sourceIP|source_ip|process|upload|download)"[[:space:]]*:' "$work/connections.json"
projected_port=$(ucode -e 'import { project_connections } from "/usr/libexec/opl-netfleet/adapters/mihomo.uc"; print(project_connections({ connections: [{ metadata: { destinationIP: "198.51.100.1", destinationPort: "443" } }] }, 1).connections[0].destination_port)')
[ "$projected_port" = 443 ]

stage=config_inactive
recovery_pid_before=$(cat /var/run/nikki/mihomo.pid)
run_timed config_get_inactive ucode "$main" config-get
[ "$(jsonfilter -i "$work/config_get_inactive.json" -e '@.result.active')" = false ]
[ "$(jsonfilter -i "$work/config_get_inactive.json" -e '@.result.recovery_profile.display_name')" = 'VM Base' ]
inactive_revision=$(jsonfilter -i "$work/config_get_inactive.json" -e '@.result.revision')
write_config_request "$work/config-request.json" "$inactive_revision" bundle bundle:base-v1 600 Japan '海外加速'
run_timed config_validate ucode "$main" config-validate "$work/config-request.json"
[ "$(jsonfilter -i "$work/config_validate.json" -e '@.result.valid')" = true ]
[ "$(jsonfilter -i "$work/config_validate.json" -e '@.result.change_count')" -gt 0 ]
run_timed config_save ucode "$main" config-save "$work/config-request.json"
[ "$(jsonfilter -i "$work/config_save.json" -e '@.result.state')" = saved ]
[ "$(jsonfilter -i "$work/config_save.json" -e '@.result.config.pending_apply')" = true ]
[ "$(uci -q get nikki.config.profile)" = subscription:base ]
[ "$(cat /var/run/nikki/mihomo.pid)" = "$recovery_pid_before" ]
saved_revision=$(jsonfilter -i "$work/config_save.json" -e '@.result.config.revision')
write_config_request "$work/config-request.json" "$saved_revision" bundle bundle:base-v1 600 Japan '海外加速'
run_timed config_apply_saved ucode "$main" config-apply "$work/config-request.json"
[ "$(jsonfilter -i "$work/config_apply_saved.json" -e '@.result.state')" = applied ]
[ "$(jsonfilter -i "$work/config_apply_saved.json" -e '@.result.change_count')" = 0 ]
[ "$(jsonfilter -i "$work/config_apply_saved.json" -e '@.result.config.pending_apply')" = false ]
[ "$(uci -q get nikki.config.profile)" = file:OPL-NetFleet.json ]
run_timed config_saved_disable ucode "$main" disable vm
[ "$(uci -q get nikki.config.profile)" = subscription:base ]
rm -f /etc/nikki/profiles/OPL-NetFleet.json \
	/etc/nikki/profiles/opl-netfleet/mvp.json \
	/etc/nikki/profiles/opl-netfleet/mvp.manifest.json

stage=validate_compile
run_timed validate ucode "$main" validate
printf '%s\n' 'not-owned' >/etc/nikki/profiles/OPL-NetFleet.json
if ucode "$main" compile >"$work/compile-conflict.json" 2>"$work/compile-conflict.stderr"; then
	exit 1
fi
[ "$(cat /etc/nikki/profiles/OPL-NetFleet.json)" = not-owned ]
[ ! -e /etc/nikki/profiles/opl-netfleet/mvp.json ]
rm -f /etc/nikki/profiles/OPL-NetFleet.json
run_timed compile ucode "$main" compile
[ "$(uci -q get nikki.config.profile)" = subscription:base ]
[ -s /etc/nikki/profiles/opl-netfleet/mvp.json ]
[ -s /etc/nikki/profiles/opl-netfleet/mvp.manifest.json ]
[ -L /etc/nikki/profiles/OPL-NetFleet.json ]
[ "$(readlink /etc/nikki/profiles/OPL-NetFleet.json)" = opl-netfleet/mvp.json ]
[ "$(sha256sum /etc/nikki/profiles/OPL-NetFleet.json | awk '{print $1}')" = \
	"$(sha256sum /etc/nikki/profiles/opl-netfleet/mvp.json | awk '{print $1}')" ]
[ -n "$(jsonfilter -i /etc/nikki/profiles/opl-netfleet/mvp.manifest.json -e '@.generated_groups.standard.providers.alpha.group')" ]
[ -n "$(jsonfilter -i /etc/nikki/profiles/opl-netfleet/mvp.manifest.json -e '@.generated_groups.standard.providers.beta.group')" ]

stage=enable_select
run_timed enable ucode "$main" enable vm
[ "$(uci -q get nikki.config.profile)" = file:OPL-NetFleet.json ]
run_timed select_auto ucode "$main" select standard auto vm
[ "$(jsonfilter -i "$work/select_auto.json" -e '@.result.state')" = selected ]

stage=direct_history_isolation
direct_guard=$(jsonfilter -i /etc/nikki/profiles/opl-netfleet/mvp.manifest.json \
	-e '@.generated_groups.standard.direct_guard_name')
automatic_group=$(jsonfilter -i /etc/nikki/profiles/opl-netfleet/mvp.manifest.json \
	-e '@.generated_groups.standard.automatic_name')
[ -n "$direct_guard" ]
[ -n "$automatic_group" ]
latest_history_time() {
	ucode -e '
		import { proxies } from "/usr/libexec/opl-netfleet/adapters/mihomo.uc";
		const state = proxies("netfleet-vm-fixture", 2);
		const history = state?.proxies?.[ARGV[0]]?.history ?? [];
		print(length(history) > 0 ? history[length(history) - 1].time : "");
	' "$1"
}
direct_history_before=$(latest_history_time DIRECT)
guard_history_before=$(latest_history_time "$direct_guard")
ucode -e '
	import { measure } from "/usr/libexec/opl-netfleet/adapters/latency.uc";
	const group = ARGV[0];
	const guard = ARGV[1];
	const result = measure("netfleet-vm-fixture", group, {
		latency: { method: "mihomo_delay", url: ARGV[2], timeout_ms: 3000, expected_status: 204 }
	});
	exit(result?.status == "ok" && result?.results?.[guard]?.status == "ok" ? 0 : 1);
' "$automatic_group" "$direct_guard" "$probe_url"
direct_history_after=$(latest_history_time DIRECT)
guard_history_after=$(latest_history_time "$direct_guard")
[ "$direct_history_after" = "$direct_history_before" ]
[ -n "$guard_history_after" ]
[ "$guard_history_after" != "$guard_history_before" ]

stage=config_active_apply
run_timed config_get_active ucode "$main" config-get
[ "$(jsonfilter -i "$work/config_get_active.json" -e '@.result.active')" = true ]
active_revision=$(jsonfilter -i "$work/config_get_active.json" -e '@.result.revision')
write_config_request "$work/config-request.json" "$active_revision" bundle bundle:base-v1 600 'Japan Updated' '海外加速'
run_timed config_apply ucode "$main" config-apply "$work/config-request.json"
[ "$(jsonfilter -i "$work/config_apply.json" -e '@.result.state')" = applied ]
[ "$(jsonfilter -i "$work/config_apply.json" -e '@.result.config.active')" = true ]
[ "$(jsonfilter -i /etc/opl-netfleet/policy.json -e '@.regions.japan.display_name')" = 'Japan Updated' ]
[ "$(uci -q get nikki.config.profile)" = file:OPL-NetFleet.json ]
/etc/init.d/nikki running >/dev/null 2>&1

stage=config_active_rollback
policy_digest_before=$(sha256sum /etc/opl-netfleet/policy.json | awk '{print $1}')
run_timed config_get_rollback ucode "$main" config-get
rollback_revision=$(jsonfilter -i "$work/config_get_rollback.json" -e '@.result.revision')
write_config_request "$work/config-request.json" "$rollback_revision" profile subscription:invalid_source 600 'Japan Updated' 'Invalid Egress'
if ucode "$main" config-apply "$work/config-request.json" >"$work/config-rollback.json" 2>"$work/config-rollback.stderr"; then
	exit 1
fi
[ "$(jsonfilter -i "$work/config-rollback.json" -e '@.error')" = staged_profile_test_failed ]
[ "$(jsonfilter -i "$work/config-rollback.json" -e '@.detail.rollback.state')" = active_restored ]
[ "$(sha256sum /etc/opl-netfleet/policy.json | awk '{print $1}')" = "$policy_digest_before" ]
[ "$(uci -q get nikki.config.profile)" = file:OPL-NetFleet.json ]
/etc/init.d/nikki running >/dev/null 2>&1
curl -fsS --connect-timeout 2 --max-time 3 -H "Authorization: Bearer $secret" \
	http://127.0.0.1:9090/version >/dev/null

stage=subscription_refresh_unchanged
active_pid_before=$(cat /var/run/nikki/mihomo.pid)
run_timed refresh_unchanged ucode "$main" refresh vm
[ "$(jsonfilter -i "$work/refresh_unchanged.json" -e '@.result.state')" = unchanged ]
[ "$(cat /var/run/nikki/mihomo.pid)" = "$active_pid_before" ]

stage=subscription_refresh_changed
cp /etc/nikki/subscriptions/alpha.yaml "$work/subscription-alpha.next.yaml"
printf '%s\n' '# refreshed fixture' >>"$work/subscription-alpha.next.yaml"
run_timed refresh_changed ucode "$main" refresh vm
[ "$(jsonfilter -i "$work/refresh_changed.json" -e '@.result.state')" = updated ]
[ "$(jsonfilter -i "$work/refresh_changed.json" -e '@.result.result.reloaded')" = true ]
[ "$(uci -q get nikki.config.profile)" = file:OPL-NetFleet.json ]
rm -f "$work/subscription-alpha.next.yaml"

stage=subscription_refresh_failed_provider
alpha_digest=$(sha256sum /etc/nikki/subscriptions/alpha.yaml | awk '{print $1}')
: >"$work/fail-alpha"
run_timed refresh_failed_provider ucode "$main" refresh vm
[ "$(jsonfilter -i "$work/refresh_failed_provider.json" -e '@.result.state')" = update_failed ]
[ "$(sha256sum /etc/nikki/subscriptions/alpha.yaml | awk '{print $1}')" = "$alpha_digest" ]
rm -f "$work/fail-alpha"

stage=subscription_refresh_rollback
artifact_digest=$(sha256sum /etc/nikki/profiles/opl-netfleet/mvp.json | awk '{print $1}')
policy_source=/etc/opl-netfleet/policy-sources/base-v1.json
cp -p "$policy_source" "$work/base-v1.json.bak"
cp /etc/nikki/subscriptions/alpha.yaml "$work/subscription-alpha.next.yaml"
printf '%s\n' '# rollback fixture' >>"$work/subscription-alpha.next.yaml"
if ! ucode -e '
	import { readfile, writefile } from "fs";
	const path = ARGV[0];
	const profile = json(readfile(path));
	if (type(profile?.["proxy-groups"]) != "array") {
		exit(1);
	}
	push(profile["proxy-groups"], {
		name: "NetFleet · 直连护栏",
		type: "select",
		proxies: ["DIRECT"]
	});
	if (!writefile(path, sprintf("%J\n", profile))) {
		exit(1);
	}
' "$policy_source"; then
	cp -p "$work/base-v1.json.bak" "$policy_source"
	exit 1
fi
refresh_failed=1
if ucode "$main" refresh vm >"$work/refresh_rollback.json" 2>"$work/refresh_rollback.stderr"; then
	refresh_failed=0
fi
cp -p "$work/base-v1.json.bak" "$policy_source"
rm -f "$work/subscription-alpha.next.yaml"
[ "$refresh_failed" -eq 1 ]
[ "$(jsonfilter -i "$work/refresh_rollback.json" -e '@.error')" = compile_rejected ]
[ "$(sha256sum /etc/nikki/subscriptions/alpha.yaml | awk '{print $1}')" = "$alpha_digest" ]
[ "$(sha256sum /etc/nikki/profiles/opl-netfleet/mvp.json | awk '{print $1}')" = "$artifact_digest" ]
[ "$(uci -q get nikki.config.profile)" = file:OPL-NetFleet.json ]
/etc/init.d/nikki running >/dev/null 2>&1
ucode "$main" status >"$work/refresh-status.json"
[ "$(jsonfilter -i "$work/refresh-status.json" -e '@.result.subscription_refresh.last_result')" = rollback_restored ]

: >"$metrics/status.ms"
stage=status_profile
for sample in $(seq 1 5); do
	status_started_ms=$(date +%s%3N)
	ucode "$main" status >"$work/status.json" 2>"$work/status.stderr"
	status_finished_ms=$(date +%s%3N)
	[ "$(jsonfilter -i "$work/status.json" -e '@.ok')" = true ]
	printf '%s\n' "$((status_finished_ms - status_started_ms))" >>"$metrics/status.ms"
done
sort -n "$metrics/status.ms" >"$metrics/status.sorted"
status_p50_ms=$(sed -n '3p' "$metrics/status.sorted")
status_p95_ms=$(sed -n '5p' "$metrics/status.sorted")

stage=supervisor_idle_profile
ucode "$supervisor" >"$work/supervisor.log" 2>&1 &
supervisor_pid=$!
sleep 1
supervisor_ticks_start=$(awk '{print $14 + $15}' "/proc/$supervisor_pid/stat")
supervisor_started=$(date +%s)
sleep 3
supervisor_ticks_end=$(awk '{print $14 + $15}' "/proc/$supervisor_pid/stat")
supervisor_finished=$(date +%s)
supervisor_rss_kib=$(awk '/^VmRSS:/ {print $2}' "/proc/$supervisor_pid/status")

active_pid=$(cat /var/run/nikki/mihomo.pid)
kill "$active_pid"
recovered=false
stage=supervisor_recovery
for attempt in $(seq 1 60); do
	if [ "$(uci -q get nikki.config.profile)" = subscription:base ] &&
		/etc/init.d/nikki running >/dev/null 2>&1 &&
		curl -fsS --connect-timeout 2 --max-time 3 -H "Authorization: Bearer $secret" \
			http://127.0.0.1:9090/version >/dev/null; then
		recovered=true
		break
	fi
	sleep 1
done
[ "$recovered" = true ]

stage=direct_and_disable
run_timed reenable run_locked /var/lock/opl-netfleet-deploy.lock ucode "$main" enable vm
flock -n /var/lock/opl-netfleet-deploy.lock true
run_timed select_direct run_locked /var/lock/opl-netfleet-deploy.lock ucode "$main" select standard DIRECT vm
[ "$(jsonfilter -i "$work/select_direct.json" -e '@.result.selected')" = DIRECT ]
[ "$(jsonfilter -i "$work/select_direct.json" -e '@.result.selected_leaf')" = DIRECT ]
[ "$(curl -4 -L -sS --noproxy '' --proxy http://127.0.0.1:7890 --connect-timeout 3 --max-time 8 -o /dev/null -w '%{http_code}' "$probe_url")" = 204 ]
run_timed disable run_locked /var/lock/opl-netfleet-deploy.lock ucode "$main" disable vm
[ "$(uci -q get nikki.config.profile)" = subscription:base ]
[ "$(jsonfilter -i "$work/disable.json" -e '@.result.state')" = native_profile ]
ucode "$main" status >"$work/native-status.json"
[ "$(jsonfilter -i "$work/native-status.json" -e '@.ok')" = true ]
[ "$(jsonfilter -i "$work/native-status.json" -e '@.result.active')" = false ]

stage=supervisor_lan_ingress_passthrough
run_timed ingress_compile run_locked /var/lock/opl-netfleet-deploy.lock ucode "$main" compile
run_timed ingress_reenable run_locked /var/lock/opl-netfleet-deploy.lock ucode "$main" enable vm
[ "$(jsonfilter -i "$work/ingress_reenable.json" -e '@.result.readback.runtime_identity_ok')" = true ]
flock /var/lock/opl-netfleet-deploy.lock sh -c 'sleep 38' &
recovery_lock_pid=$!
uci set nikki.mixin.allow_lan=0
uci commit nikki
ingress_passthrough=false
for attempt in $(seq 1 50); do
	if [ "$(uci -q get nikki.config.enabled)" = 0 ] &&
		[ "$(uci -q get nikki.config.profile)" = subscription:base ] &&
		! /etc/init.d/nikki running >/dev/null 2>&1 &&
		! nft list table inet nikki >/dev/null 2>&1; then
		ingress_passthrough=true
		break
	fi
	sleep 1
done
wait "$recovery_lock_pid"
[ "$ingress_passthrough" = true ]
ucode "$main" status >"$work/ingress-status.json"
[ "$(jsonfilter -i "$work/ingress-status.json" -e '@.result.runtime.passthrough_ready')" = true ]
[ "$(jsonfilter -i "$work/ingress-status.json" -e '@.result.profile')" = subscription:base ]

stage=supervisor_dns_ingress_passthrough
uci set nikki.mixin.allow_lan=1
uci set nikki.mixin.dns_enabled=1
uci commit nikki
run_timed dns_prepare_recovery run_locked /var/lock/opl-netfleet-deploy.lock \
	ucode "$main" prepare-recovery subscription:base
run_timed dns_compile run_locked /var/lock/opl-netfleet-deploy.lock ucode "$main" compile
run_timed dns_reenable run_locked /var/lock/opl-netfleet-deploy.lock ucode "$main" enable vm
ucode "$main" status >"$work/dns-ready-status.json"
[ "$(jsonfilter -i "$work/dns-ready-status.json" -e '@.result.runtime.lan_runtime.dns_ready')" = true ]
uci set nikki.mixin.dns_enabled=0
uci commit nikki
dns_passthrough=false
for attempt in $(seq 1 60); do
	if [ "$(uci -q get nikki.config.enabled)" = 0 ] &&
		[ "$(uci -q get nikki.config.profile)" = subscription:base ] &&
		! /etc/init.d/nikki running >/dev/null 2>&1 &&
		! nft list table inet nikki >/dev/null 2>&1; then
		dns_passthrough=true
		break
	fi
	sleep 1
done
[ "$dns_passthrough" = true ]
ucode "$main" status >"$work/dns-status.json"
[ "$(jsonfilter -i "$work/dns-status.json" -e '@.result.runtime.passthrough_ready')" = true ]
[ "$(jsonfilter -i "$work/dns-status.json" -e '@.result.profile')" = subscription:base ]

compile_ms=$(cat "$metrics/compile.ms")
enable_ms=$(cat "$metrics/enable.ms")
select_ms=$(cat "$metrics/select_auto.ms")
disable_ms=$(cat "$metrics/disable.ms")
supervisor_elapsed=$((supervisor_finished - supervisor_started))
supervisor_ticks=$((supervisor_ticks_end - supervisor_ticks_start))
supervisor_cpu_milli_percent=$(awk -v ticks="$supervisor_ticks" -v elapsed="$supervisor_elapsed" \
	'BEGIN { if (elapsed < 1) elapsed = 1; printf "%d", (ticks * 1000 / elapsed) + 0.5 }')

stage=complete
qualification=$work/qualification.json
qualification_temporary=$qualification.tmp
printf '{"ok":true,"source_commit":"%s","source_tree":"%s","checks":{"ucode_runtime":true,"mihomo_runtime":true,"connections_readback":true,"config_get":true,"config_validate":true,"config_save_inactive":true,"config_apply_saved":true,"config_apply_active":true,"config_apply_rollback":true,"compile_staged":true,"multi_provider_topology":true,"enable_readback":true,"select_readback":true,"direct_history_isolated":true,"subscription_refresh_unchanged":true,"subscription_refresh_changed":true,"subscription_refresh_provider_lkg":true,"subscription_refresh_rollback":true,"direct_fallback":true,"supervisor_native_recovery":true,"supervisor_lan_ingress_passthrough":true,"supervisor_lock_retry":true,"supervisor_dns_ingress_passthrough":true,"disable_native":true},"metrics":{"compile_ms":%s,"enable_ms":%s,"select_auto_ms":%s,"disable_ms":%s,"status_samples":5,"status_p50_ms":%s,"status_p95_ms":%s,"supervisor_window_seconds":%s,"supervisor_cpu_milli_percent":%s,"supervisor_rss_kib":%s},"runtime":{"openwrt_ucode":true,"mihomo_version":"v1.19.30","yq_version":"v4.53.6","nikki_fixture":"synthetic_lifecycle_only"}}\n' \
	"$source_commit" "$source_tree" "$compile_ms" "$enable_ms" "$select_ms" "$disable_ms" \
	"$status_p50_ms" "$status_p95_ms" "$supervisor_elapsed" "$supervisor_cpu_milli_percent" "$supervisor_rss_kib" \
	>"$qualification_temporary"
[ -s "$qualification_temporary" ]
[ "$(jsonfilter -i "$qualification_temporary" -e '@.ok')" = true ]
mv "$qualification_temporary" "$qualification"
cat "$qualification"
