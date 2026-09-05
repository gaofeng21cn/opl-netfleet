#!/bin/sh
set -eu
umask 077

source_commit=${1:?}
source_tree=${2:?}
real_ubus=$(command -v ubus)
work=/tmp/netfleet-deploy-fixture
bundle=$work/bundle
payload=$work/payload
bin=$work/bin
state=$work/state
rm -rf -- "$work"
mkdir -p "$bundle" "$payload/usr/libexec/opl-netfleet" "$payload/etc/init.d" \
	"$payload/etc/opl-netfleet" "$bin" "$state" /etc/nikki/subscriptions \
	/etc/nikki/profiles/opl-netfleet /var/lib/opl-netfleet /usr/libexec/opl-netfleet

cat >"$bin/ucode" <<'EOF'
#!/bin/sh
action=$2
case "$action" in
	validate-schema|validate|probe|prepare-recovery|compile)
		printf '{"ok":true,"action":"%s","result":{}}\n' "$action"
		;;
	status)
		profile=$(uci -q get nikki.config.profile 2>/dev/null || true)
		active=false
		case "$profile" in
			file:OPL-NetFleet.json|file:opl-netfleet/mvp.json) active=true ;;
		esac
		printf '{"ok":true,"action":"status","result":{"active":%s,"runtime":{"netfleet_present":%s,"mihomo_running":true,"controller_available":true}}}\n' "$active" "$active"
		;;
	disable|restore-recovery)
		uci set nikki.config.profile=subscription:base
		uci commit nikki
		printf '{"ok":true,"action":"%s","result":{"state":"native_profile","protected_probes":{"ok":true}}}\n' "$action"
		;;
	enable)
		printf '{"ok":false,"action":"enable","error":"initialization_failed"}\n'
		exit 1
		;;
	*)
		printf '{"ok":false,"action":"%s","error":"unknown_action"}\n' "$action"
		exit 1
		;;
esac
EOF

for command in mihomo yq; do
	cat >"$bin/$command" <<'EOF'
#!/bin/sh
exit 0
EOF
done
cat >"$bin/curl" <<'EOF'
#!/bin/sh
for argument in "$@"; do
	if [ "$argument" = "http://127.0.0.1/ubus" ]; then
		if [ -f /tmp/netfleet-deploy-fixture/state/session-granted ]; then
			printf '{"jsonrpc":"2.0","id":1,"result":[0,{}]}\n'
		else
			printf '{"jsonrpc":"2.0","id":1,"error":{"code":-32002,"message":"Access denied"}}\n'
		fi
		exit 0
	fi
done
while [ "$#" -gt 0 ]; do
	if [ "$1" = "-o" ]; then
		output=$2
		break
	fi
	shift
done
[ -n "${output:-}" ] || exit 0
name=$(basename "$output" .tmp)
cp "/tmp/netfleet-deploy-fixture/state/ruleset-source/$name" "$output"
EOF
cat >"$bin/flock" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$bin/pidof" <<'EOF'
#!/bin/sh
[ "$1" = mihomo ] && { echo 4242; exit 0; }
exit 1
EOF
cat >"$bin/ip" <<'EOF'
#!/bin/sh
echo 'default via 192.168.1.2 dev eth0'
EOF
cat >"$bin/ubus" <<'EOF'
#!/bin/sh
if [ "$1 $2 $3" = 'call session create' ]; then
	printf '{"ubus_rpc_session":"0123456789abcdef0123456789abcdef"}\n'
	exit 0
fi
if [ "$1 $2 $3" = 'call session grant' ]; then
	printf '%s\n' "${4:-}" | grep -Fq '"objects":[["luci","getFeatures"]]' || exit 1
	: >/tmp/netfleet-deploy-fixture/state/session-granted
	echo '{}'
	exit 0
fi
if [ "$1 $2 $3" = 'call session destroy' ]; then
	rm -f /tmp/netfleet-deploy-fixture/state/session-granted
	echo '{}'
	exit 0
fi
if [ "$1 $2 $3" = 'call system board' ]; then
	echo '{}'
	exit 0
fi
if [ "$1 $2 $3" = '-v list luci' ]; then
	cat <<'METHODS'
'luci' @fixture
	"getFeatures":{}
METHODS
	exit 0
fi
if [ "$1 $2 $3" = '-v list opl-netfleet' ]; then
	cat <<'METHODS'
'opl-netfleet' @fixture
	"status":{}
	"events":{}
	"connections":{}
	"probe":{}
	"config_get":{}
	"config_validate":{}
	"config_save":{}
	"config_apply":{}
	"enable":{}
	"select_auto":{}
	"refresh":{}
	"disable":{}
