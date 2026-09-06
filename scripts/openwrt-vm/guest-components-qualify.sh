#!/bin/sh
set -eu
umask 077
feed_url=${1:?}
work=/tmp/netfleet-components-fixture
owner=/usr/libexec/opl-netfleet/application/components.uc
main=/usr/libexec/opl-netfleet/main.uc
stage=precondition
test -f /tmp/netfleet-setup-vm-authorized
test -f "$owner"
mkdir -p "$work"
cp /etc/apk/repositories.d/opl-netfleet.list "$work/original-feed"
finish() {
	rc=$?
	trap - EXIT INT TERM
	cp "$work/original-feed" /etc/apk/repositories.d/opl-netfleet.list
	rm -f /etc/apk/repositories.d/netfleet-component-fixture.list
	if [ "$rc" -ne 0 ]; then
		echo "Component qualification failed at: $stage" >&2
		for file in "$work"/*-result.json /tmp/opl-netfleet-components/*/log; do
			[ ! -f "$file" ] || { echo "--- $file" >&2; tail -50 "$file" >&2; }
		done
	fi
	exit "$rc"
}
trap finish EXIT INT TERM
assert_json() { [ "$(jsonfilter -i "$1" -e "$2")" = "$3" ]; }
install_fixture() {
	(
		exec 9>/var/lock/opl-netfleet-deploy.lock
		flock 9
		apk --no-network add "$@" 9>&-
	)
}
snapshot() {
	sha256sum /etc/config/netfleet /etc/opl-netfleet/policy.json /etc/opl-netfleet/backend.json \
		/etc/opl-netfleet/native/subscriptions/setup.yaml /usr/libexec/mihomo >"$1.inputs"
	if [ -f /etc/opl-netfleet/native/mixin.json ]; then sha256sum /etc/opl-netfleet/native/mixin.json >>"$1.inputs"; fi
	ucode -e 'import { api_secret } from "/usr/libexec/opl-netfleet/adapters/uci.uc";
		import { proxies } from "/usr/libexec/opl-netfleet/adapters/mihomo.uc";
		const values = proxies(api_secret(), 2)?.proxies; if (values == null) exit(1);
		const selected = {}; for (let name in sort(keys(values))) if (values[name].type == "Selector") selected[name] = values[name].now;
		printf("%J\n", selected);' >"$1.routes"
}
unchanged() {
	snapshot "$work/after"
	cmp "$work/before.inputs" "$work/after.inputs"
	cmp "$work/before.routes" "$work/after.routes"
	ucode "$main" probe >"$work/probe-result.json"
	assert_json "$work/probe-result.json" '@.ok' true
	assert_json "$work/probe-result.json" '@.result.ok' true
	[ ! -e /tmp/opl-netfleet-package-upgrade-state ]
}
wait_operation() {
	wanted=$1
	for attempt in $(seq 1 180); do
		if ! ucode "$owner" operation >"$work/operation-result.json"; then sleep 1; continue; fi
		id=$(jsonfilter -i "$work/operation-result.json" -e '@.result.packages.id')
		state=$(jsonfilter -i "$work/operation-result.json" -e '@.result.packages.state')
		if [ "$id" = "$wanted" ]; then
			case "$state" in succeeded|failed|interrupted) return 0 ;; esac
		fi
		sleep 1
	done
	echo 'Component worker did not finish' >&2
	return 1
}
request() {
	method=$1
	version=${2:-}
	component=${3:-netfleet}
	if [ "$method" = components_check ]; then
		ubus -t 20 call opl-netfleet "$method" '{}' >"$work/start-result.json"
	else
		ubus -t 20 call opl-netfleet "$method" "{\"component\":\"$component\",\"version\":\"$version\"}" >"$work/start-result.json"
	fi
	assert_json "$work/start-result.json" '@.ok' true
	id=$(jsonfilter -i "$work/start-result.json" -e '@.result.operation.id')
	[ -n "$id" ]
	wait_operation "$id"
}
rpc_ready() {
	for attempt in $(seq 1 20); do
		if ubus -t 5 call opl-netfleet components_get '{}' >"$work/rpc-result.json" 2>/dev/null &&
			[ "$(jsonfilter -i "$work/rpc-result.json" -e '@.ok')" = true ]; then return 0; fi
		sleep 1
	done
	return 1
}
stage=actual_component_readback
rpc_ready
ucode /tmp/tests/components_device.uc "$owner" >"$work/contract.log"
ucode "$owner" get >"$work/get-result.json"
assert_json "$work/get-result.json" '@.result.supported' true
assert_json "$work/get-result.json" '@.result.backend' native-mihomo
ucode -e 'import { readfile, popen } from "fs";
	const data = json(readfile(ARGV[0])).result;
	const pipe = popen("apk --no-network query --from installed --format json --fields name,version opl-netfleet luci-app-netfleet mihomo-meta");
	const rows = json(pipe.read("all")); if (pipe.close() != 0) exit(1);
	const installed = {}; for (let row in rows) installed[row.name] = row.version;
	for (let entry in [["netfleet","opl-netfleet"],["luci","luci-app-netfleet"],["mihomo","mihomo-meta"]]) {
		const found = filter(data.components, row => row.id == entry[0])[0];
		if (found?.installed_version != installed[entry[1]] || !found.managed) exit(1);
	}
	if (filter(data.components, row => row.id == "mihomo")[0].running_version == null) exit(1);' "$work/get-result.json"
