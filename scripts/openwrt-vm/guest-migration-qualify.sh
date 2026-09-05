#!/bin/sh
# Continue the synthetic Nikki lifecycle fixture with a real native cutover.
set -eu
umask 077
source_commit=${1:?}
source_tree=${2:?}
probe_port=${3:?}
work=/tmp/netfleet-migration-fixture
previous=/tmp/netfleet-runtime-fixture
main=/usr/libexec/opl-netfleet/main.uc
gateway=/usr/libexec/opl-netfleet/application/native_gateway.uc
lock=/var/lock/opl-netfleet-deploy.lock
policy=/etc/opl-netfleet/policy.json
bundle=/etc/opl-netfleet/policy-sources/base-v1.json
stage=precondition
helper_pids=
wan_created=false

test -f /tmp/netfleet-migration-vm-authorized
test -f "$previous/qualification.json"
test "$(jsonfilter -i "$previous/qualification.json" -e '@.source_commit')" = "$source_commit"
test "$(jsonfilter -i "$previous/qualification.json" -e '@.source_tree')" = "$source_tree"
test "$(jsonfilter -i "$previous/qualification.json" -e '@.ok')" = true
test ! -e /etc/opl-netfleet/backend.json
test ! -e /etc/config/netfleet
test ! -e /etc/opl-netfleet/native
mkdir -p "$work/config"

