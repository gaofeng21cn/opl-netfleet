#!/bin/sh
set -eu
umask 077
feed_url=${1:?}
work=/tmp/netfleet-components-fixture
owner=/usr/libexec/opl-netfleet/main.uc
main=/usr/libexec/opl-netfleet/main.uc
stage=precondition
test -f /tmp/netfleet-setup-vm-authorized
test -f "$owner"
mkdir -p "$work"
cp /etc/apk/repositories.d/opl-netfleet.list "$work/original-feed"
cp /etc/apk/world "$work/original-world"
finish() {
	rc=$?
	trap - EXIT INT TERM
	cp "$work/original-feed" /etc/apk/repositories.d/opl-netfleet.list
	if [ -f "$work/distfeeds.list" ]; then
		mv "$work/distfeeds.list" /etc/apk/repositories.d/distfeeds.list
	fi
	rm -f /etc/apk/repositories.d/netfleet-component-fixture.list
	rm -f /root/netfleet-component-space-fixture
	if [ "$rc" -ne 0 ]; then
		echo "Component qualification failed at: $stage" >&2
		ubus call service list '{"name":"opl-netfleet-update-recovery"}' >&2
		for file in "$work"/*-result.json "$work"/*.log /tmp/opl-netfleet-operation-packages.json /etc/opl-netfleet/package-transactions/*/log; do
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
	ucode -e 'import { create } from "/usr/libexec/opl-netfleet/kernel/host.uc";
		import { create as create_adapter } from "/usr/libexec/opl-netfleet/adapters/openwrt.uc";
		const host = create("/usr/libexec/opl-netfleet", { adapter: create_adapter() });
		const api_secret = host.use("platform.credentials").api_secret;
		const proxies = host.use("mihomo.controller").proxies;
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
	[ -e /tmp/netfleet-setup-fixture/client-ready ]
	ip netns exec nf-setup-client nslookup -type=A www.gstatic.com 192.168.1.1 >>"$work/client.log" 2>&1
	for address in 198.18.1.2 '[fd77:a::2]'; do
		ip netns exec nf-setup-client curl -fsS --noproxy '*' --max-time 10 \
			--cacert /tmp/local-probe.crt --resolve "netfleet-probe.test:19443:$address" \
			https://netfleet-probe.test:19443/generate_204
	done
}
wait_operation() {
	wanted=$1
	for attempt in $(seq 1 180); do
		if ! ucode "$owner" components-operation >"$work/operation-result.json"; then sleep 1; continue; fi
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
ucode /tmp/tests/extensions_device.uc >>"$work/contract.log"
ucode "$owner" components-get >"$work/get-result.json"
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
bad=$(jsonfilter -i "$work/fixture.json" -e '@.bad_version')
package_version() {
	ucode -e 'import { readfile } from "fs";
		print(json(readfile(ARGV[0])).package_versions[ARGV[1]][ARGV[2]]);' \
		"$work/fixture.json" "$1" "$2"
}
core_current=$(jsonfilter -i "$work/fixture.json" -e '@.core_version')
core_old=$(jsonfilter -i "$work/fixture.json" -e '@.core_old_version')
core_bad=$(jsonfilter -i "$work/fixture.json" -e '@.core_bad_version')
printf '%s\n' "$feed_url/components-fixtures/good/packages.adb" >/etc/apk/repositories.d/opl-netfleet.list
product_packages=$(jsonfilter -i "$work/fixture.json" -e '@.product_packages[*]')
dependency_packages=
for name in $product_packages; do
	if ! grep -Eq "^$name([@<>=~]|$)" "$work/original-world"; then
		dependency_packages="$dependency_packages $name"
	fi
done
restore_fixture_world() {
	apk --no-network add $product_packages >>"$work/unpin.log" 2>&1
	[ -z "$dependency_packages" ] || apk --no-network del $dependency_packages >>"$work/unpin.log" 2>&1
}
old_packages=
for name in $product_packages; do
	old=$(package_version "$name" old)
	uclient-fetch -q -O "$work/$name-$old.apk" "$feed_url/components-fixtures/good/$name-$old.apk"
	old_packages="$old_packages $work/$name-$old.apk"
done
stage=older_real_apk
install_fixture $old_packages >"$work/downgrade.log" 2>&1
unchanged
rpc_ready
stage=installer_product_upgrade
# Local APK files pin their checksum; a normal feed installation has no pin.
restore_fixture_world
for name in $product_packages; do
	apk list --manifest | grep -Fqx "$name $(package_version "$name" old)"
done
uclient-fetch -q -O "$work/install-netfleet.sh" "$feed_url/install-netfleet.sh"
# The isolated proxy only serves local fixtures; system dependencies are installed.
mv /etc/apk/repositories.d/distfeeds.list "$work/distfeeds.list"
NETFLEET_FEED_BASE="$feed_url" NETFLEET_ALLOW_INSECURE_FEED=1 \
	sh "$work/install-netfleet.sh" >"$work/installer-upgrade.log" 2>&1
mv "$work/distfeeds.list" /etc/apk/repositories.d/distfeeds.list
for name in $product_packages; do
	apk list --manifest | grep -Fqx "$name $(package_version "$name" current)"
done
unchanged
install_fixture $old_packages >>"$work/downgrade.log" 2>&1
restore_fixture_world
stage=independent_plugin_update
printf '%s\n' "$feed_url/components-fixtures/good/packages.adb" >/etc/apk/repositories.d/opl-netfleet.list
printf '%s\n' "$feed_url/components-fixtures/independent/packages.adb" >>/etc/apk/repositories.d/netfleet-component-fixture.list
apk --timeout 30 --repositories-file /etc/apk/repositories.d/netfleet-component-fixture.list update >>"$work/rollback-feed.log" 2>&1
independent=$(jsonfilter -i "$work/fixture.json" -e '@.package_versions["opl-netfleet-plugin-dashboard"].independent')
uclient-fetch -q -O "$work/independent.apk" \
	"$feed_url/components-fixtures/independent/opl-netfleet-plugin-dashboard-$independent.apk"
# Update a non-resource plugin through the real finite transaction. Keep an old
# local checksum root to prove it is not copied onto the new APK database.
plugin=opl-netfleet-plugin-dashboard
prior=$(package_version "$plugin" old)
install_fixture "$work/$plugin-$prior.apk" >"$work/independent.log" 2>&1
local_stage="$work/local-install"
mkdir -p "$local_stage/old" "$local_stage/new"
cp "$work/$plugin-$prior.apk" "$local_stage/old/"
cp "$work/independent.apk" "$local_stage/new/$plugin-$independent.apk"
chmod 700 "$local_stage" "$local_stage/old" "$local_stage/new"
chmod 600 "$local_stage"/old/* "$local_stage"/new/*
old_sha=$(sha256sum "$local_stage/old/$plugin-$prior.apk" | cut -d' ' -f1)
new_sha=$(sha256sum "$local_stage/new/$plugin-$independent.apk" | cut -d' ' -f1)
printf '{"schema":"opl-netfleet-plugin-install.v1","packages":[{"name":"%s","before_version":"%s","version":"%s","before_sha256":"%s","sha256":"%s"}]}\n' \
 "$plugin" "$prior" "$independent" "$old_sha" "$new_sha" >"$local_stage/request.json"
core_pid_before=$(pidof mihomo)
cp "$local_stage/old/$plugin-$prior.apk" "$local_stage/old/unexpected.apk"
if ucode "$owner" components-install "$local_stage" >"$work/local-rejected.json"; then exit 1; fi
assert_json "$work/local-rejected.json" '@.error' unexpected_plugin_archive
[ "$(pidof mihomo)" = "$core_pid_before" ]
rm "$local_stage/old/unexpected.apk"
ucode "$owner" components-install "$local_stage" >"$work/local-start.json"
assert_json "$work/local-start.json" '@.ok' true
id=$(jsonfilter -i "$work/local-start.json" -e '@.result.operation.id')
wait_operation "$id"
assert_json "$work/operation-result.json" '@.result.packages.state' succeeded
[ "$(pidof mihomo)" = "$core_pid_before" ]
grep -Fxq "$plugin" /etc/apk/world
# Retry with stale installed-version evidence must fail before hooks.
if ucode "$owner" components-install "$local_stage" >"$work/local-rejected.json"; then exit 1; fi
assert_json "$work/local-rejected.json" '@.error' installed_version_changed
unchanged
rpc_ready
cp /etc/apk/world "$work/update-world"
stage=component_update
rpcd_before=$(pidof rpcd)
request components_update "$current"
assert_json "$work/operation-result.json" '@.result.packages.state' succeeded
cmp /etc/apk/world "$work/update-world"
for name in $product_packages; do
	expected=$(package_version "$name" current)
	[ "$name" != opl-netfleet-plugin-dashboard ] || expected=$independent
	apk list --manifest | grep -Fqx "$name $expected"
done
rpc_ready
[ "$(pidof rpcd)" != "$rpcd_before" ]
unchanged
stage=durable_terminal_reconcile
terminal_core_pid=$(pidof mihomo)
transaction=/etc/opl-netfleet/package-transactions
saved_id=$(jsonfilter -i "$transaction/request.json" -e '@.id')
test "$(jsonfilter -i "$transaction/$saved_id/journal.json" -e '@.phase')" = complete
# Model a process loss after terminal persistence, before pending removal.
printf '{"id":"%s"}\n' "$saved_id" >"$transaction/pending.json"
rm -f /tmp/opl-netfleet-operation-packages.json
ubus -t 20 call opl-netfleet components_recover '{}' >"$work/recover-start.json"
assert_json "$work/recover-start.json" '@.ok' true
for attempt in $(seq 1 90); do
	[ -e "$transaction/pending.json" ] || break
	sleep 1
done
test ! -e "$transaction/pending.json"
[ "$(pidof mihomo)" = "$terminal_core_pid" ]
unchanged
# A lost volatile progress record must not prevent the next operation.
request components_check
assert_json "$work/operation-result.json" '@.result.packages.state' succeeded
unchanged
stage=component_failed_candidate_rollback
printf '%s\n' "$feed_url/components-fixtures/bad/packages.adb" >/etc/apk/repositories.d/opl-netfleet.list
request components_update "$bad"
assert_json "$work/operation-result.json" '@.result.packages.state' failed
assert_json "$work/operation-result.json" '@.result.packages.error' runtime_verification_failed_rolled_back
assert_json "$work/operation-result.json" '@.result.packages.recovery' restored
cmp /etc/apk/world "$work/update-world"
for name in $product_packages; do
	expected=$(package_version "$name" current)
	[ "$name" != opl-netfleet-plugin-dashboard ] || expected=$independent
	apk list --manifest | grep -Fqx "$name $expected"
done
rpc_ready
unchanged
stage=component_failed_package_hook_rollback
printf '%s\n' "$feed_url/components-fixtures/bad-hook/packages.adb" >/etc/apk/repositories.d/opl-netfleet.list
request components_update "$current"
assert_json "$work/operation-result.json" '@.result.packages.state' failed
assert_json "$work/operation-result.json" '@.result.packages.error' package_install_failed_rolled_back
assert_json "$work/operation-result.json" '@.result.packages.recovery' restored
cmp /etc/apk/world "$work/update-world"
for name in $product_packages; do
	expected=$(package_version "$name" current)
	[ "$name" != opl-netfleet-plugin-dashboard ] || expected=$independent
	apk list --manifest | grep -Fqx "$name $expected"
done
apk --no-network --simulate add opl-netfleet luci-app-netfleet >>"$work/post-hook-reconcile.log" 2>&1
rpc_ready
unchanged
stage=interrupted_package_install_recovery
printf '%s\n' "$feed_url/components-fixtures/interrupted/packages.adb" >/etc/apk/repositories.d/opl-netfleet.list
ubus -t 20 call opl-netfleet components_update "{\"component\":\"netfleet\",\"version\":\"$current\"}" >"$work/interrupted-start.json"
assert_json "$work/interrupted-start.json" '@.ok' true
for attempt in $(seq 1 120); do
	[ ! -f /tmp/netfleet-update-paused ] || break
	sleep 1
done
test -f /tmp/netfleet-update-paused
worker=$(ubus call service list '{"name":"opl-netfleet-update"}' | jsonfilter -e '@["opl-netfleet-update"].instances.update.pid')
ucode - "$worker" <<'UCKILL'
import * as fs from 'fs';
const root = int(ARGV[0]);
if (root <= 1) exit(1);
system(`kill -STOP ${root}`);
const parents = {};
for (let name in fs.lsdir('/proc')) {
	if (!match(name, /^[0-9]+$/)) continue;
	const text = fs.readfile(`/proc/${name}/stat`);
	if (text != null) parents[name] = int(split(replace(text, /^.*\) /, ''), ' ')[1]);
}
const family = [root];
for (let i = 0; i < length(family); i++)
	for (let child, parent in parents)
		if (parent == family[i] && index(family, int(child)) < 0) push(family, int(child));
for (let pid in reverse(family)) system(`kill -KILL ${pid} 2>/dev/null`);
UCKILL
# Lose volatile progress and make installed entry unreadable, as a partial replacement can.
rm -f /tmp/opl-netfleet-operation-packages.json
printf 'incomplete package bytes\n' >/usr/libexec/opl-netfleet/main.uc
/etc/init.d/opl-netfleet-update-recovery start
for attempt in $(seq 1 120); do
	[ -e /etc/opl-netfleet/package-transactions/pending.json ] || break
	sleep 1
done
test ! -e /etc/opl-netfleet/package-transactions/pending.json
rpc_ready
unchanged
ucode "$owner" components-operation >"$work/recovered-result.json"
assert_json "$work/recovered-result.json" '@.result.packages.recovery' restored
assert_json "$work/recovered-result.json" '@.result.packages.state' failed
cmp /etc/apk/world "$work/update-world"
for name in $product_packages; do
	expected=$(package_version "$name" current)
	[ "$name" != opl-netfleet-plugin-dashboard ] || expected=$independent
	apk list --manifest | grep -Fqx "$name $expected"
done
stage=core_update
printf '%s\n' "$feed_url/components-fixtures/good/packages.adb" >/etc/apk/repositories.d/opl-netfleet.list
uclient-fetch -q -O "$work/mihomo-meta-$core_old.apk" "$feed_url/components-fixtures/good/mihomo-meta-$core_old.apk"
install_fixture "$work/mihomo-meta-$core_old.apk" >"$work/core-downgrade.log" 2>&1
unchanged
stage=insufficient_core_space_rejected_before_stop
core_pid_before=$(ubus call service list '{"name":"opl-netfleet-core"}' | jsonfilter -e '@["opl-netfleet-core"].instances.core.pid')
free_kb=$(df -Pk /usr/libexec | awk 'NR == 2 { print $4 }')
fill_mb=$((free_kb / 1024 - 16))
[ "$fill_mb" -gt 0 ]
dd if=/dev/zero of=/root/netfleet-component-space-fixture bs=1M count="$fill_mb" >"$work/space-fixture.log" 2>&1
request components_update "$core_current" mihomo
assert_json "$work/operation-result.json" '@.result.packages.state' failed
assert_json "$work/operation-result.json" '@.result.packages.error' insufficient_update_space
[ "$(ubus call service list '{"name":"opl-netfleet-core"}' | jsonfilter -e '@["opl-netfleet-core"].instances.core.pid')" = "$core_pid_before" ]
rm /root/netfleet-component-space-fixture
unchanged
stage=core_update
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
# Remove the explicit root introduced by the independent-plugin test; the product still needs it.
apk --no-network --repositories-file /dev/null del opl-netfleet-plugin-dashboard >"$work/independent-root-remove.log" 2>&1
printf '%s\n' '{"ok":true,"checks":{"component_finite_plugin_update":true,"component_finite_rejects_extra_archive":true,"component_finite_rejects_stale_version":true,"component_finite_keeps_core_pid":true,"component_versions":true,"component_check_worker":true,"component_rejects_wrong_candidate":true,"installer_complete_product_upgrade":true,"component_preserves_newer_independent_plugin":true,"component_world_preserved":true,"component_real_apk_upgrade":true,"component_rpcd_restart_continuity":true,"component_failed_upgrade_rollback":true,"component_durable_terminal_reconcile":true,"component_interrupted_install_recovery":true,"component_failed_package_hook_rollback":true,"component_private_inputs_unchanged":true,"component_routes_restored":true,"component_insufficient_space_rejected":true,"component_mihomo_upgrade":true,"component_incompatible_core_rejected":true}}' >"$work/qualification.json"
