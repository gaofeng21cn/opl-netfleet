#!/bin/sh
set -eu
umask 077
test -f /tmp/netfleet-native-vm-authorized
packages=/tmp/netfleet-plugin-packages
work=$(mktemp -d /tmp/netfleet-plugin-package-test.XXXXXX)
main=/usr/libexec/opl-netfleet/main.uc
id=device-info
package=opl-netfleet-plugin-device-info
marker=/var/run/opl-netfleet-plugin-maintenance/$id
core_pid=$(pidof mihomo)
test -n "$core_pid"
finish() {
	rc=$?
	if [ "$rc" -ne 0 ]; then
		for file in "$work"/*.log "$work"/response.json; do
			[ ! -f "$file" ] || tail -40 "$file" >&2
		done
	fi
	rm -rf "$work"
	exit "$rc"
}
trap finish EXIT
cp "$packages"/*.pem /etc/apk/keys/
apk --no-network add "$packages"/netfleet-plugin-vm-host-*.apk >"$work/install-host.log" 2>&1
apk --no-network add "$packages"/opl-netfleet-plugin-device-info-0.1.0-r1.apk >"$work/install.log" 2>&1
test ! -e "$marker"
invoke() {
	ucode "$main" plugins-list >"$work/list.json"
	ucode -e '
		import * as fs from "fs";
		const plugin = filter(json(fs.readfile(ARGV[0])).result.plugins, item => item.id == "device-info")[0];
		if (plugin == null) exit(1);
		printf("%J\n", {request:{id:plugin.id,action:ARGV[1],revision:plugin.revision,confirm:true}});
	' "$work/list.json" "$1" >"$work/request.json"
	case "$1" in get|inspect) access=plugin-read ;; *) access=plugin-call ;; esac
	ucode "$main" "$access" "$work/request.json" >"$work/response.json"
}
invoke get
test "$(jsonfilter -i "$work/response.json" -e '@.result.loaded')" = false
invoke load
test "$(jsonfilter -i "$work/response.json" -e '@.result.ready')" = true
invoke inspect
test "$(jsonfilter -i "$work/response.json" -e '@.result.release.distribution')" = OpenWrt
apk --no-network add "$packages"/opl-netfleet-plugin-device-info-0.1.1-r1.apk >"$work/upgrade.log" 2>&1
test ! -e "$marker"
test "$(jsonfilter -i /usr/libexec/opl-netfleet/plugins/device-info/manifest.json -e '@.version')" = 0.1.1
invoke get
test "$(jsonfilter -i "$work/response.json" -e '@.result.loaded')" = false
invoke load
test "$(jsonfilter -i "$work/response.json" -e '@.result.ready')" = true
apk --no-network del "$package" >"$work/remove.log" 2>&1
test ! -e /usr/libexec/opl-netfleet/plugins/device-info/control
test ! -e /var/run/opl-netfleet-plugin-device-info
test ! -e "$marker"
test "$(pidof mihomo)" = "$core_pid"
apk --no-network del netfleet-plugin-vm-host >"$work/remove-host.log" 2>&1
printf '{"ok":true,"install":true,"load":true,"upgrade":true,"remove":true,"core_pid_unchanged":true,"artifact_sha256":"%s"}\n' \
	"$(sha256sum /tmp/plugin-packages.tar | cut -d ' ' -f 1)"