finish() {
	rc=$?
	trap - EXIT INT TERM
	set +e
	/etc/init.d/opl-netfleet stop >/dev/null 2>&1
	/etc/init.d/opl-netfleet disable >/dev/null 2>&1
	/etc/init.d/opl-netfleet-core stop >/dev/null 2>&1
	/etc/init.d/opl-netfleet-core disable >/dev/null 2>&1
	/etc/init.d/nikki stop >/dev/null 2>&1
	/etc/init.d/nikki disable >/dev/null 2>&1
	for pid in $helper_pids; do kill "$pid" >/dev/null 2>&1; done
	nft delete table ip netfleet_vm_migration_probe >/dev/null 2>&1
	if [ "$wan_created" = true ]; then
		ubus call network.interface.wan down >/dev/null 2>&1
		ip link del nf-migrate-wan >/dev/null 2>&1
	fi
	if [ "$rc" -eq 0 ] && { [ "$stage" != complete ] || [ ! -s "$work/qualification.json" ]; }; then rc=1; fi
	if [ "$rc" -ne 0 ]; then
		echo "Migration qualification failed at: $stage" >&2
		for file in "$work"/*-result.json "$work"/*.stderr "$work"/*.log; do
			[ ! -f "$file" ] || { echo "--- $file" >&2; tail -60 "$file" >&2; }
		done
		ubus call service list '{"name":"opl-netfleet-core"}' >&2
		logread | tail -60 >&2
	fi
	exit "$rc"
}
trap finish EXIT INT TERM

run_main() {
	# Do not pass the parent's lock descriptor into a daemon started by a child.
	(
		exec 9>"$lock"
		flock 9
		ucode "$main" "$@" 9>&-
	)
}
assert_json() { [ "$(jsonfilter -i "$1" -e "$2")" = "$3" ]; }
digest() { sha256sum "$1" | awk '{print $1}'; }
request() {
	ucode -e '
		import { readfile, writefile } from "fs";
		const preview = json(readfile(ARGV[0]));
		if (preview?.result?.ready != true || type(preview.result.revision) != "string") exit(1);
		const request = { request: { confirmed: true, backend: "native-mihomo", revision: preview.result.revision } };
		exit(writefile(ARGV[1], sprintf("%J", request)) ? 0 : 1);
	' "$1" "$2"
	chmod 0600 "$2"
}

stage=dependencies
# Exclude the preceding lifecycle test's ubus/nft shims from this test.
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
apk --timeout 120 update >"$work/packages.log" 2>&1 || true
apk --timeout 120 add curl flock ip-full kmod-veth kmod-nft-tproxy kmod-nft-socket \
	ucode-mod-fs ucode-mod-uci ucode-mod-ubus >>"$work/packages.log" 2>&1
for executable in mihomo yq; do
	if [ ! -e "/usr/bin/$executable" ]; then ln -s "$previous/bin/$executable" "/usr/bin/$executable"; fi
	test -x "/usr/bin/$executable"
done
cp -R /tmp/openwrt/files/usr/libexec/opl-netfleet /usr/libexec/
mkdir -p /usr/share/opl-netfleet
cp -R /tmp/openwrt/files/usr/share/opl-netfleet/nikki /usr/share/opl-netfleet/
cp /tmp/openwrt/files/etc/init.d/opl-netfleet-core /etc/init.d/opl-netfleet-core
cp /tmp/openwrt/files/etc/init.d/opl-netfleet /etc/init.d/opl-netfleet
chmod 0755 "$main" /etc/init.d/opl-netfleet /etc/init.d/opl-netfleet-core
/etc/init.d/opl-netfleet stop
/etc/init.d/opl-netfleet disable
/etc/init.d/opl-netfleet-core disable

stage=real_network_prerequisites
wan_up=$(ubus call network.interface.wan status 2>/dev/null | jsonfilter -e '@.up' 2>/dev/null || true)
if [ "$wan_up" != true ]; then
	ip link add nf-migrate-wan type veth peer name nf-migrate-peer
	ip link set nf-migrate-wan up
	ip link set nf-migrate-peer up
	wan_created=true
	ubus call network add_dynamic '{"name":"wan","proto":"static","device":"nf-migrate-wan","ipaddr":["198.18.2.1/30"]}' >"$work/wan-result.json"
fi
for attempt in 1 2 3 4 5; do
	[ "$(ubus call network.interface.wan status | jsonfilter -e '@.up')" != true ] || break
	sleep 1
done
[ "$(ubus call network.interface.wan status | jsonfilter -e '@.up')" = true ]
ip route show default | grep -q '^default '
nft -f - <<EOF
table ip netfleet_vm_migration_probe {
	chain output {
		type nat hook output priority -101; policy accept;
		ip daddr 192.168.1.2 tcp dport 443 dnat to 192.168.1.2:$probe_port
	}
}
EOF
dnsmasq --keep-in-foreground --port=1054 --listen-address=127.0.0.1 --bind-interfaces \
	--no-resolv --no-hosts --address=/netfleet-probe.test/192.168.1.2 \
	--address=/www.gstatic.com/192.168.1.2 --pid-file="$work/dns.pid" >"$work/dns.log" 2>&1 &
helper_pids="$helper_pids $!"
for helper in primary reserve; do
	"$previous/bin/netfleet-test-$helper" -d "$previous/helper-$helper" -f "$previous/helper-$helper.json" \
		>"$work/helper-$helper.log" 2>&1 &
	helper_pids="$helper_pids $!"
done
probe_url=https://netfleet-probe.test:$probe_port/generate_204
for attempt in $(seq 1 15); do
	if curl -fsS --socks5-hostname 127.0.0.1:1081 --max-time 4 "$probe_url" >/dev/null &&
		curl -fsS --socks5-hostname 127.0.0.1:1082 --max-time 4 "$probe_url" >/dev/null; then break; fi
	[ "$attempt" -lt 15 ] || exit 1
	sleep 1
done

stage=nikki_fixture_configuration
cp /tmp/openwrt/files/etc/config/netfleet "$work/config/netfleet"
ucode -e '
	import { cursor } from "uci";
	const defaults = cursor(ARGV[0]);
	const target = cursor();
	const remove = [];
	target.foreach("nikki", null, (s) => { if (s[".type"] != "subscription") push(remove, s[".name"]); });
	for (let name in remove) target.delete("nikki", name);
	defaults.foreach("netfleet", null, (s) => {
		if (!target.set("nikki", s[".name"], s[".type"])) exit(1);
		for (let key, value in s) if (substr(key, 0, 1) != "." && !target.set("nikki", s[".name"], key, value)) exit(1);
	});
	target.set("nikki", "config", "profile", "subscription:base");
	target.set("nikki", "config", "enabled", "1");
	target.set("nikki", "mixin", "api_secret", "netfleet-vm-fixture");
	target.set("nikki", "mixin", "mixin_file_content", "1");
	target.set("nikki", "mixin", "ipv6", "0");
	target.set("nikki", "proxy", "ipv6_proxy", "0");
	target.set("nikki", "proxy", "ipv6_dns_hijack", "0");
	target.set("nikki", "routing", "cgroup_name", "nikki");
	target.set("nikki", "routing", "dummy_device", "nikki-dummy");
	exit(target.commit("nikki") ? 0 : 1);
' "$work/config"
mkdir -p /etc/nikki/run/ui
printf '<!doctype html><title>Migration resource fixture</title>\n' >/etc/nikki/run/ui/index.html
cat >/etc/nikki/mixin.yaml <<'EOF'
{"hosts":{"netfleet-probe.test":"192.168.1.2","www.gstatic.com":"192.168.1.2"},"dns":{"nameserver":["udp://127.0.0.1:1054"]}}
EOF
ucode -e '
	import { read_yaml } from "/usr/libexec/opl-netfleet/adapters/uci.uc";
	import { writefile } from "fs";
	const source = read_yaml(ARGV[0], true);
	source.hosts = { "netfleet-probe.test": "192.168.1.2", "www.gstatic.com": "192.168.1.2" };
	source.dns = { enable: true, listen: "[::]:1053", nameserver: ["udp://127.0.0.1:1054"] };
	exit(writefile(ARGV[0], sprintf("%J", source)) ? 0 : 1);
' /etc/nikki/subscriptions/base.yaml
# The old fixture implements process lifecycle only. Add actual persistent
# service enablement so migration can exercise disabling and restoring it.
sed 's/nikki\.proxy\.api_secret/nikki.mixin.api_secret/g' /etc/init.d/nikki >"$work/nikki-lifecycle"
chmod 0755 "$work/nikki-lifecycle"
cat >/etc/init.d/nikki <<'EOF'
#!/bin/sh
case "$1" in
	enable) ln -sf /etc/init.d/nikki /etc/rc.d/S99nikki-migration-fixture ;;
	disable) rm -f /etc/rc.d/S99nikki-migration-fixture ;;
	enabled) test -L /etc/rc.d/S99nikki-migration-fixture ;;
	*) exec /tmp/netfleet-migration-fixture/nikki-lifecycle "$@" ;;
esac
EOF
chmod 0755 /etc/init.d/nikki
/etc/init.d/nikki enable
/etc/init.d/nikki restart
run_main status >"$work/source-status-result.json"
assert_json "$work/source-status-result.json" '@.result.runtime.mihomo_running' true
assert_json "$work/source-status-result.json" '@.result.runtime.controller_available' true
run_main probe >"$work/source-probe-result.json"
assert_json "$work/source-probe-result.json" '@.ok' true

stage=controlled_compile_failure
cp -p "$bundle" "$work/bundle.accepted.json"
ucode -e '
	import { readfile, writefile } from "fs";
	const bundle = json(readfile(ARGV[0]));
	const manifest = json(readfile(ARGV[1]));
	const name = manifest?.generated_groups?.standard?.direct_guard_name;
	if (type(name) != "string") exit(1);
	push(bundle["proxy-groups"], { name: name, type: "select", proxies: ["DIRECT"] });
	exit(writefile(ARGV[0], sprintf("%J", bundle)) ? 0 : 1);
' "$bundle" /etc/nikki/profiles/opl-netfleet/mvp.manifest.json
for path in "$policy" /etc/config/nikki /etc/nikki/mixin.yaml /etc/nikki/subscriptions/*.yaml; do
	sha256sum "$path"
done >"$work/rollback-inputs.sha256"
run_main migration-get >"$work/failure-preview-result.json"
assert_json "$work/failure-preview-result.json" '@.result.ready' true
request "$work/failure-preview-result.json" "$work/failure-request.json"
if run_main migration-apply "$work/failure-request.json" >"$work/rollback-result.json" 2>"$work/rollback.stderr"; then exit 1; fi
assert_json "$work/rollback-result.json" '@.error' native_compile_failed
assert_json "$work/rollback-result.json" '@.result.rollback.ok' true
sha256sum -c "$work/rollback-inputs.sha256" >"$work/rollback-byte-readback.log"
test ! -e /etc/opl-netfleet/backend.json
test ! -e /etc/config/netfleet
test ! -e /etc/opl-netfleet/native
/etc/init.d/nikki running
/etc/init.d/nikki enabled
run_main probe >"$work/rollback-probe-result.json"
assert_json "$work/rollback-probe-result.json" '@.ok' true
ucode "$gateway" status >"$work/rollback-gateway-result.json"
assert_json "$work/rollback-gateway-result.json" '@.result.core_running' false
assert_json "$work/rollback-gateway-result.json" '@.result.clean' true
cp -p "$work/bundle.accepted.json" "$bundle"

stage=migrate_to_native
policy_digest=$(digest "$policy")
run_main migration-get >"$work/preview-result.json"
assert_json "$work/preview-result.json" '@.result.ready' true
assert_json "$work/preview-result.json" '@.result.capabilities.private_mixin' true
assert_json "$work/preview-result.json" '@.result.capabilities.dashboard' true
request "$work/preview-result.json" "$work/request.json"
started=$(date +%s%3N)
run_main migration-apply "$work/request.json" >"$work/migration-result.json" 2>"$work/migration.stderr"
elapsed=$(( $(date +%s%3N) - started ))
assert_json "$work/migration-result.json" '@.ok' true
assert_json "$work/migration-result.json" '@.result.state' active
assert_json "$work/migration-result.json" '@.result.backend' native-mihomo
test "$(digest "$policy")" = "$policy_digest"
test "$(uci -q get nikki.config.enabled)" = 0
test "$(uci -q get netfleet.config.profile)" = file:OPL-NetFleet.json
! /etc/init.d/nikki running
! /etc/init.d/nikki enabled
/etc/init.d/opl-netfleet-core enabled
/etc/init.d/opl-netfleet enabled
run_main status >"$work/native-status-result.json"
assert_json "$work/native-status-result.json" '@.result.active' true
assert_json "$work/native-status-result.json" '@.result.runtime.backend.id' native-mihomo
assert_json "$work/native-status-result.json" '@.result.runtime.netfleet_present' true
ucode "$gateway" status >"$work/native-gateway-result.json"
assert_json "$work/native-gateway-result.json" '@.result.ready' true
run_main select standard auto vm >"$work/native-select-result.json"
assert_json "$work/native-select-result.json" '@.ok' true
run_main probe >"$work/native-probe-result.json"
assert_json "$work/native-probe-result.json" '@.ok' true
test "$(digest /etc/nikki/run/ui/index.html)" = "$(digest /etc/opl-netfleet/native/run/ui/index.html)"
ucode -e '
	import { read_yaml, read_json } from "/usr/libexec/opl-netfleet/adapters/uci.uc";
	for (let section in ["base", "alpha", "beta"]) {
		const source = read_yaml(`/etc/nikki/subscriptions/${section}.yaml`, true);
		const imported = read_json(`/etc/opl-netfleet/native/subscriptions/${section}.yaml`);
		if (sprintf("%J", source) != sprintf("%J", imported)) exit(1);
	}
	const mixed = read_json("/etc/opl-netfleet/native/mixin.json");
	if (mixed?.dns?.nameserver?.[0] != "udp://127.0.0.1:1054") exit(1);
'

stage=complete
printf '{"ok":true,"source_commit":"%s","source_tree":"%s","checks":{"source_controller_and_business":true,"migration_preview":true,"compile_failure_rollback":true,"rollback_private_bytes":true,"rollback_nikki_owner":true,"native_migration":true,"shared_policy_unchanged":true,"subscriptions_imported":true,"private_mixin_imported":true,"dashboard_resource_imported":true,"native_gateway_readback":true,"shared_select":true,"shared_probe":true,"service_ownership_transfer":true},"metrics":{"migration_ms":%s},"runtime":{"nikki_fixture":"synthetic_lifecycle_only","native_gateway":"shipped_owner"}}\n' \
	"$source_commit" "$source_tree" "$elapsed" >"$work/qualification.json"
assert_json "$work/qualification.json" '@.ok' true
cat "$work/qualification.json"
