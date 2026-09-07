#!/bin/sh
set -eu
umask 077
test -f /tmp/netfleet-native-vm-authorized
packages=/tmp/netfleet-plugin-packages
work=$(mktemp -d /tmp/netfleet-plugin-package-test.XXXXXX)
main=/usr/libexec/opl-netfleet/main.uc
rpc=/usr/libexec/rpcd/opl-netfleet.plugins
id=device-info
package=opl-netfleet-plugin-device-info
marker=/var/run/opl-netfleet-plugin-maintenance/$id
core_pid=$(pidof mihomo)
test -n "$core_pid"
overlay=/etc/opl-netfleet/system.json
overlay_saved=0
host_installed=0
if [ -e "$overlay" ]; then
	cp -p "$overlay" "$work/system.original"
	overlay_saved=1
fi
finish() {
	rc=$?
	if [ "$rc" -ne 0 ]; then
		for file in "$work"/*.log "$work"/response.json; do
			[ ! -f "$file" ] || tail -40 "$file" >&2
		done
	fi
	if [ "$overlay_saved" = 1 ]; then cp -p "$work/system.original" "$overlay";
	else rm -f "$overlay"; fi
	rm -rf "$work"
	exit "$rc"
}
trap finish EXIT
cp "$packages"/*.pem /etc/apk/keys/
if ! apk --no-network info -e opl-netfleet-kernel >/dev/null 2>&1; then
	apk --no-network add "$packages"/netfleet-plugin-vm-host-*.apk >"$work/install-host.log" 2>&1
	host_installed=1
fi
apk --no-network add "$packages"/opl-netfleet-plugin-device-info-0.1.0-r1.apk >"$work/install.log" 2>&1
test ! -e "$marker"
invoke() {
	params='{}'
	[ "$#" -lt 2 ] || params=$2
	ucode "$main" plugins-list >"$work/list.json"
	ucode -e '
		import * as fs from "fs";
		const plugin = filter(json(fs.readfile(ARGV[0])).result.plugins, item => item.id == ARGV[1])[0];
		if (plugin == null) exit(1);
		printf("%J\n", {request:{id:plugin.id,action:ARGV[2],revision:plugin.revision,confirm:true,params:json(ARGV[3])}});
	' "$work/list.json" "$id" "$1" "$params" >"$work/request.json"
	case "$1" in get|inspect|config-get) access=plugin_read ;; *) access=plugin_call ;; esac
	"$rpc" call "$access" <"$work/request.json" >"$work/response.json"
	test "$(jsonfilter -i "$work/response.json" -e '@.ok')" = true
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

id=workspace-note
package=opl-netfleet-plugin-workspace-note
marker=/var/run/opl-netfleet-plugin-maintenance/$id
root=/usr/libexec/opl-netfleet/plugins/$id
public=/www/luci-static/resources/netfleet/plugins/$id
data="$work/note.json"
ucode -e '
	import * as fs from "fs";
	let profile = fs.stat(ARGV[0]) == null ? {schema:"opl-netfleet-system.v1",bindings:{},enabled:{}} : json(fs.readfile(ARGV[0]));
	profile.config = profile.config ?? {};
	profile.config["workspace-note"] = {data_path:ARGV[1]};
	if (!fs.writefile(ARGV[0], sprintf("%J\n", profile)) || !fs.chmod(ARGV[0], 0600)) exit(1);
' "$overlay" "$data"
apk --no-network add "$packages"/opl-netfleet-plugin-workspace-note-0.1.0-r1.apk >"$work/note-install.log" 2>&1
test ! -e "$marker"
invoke load
invoke config-get
test "$(jsonfilter -i "$work/response.json" -e '@.result.generation')" = 0
invoke config-set '{"title":"Qualification note","text":"Keep this through package upgrade","generation":0}'
test "$(jsonfilter -i "$work/response.json" -e '@.result.generation')" = 1
ucode -e 'import * as fs from "fs"; exit((fs.stat(ARGV[0]).mode & 0777) == 0600 ? 0 : 1);' "$data"
saved_sha=$(sha256sum "$data" | cut -d ' ' -f 1)
revision_before=$(jsonfilter -i "$packages/fixture.json" -e '@.plugins["workspace-note"]["0.1.0"].revision')
test -n "$revision_before"
test -f "$public/$revision_before/resources/page.js"
cmp "$root/resources/style.css" "$public/$revision_before/resources/style.css"
test ! -e "$public/resources"
ucode -e '
	import * as fs from "fs";
	const item = filter(json(fs.readfile(ARGV[0])).result.plugins, item => item.id == "workspace-note")[0];
	if (item?.revision != ARGV[1] || length(item?.ui ?? []) != 1 || item.configuration?.write != "config-set") exit(1);
' "$work/list.json" "$revision_before"

apk --no-network add "$packages"/opl-netfleet-plugin-workspace-note-0.1.1-r1.apk >"$work/note-upgrade.log" 2>&1
test ! -e "$marker"
test "$(jsonfilter -i "$root/manifest.json" -e '@.version')" = 0.1.1
test "$(sha256sum "$data" | cut -d ' ' -f 1)" = "$saved_sha"
invoke config-get
test "$(jsonfilter -i "$work/response.json" -e '@.result.title')" = 'Qualification note'
test "$(jsonfilter -i "$work/response.json" -e '@.result.text')" = 'Keep this through package upgrade'
test "$(jsonfilter -i "$work/response.json" -e '@.result.generation')" = 1
revision_after=$(jsonfilter -i "$packages/fixture.json" -e '@.plugins["workspace-note"]["0.1.1"].revision')
test -n "$revision_after"
test "$revision_before" != "$revision_after"
test -f "$public/$revision_after/resources/page.js"
test ! -e "$public/$revision_before/resources/page.js"
cmp "$root/resources/style.css" "$public/$revision_after/resources/style.css"
ucode -e '
	import * as fs from "fs";
	const item = filter(json(fs.readfile(ARGV[0])).result.plugins, item => item.id == "workspace-note")[0];
	if (item?.revision != ARGV[1]) exit(1);
' "$work/list.json" "$revision_after"
invoke config-set '{"title":"Updated note","text":"New code accepts the persisted generation","generation":1}'
test "$(jsonfilter -i "$work/response.json" -e '@.result.generation')" = 2

apk --no-network del "$package" >"$work/note-remove.log" 2>&1
test ! -e "$root/manifest.json"
test ! -e "$public/$revision_after/resources/page.js"
test ! -e "$marker"
test "$(jsonfilter -i "$data" -e '@.generation')" = 2
ucode "$main" plugins-list >"$work/list.json"
ucode -e 'import * as fs from "fs"; if (length(filter(json(fs.readfile(ARGV[0])).result.plugins, item => item.id == "workspace-note"))) exit(1);' "$work/list.json"
test "$(pidof mihomo)" = "$core_pid"
if [ "$host_installed" = 1 ]; then apk --no-network del netfleet-plugin-vm-host >"$work/remove-host.log" 2>&1; fi
printf '{"ok":true,"install":true,"load":true,"upgrade":true,"remove":true,"workspace_note":{"signed_install":true,"generic_rpc":true,"configuration_saved":true,"configuration_preserved_on_upgrade":true,"revision_assets_replaced":true,"updated_code_accepts_saved_configuration":true,"uninstall_removes_plugin_and_assets":true,"user_data_preserved_on_uninstall":true},"core_pid_unchanged":true,"artifact_sha256":"%s"}\n' \
	"$(sha256sum /tmp/plugin-packages.tar | cut -d ' ' -f 1)"