METHODS
	exit 0
fi
exit 1
EOF
chmod 0755 "$bin"/*

cat >/etc/config/nikki <<'EOF'
config nikki 'config'
	option enabled '1'
	option profile 'subscription:base'

config procd 'procd'
	option fast_reload '1'

config mixin 'mixin'
	option mixin_file_content '1'
	option api_secret 'fixture-secret'

config log 'log'
	option clear_at_stop '1'

config proxy 'proxy'
	option tcp_mode 'redirect'
	option udp_mode 'tun'

config sniff
	option protocol 'HTTP'

config sniff
	option protocol 'TLS'

config sniff
	option protocol 'QUIC'

config subscription 'base'
	option name 'Base Provider'
	option url 'https://subscription.invalid/fixture'
	option user_agent 'mihomo'
	option success '1'
EOF
cat >/etc/init.d/nikki <<'EOF'
#!/bin/sh
case "$1" in
	status) echo running ;;
	restart|stop) : ;;
	update_subscription)
		mkdir -p /etc/nikki/subscriptions
		printf 'proxies: []\nproxy-groups: []\nrules: []\n' >"/etc/nikki/subscriptions/$2.yaml"
		uci set "nikki.$2.success=1"
		uci commit nikki
		;;
	*) exit 1 ;;
esac
EOF
chmod 0755 /etc/init.d/nikki
printf 'proxies: []\nproxy-groups: []\nrules: []\n' >/etc/nikki/subscriptions/base.yaml
printf 'nikki-rules: []\n' >/etc/nikki/mixin.yaml
printf 'old-events\n' >/var/lib/opl-netfleet/events.json
printf 'old-main\n' >/usr/libexec/opl-netfleet/main.uc
chmod 0755 /usr/libexec/opl-netfleet/main.uc

cat >"$payload/usr/libexec/opl-netfleet/main.uc" <<'EOF'
new-main
EOF
cat >"$payload/etc/init.d/opl-netfleet" <<'EOF'
#!/bin/sh
state=/tmp/netfleet-deploy-fixture/state
case "$1" in
	enabled) test -f "$state/supervisor-enabled" ;;
	enable) : >"$state/supervisor-enabled" ;;
	disable) rm -f "$state/supervisor-enabled" ;;
	status) test -f "$state/supervisor-running" ;;
	start|restart) : >"$state/supervisor-running" ;;
	stop) rm -f "$state/supervisor-running" ;;
	*) exit 1 ;;
esac
EOF
cat >"$payload/etc/opl-netfleet/policy.example.json" <<'EOF'
{"schema_version":2}
EOF
mkdir -p "$state/ruleset-source"
printf 'fixture-cn-domain\n' >"$state/ruleset-source/cn-domain.mrs"
printf 'fixture-cn-ip\n' >"$state/ruleset-source/cn-ip.mrs"
printf 'fixture-geolocation-non-cn\n' >"$state/ruleset-source/geolocation-non-cn.mrs"
commit=4d065eb9c68fb13603fa4678cc34735db76cabb8
cn_domain_sha=$(sha256sum "$state/ruleset-source/cn-domain.mrs" | awk '{print $1}')
cn_ip_sha=$(sha256sum "$state/ruleset-source/cn-ip.mrs" | awk '{print $1}')
non_cn_sha=$(sha256sum "$state/ruleset-source/geolocation-non-cn.mrs" | awk '{print $1}')
cat >"$payload/etc/opl-netfleet/rulesets.lock.json" <<EOF
{"schema":"opl-netfleet-ruleset-lock.v1","upstream":{"repository":"MetaCubeX/meta-rules-dat","commit":"$commit","license":"GPL-3.0"},"rulesets":[{"id":"cn-domain","behavior":"domain","format":"mrs","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/$commit/fixture/cn-domain.mrs","size_bytes":18,"sha256":"$cn_domain_sha"},{"id":"cn-ip","behavior":"ipcidr","format":"mrs","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/$commit/fixture/cn-ip.mrs","size_bytes":14,"sha256":"$cn_ip_sha"},{"id":"geolocation-non-cn","behavior":"domain","format":"mrs","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/$commit/fixture/geolocation-non-cn.mrs","size_bytes":27,"sha256":"$non_cn_sha"}]}
EOF
chmod 0755 "$payload/usr/libexec/opl-netfleet/main.uc" "$payload/etc/init.d/opl-netfleet"

(
	cd "$payload"
	find . -type f | LC_ALL=C sort | while read -r path; do
		path=${path#./}
		printf '%s  %s\n' "$(sha256sum "$path" | awk '{print $1}')" "$path"
	done >"$bundle/FILES.sha256"
	tar -cf "$bundle/payload.tar" .
)
cp /tmp/deploy-openwrt-remote.sh "$bundle/deploy-openwrt-remote.sh"
cp "$payload/etc/opl-netfleet/rulesets.lock.json" "$bundle/rulesets.lock.json"
cat >"$bundle/policy.json" <<'EOF'
{"schema_version":2,"main":{"target":"openwrt-vm","enabled":true},"policy_source":{"kind":"profile","ref":"subscription:base"},"recovery_profile":{"ref":"subscription:base"}}
EOF
cat >"$bundle/subscriptions.json" <<'EOF'
{"schema_version":1,"subscriptions":[{"section":"base","name":"Base Provider","url":"https://subscription.invalid/fixture","user_agent":"mihomo"}]}
EOF
printf 'nikki-rules: []\n' >"$bundle/nikki-mixin.yaml"
cat >"$bundle/platform.json" <<'EOF'
{"schema_version":1,"target":"openwrt-vm","nikki":{"scheduled_restart":false,"test_profile":true,"fast_reload":false,"api_listen":"0.0.0.0:9090","api_secret_required":true,"allow_lan":true,"selection_cache":true,"log_level":"warning","log_clear_at_stop":false,"ipv6":true,"unified_delay":true,"tcp_concurrent":true,"tun_enabled":false,"dns_enabled":true,"dns_cache_algorithm":"arc","dns_ipv6":true,"dns_mode":"redir-host","fake_ip_cache":false,"sniffer_enabled":true,"sniffer_force_dns_mapping":true,"sniffer_parse_pure_ip":true,"sniffer_override_destination":false,"tcp_mode":"tproxy","udp_mode":"tproxy","ipv4_dns_hijack":true,"ipv6_dns_hijack":true,"ipv4_proxy":true,"ipv6_proxy":true,"fake_ip_ping_hijack":false,"bypass_china_mainland_ip":true,"bypass_china_mainland_ip6":true},"openwrt":{"software_flow_offload":false,"hardware_flow_offload":false}}
EOF
policy_sha=$(sha256sum "$bundle/policy.json" | awk '{print $1}')
subscriptions_sha=$(sha256sum "$bundle/subscriptions.json" | awk '{print $1}')
mixin_sha=$(sha256sum "$bundle/nikki-mixin.yaml" | awk '{print $1}')
platform_sha=$(sha256sum "$bundle/platform.json" | awk '{print $1}')
rulesets_lock_sha=$(sha256sum "$bundle/rulesets.lock.json" | awk '{print $1}')
file_count=$(wc -l <"$bundle/FILES.sha256" | tr -d ' ')
printf '{"schema":"opl-netfleet-deploy-bundle.v5","source_commit":"%s","source_tree":"%s","policy_schema":2,"file_count":%s,"instance":true,"policy_sha256":"%s","subscriptions_sha256":"%s","nikki_mixin_sha256":"%s","platform_sha256":"%s","rulesets_lock_sha256":"%s","activation_qualified":true,"qualification_sha256":"%s"}\n' \
	"$source_commit" "$source_tree" "$file_count" "$policy_sha" "$subscriptions_sha" "$mixin_sha" "$platform_sha" "$rulesets_lock_sha" \
	"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" >"$bundle/bundle.json"
(
	cd "$bundle"
	: >SHA256SUMS
	for path in FILES.sha256 bundle.json deploy-openwrt-remote.sh rulesets.lock.json payload.tar policy.json subscriptions.json nikki-mixin.yaml platform.json; do
		printf '%s  %s\n' "$(sha256sum "$path" | awk '{print $1}')" "$path" >>SHA256SUMS
	done
)

set +e
PATH="$bin:$PATH" sh /tmp/deploy-openwrt-remote.sh --bundle "$bundle" --preserve-state --instance >"$work/result.json"
rc=$?
set -e
[ "$rc" -ne 0 ]
grep -q '"error":"enable_failed"' "$work/result.json"
grep -q '"rollback":"restored_previous_bytes_native_profile"' "$work/result.json"
[ "$(readlink /var)" = tmp ]
[ "$(cat /var/lib/opl-netfleet/events.json)" = old-events ]
[ "$(cat /usr/libexec/opl-netfleet/main.uc)" = old-main ]
"$real_ubus" call system board >/dev/null
test -S /var/run/ubus/ubus.sock
printf '{"ok":true,"rollback":true,"source_commit":"%s","source_tree":"%s","checks":{"deploy_failure_rollback":true,"post_failure_management":true,"var_symlink":true,"ubus":true}}\n' "$source_commit" "$source_tree"
