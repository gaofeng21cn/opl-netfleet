#!/bin/sh
set -eu
umask 077
test -f /tmp/netfleet-native-vm-authorized
packages=/tmp/netfleet-plugin-packages
work=$(mktemp -d /tmp/netfleet-plugin-components.XXXXXX)
main=/usr/libexec/opl-netfleet/main.uc
rpc=/usr/libexec/rpcd/opl-netfleet
repository=/etc/apk/repositories.d/opl-netfleet.list
saved=0
server=
stage=prepare
core_pid=$(pidof mihomo)
test -n "$core_pid"
if [ -f "$repository" ]; then cp -p "$repository" "$work/repository"; saved=1; fi
finish() {
	rc=$?
	trap - EXIT
	[ -z "$server" ] || kill "$server" 2>/dev/null || true
	if [ "$saved" = 1 ]; then cp -p "$work/repository" "$repository"; else rm -f "$repository"; fi
	if [ "$rc" != 0 ]; then
		echo "Plugin component transaction failed: $stage" >&2
		for file in "$work"/*.json "$work"/*.log /etc/opl-netfleet/package-transactions/*/log; do
			[ ! -f "$file" ] || tail -50 "$file" >&2
		done
	fi
	rm -rf "$work"
	exit "$rc"
}
trap finish EXIT
mkdir -p /etc/apk/repositories.d
uhttpd -f -p 127.0.0.1:19981 -h "$packages" >"$work/http.log" 2>&1 &
server=$!
select_feed() {
	printf 'http://127.0.0.1:19981/%s/packages.adb\n' "$1" >"$repository"
	apk --timeout 10 update >"$work/index.log" 2>&1
}
assert_json() { test "$(jsonfilter -i "$1" -e "$2")" = "$3"; }
plan() {
	ucode -e 'printf("%J\n", {request:{name:"opl-netfleet-plugin-device-info",action:ARGV[0],version:ARGV[1] || null,before_version:ARGV[2] || null}});' "$1" "$2" "$3" >"$work/request.json"
	"$rpc" call components_plugin_plan <"$work/request.json" >"$work/plan.json"
	assert_json "$work/plan.json" '@.ok' true
	ucode -e 'import * as fs from "fs";
		const value=json(fs.readfile(ARGV[0])); value.request.confirm=true;
		value.request.plan=json(fs.readfile(ARGV[1])).result;
		printf("%J\n",value);' "$work/request.json" "$work/plan.json" >"$work/confirmed.json"
}
run() {
	"$rpc" call components_plugin <"$work/confirmed.json" >"$work/start.json"
	assert_json "$work/start.json" '@.ok' true
	wanted=$(jsonfilter -i "$work/start.json" -e '@.result.operation.id')
	test -n "$wanted"
	for attempt in $(seq 1 180); do
		ucode "$main" operation-get >"$work/progress.json"
		id=$(jsonfilter -i "$work/progress.json" -e '@.result.packages.id')
		state=$(jsonfilter -i "$work/progress.json" -e '@.result.packages.state')
		if [ "$id" = "$wanted" ]; then
			case "$state" in succeeded|failed|interrupted) return 0 ;; esac
		fi
		sleep 1
	done
	return 1
}
version() { jsonfilter -i /usr/libexec/opl-netfleet/plugins/device-info/manifest.json -e '@.version'; }
stage=install
select_feed old
plan install 0.1.0 ''
run
assert_json "$work/progress.json" '@.result.packages.state' succeeded
test "$(version)" = 0.1.0
test "$(pidof mihomo)" = "$core_pid"
stage=stale_request
"$rpc" call components_plugin <"$work/confirmed.json" >"$work/stale.json"
assert_json "$work/stale.json" '@.ok' false
assert_json "$work/stale.json" '@.error' installed_version_changed
stage=upgrade
select_feed new
plan update 0.1.1 0.1.0
run
assert_json "$work/progress.json" '@.result.packages.state' succeeded
test "$(version)" = 0.1.1
test "$(pidof mihomo)" = "$core_pid"
stage=failed_hook_rollback
select_feed broken
plan update 0.1.2 0.1.1
run
assert_json "$work/progress.json" '@.result.packages.state' failed
assert_json "$work/progress.json" '@.result.packages.recovery' restored
test "$(version)" = 0.1.1
test ! -f /etc/opl-netfleet/package-transactions/pending.json
test "$(pidof mihomo)" = "$core_pid"
stage=uninstall
plan remove '' 0.1.1
run
assert_json "$work/progress.json" '@.result.packages.state' succeeded
test ! -f /usr/libexec/opl-netfleet/plugins/device-info/manifest.json
test "$(pidof mihomo)" = "$core_pid"
ucode "$main" probe >"$work/probe.json"
assert_json "$work/probe.json" '@.result.ok' true
printf '{"ok":true,"signed_install":true,"owner_plan":true,"stale_rejected":true,"upgrade":true,"failed_hook_rolled_back":true,"uninstall":true,"core_pid_unchanged":true}\n'