snapshot "$work/before"
stage=asynchronous_feed_check
request components_check
assert_json "$work/operation-result.json" '@.result.packages.state' succeeded
unchanged
stage=wrong_candidate_rejected
request components_update 9999.0.0-r1
assert_json "$work/operation-result.json" '@.result.packages.state' failed
assert_json "$work/operation-result.json" '@.result.packages.error' candidate_changed
unchanged

stage=fixture_feed
uclient-fetch -q -O "$work/fixture.json" "$feed_url/components-fixtures/fixture.json"
uclient-fetch -q -O /etc/apk/keys/netfleet-component-fixture.pem "$feed_url/components-fixtures/component-fixture.pem"
printf '%s\n' "$feed_url/components-fixtures/old/packages.adb" "$feed_url/components-fixtures/good/packages.adb" > /etc/apk/repositories.d/netfleet-component-fixture.list
apk --timeout 30 --repositories-file /etc/apk/repositories.d/netfleet-component-fixture.list update >"$work/rollback-feed.log" 2>&1
current=$(jsonfilter -i "$work/fixture.json" -e '@.version')
old=$(jsonfilter -i "$work/fixture.json" -e '@.old_version')
bad=$(jsonfilter -i "$work/fixture.json" -e '@.bad_version')
core_current=$(jsonfilter -i "$work/fixture.json" -e '@.core_version')
core_old=$(jsonfilter -i "$work/fixture.json" -e '@.core_old_version')
core_bad=$(jsonfilter -i "$work/fixture.json" -e '@.core_bad_version')
printf '%s\n' "$feed_url/components-fixtures/good/packages.adb" >/etc/apk/repositories.d/opl-netfleet.list
for name in opl-netfleet luci-app-netfleet; do
	uclient-fetch -q -O "$work/$name-$old.apk" "$feed_url/components-fixtures/good/$name-$old.apk"
done
stage=older_real_apk
install_fixture "$work/opl-netfleet-$old.apk" "$work/luci-app-netfleet-$old.apk" >"$work/downgrade.log" 2>&1
unchanged
rpc_ready
stage=component_update
rpcd_before=$(pidof rpcd)
request components_update "$current"
assert_json "$work/operation-result.json" '@.result.packages.state' succeeded
apk list --manifest | grep -Fqx "opl-netfleet $current"
apk list --manifest | grep -Fqx "luci-app-netfleet $current"
rpc_ready
[ "$(pidof rpcd)" != "$rpcd_before" ]
unchanged
stage=component_failed_candidate_rollback
printf '%s\n' "$feed_url/components-fixtures/bad/packages.adb" >/etc/apk/repositories.d/opl-netfleet.list
request components_update "$bad"
assert_json "$work/operation-result.json" '@.result.packages.state' failed
assert_json "$work/operation-result.json" '@.result.packages.error' runtime_verification_failed_rolled_back
apk list --manifest | grep -Fqx "opl-netfleet $current"
apk list --manifest | grep -Fqx "luci-app-netfleet $current"
rpc_ready
unchanged
stage=core_update
printf '%s\n' "$feed_url/components-fixtures/good/packages.adb" >/etc/apk/repositories.d/opl-netfleet.list
uclient-fetch -q -O "$work/mihomo-meta-$core_old.apk" "$feed_url/components-fixtures/good/mihomo-meta-$core_old.apk"
install_fixture "$work/mihomo-meta-$core_old.apk" >"$work/core-downgrade.log" 2>&1
unchanged
request components_update "$core_current" mihomo
assert_json "$work/operation-result.json" '@.result.packages.state' succeeded
apk list --manifest | grep -Fqx "mihomo-meta $core_current"
unchanged
stage=incompatible_core_rejected_before_stop
printf '%s\n' "$feed_url/components-fixtures/bad-core/packages.adb" >/etc/apk/repositories.d/opl-netfleet.list
core_pid_before=$(ubus call service list '{"name":"opl-netfleet-core"}' | jsonfilter -e '@["opl-netfleet-core"].instances.core.pid')
request components_update "$core_bad" mihomo
assert_json "$work/operation-result.json" '@.result.packages.state' failed
assert_json "$work/operation-result.json" '@.result.packages.error' core_config_incompatible
apk list --manifest | grep -Fqx "mihomo-meta $core_current"
[ "$(ubus call service list '{"name":"opl-netfleet-core"}' | jsonfilter -e '@["opl-netfleet-core"].instances.core.pid')" = "$core_pid_before" ]
unchanged
stage=complete
printf '%s\n' '{"ok":true,"checks":{"component_versions":true,"component_check_worker":true,"component_rejects_wrong_candidate":true,"component_real_apk_upgrade":true,"component_rpcd_restart_continuity":true,"component_failed_upgrade_rollback":true,"component_private_inputs_unchanged":true,"component_routes_restored":true,"component_mihomo_upgrade":true,"component_incompatible_core_rejected":true}}' >"$work/qualification.json"
