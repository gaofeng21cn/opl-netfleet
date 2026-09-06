#!/bin/sh
# Exercise LuCI's real authenticated cgi-io transport without a large ubus payload.
set -eu
umask 077
work=/tmp/netfleet-transfer-fixture
main=/usr/libexec/opl-netfleet/main.uc
helper=/usr/libexec/opl-netfleet-transfer
profile=transfer-fixture.yaml
profile_path=/etc/opl-netfleet/native/profiles/$profile
success_id=2f3eeb3812be4a14b426501729a054c7
stale_id=ea53d043d5f240e8b55c00a3ef88c934
invalid_id=c22cda025e064b1884fb482d459166d7
denied_id=131c954c40f14401a5867f770971b6fd
success_upload=/tmp/opl-netfleet-upload.$success_id.json
stale_upload=/tmp/opl-netfleet-upload.$stale_id.json
invalid_upload=/tmp/opl-netfleet-upload.$invalid_id.json
denied_upload=/tmp/opl-netfleet-upload.$denied_id.json
stage=precondition
test -f /tmp/netfleet-setup-vm-authorized
test "$(jsonfilter -i /etc/opl-netfleet/backend.json -e '@.kind')" = native-mihomo
test -x /www/cgi-bin/cgi-upload
test -x /www/cgi-bin/cgi-exec
test -x "$helper"
test ! -e "$profile_path"
for path in "$success_upload" "$stale_upload" "$invalid_upload" "$denied_upload"; do
	test ! -e "$path"
	test ! -L "$path"
done
mkdir -p "$work"
chmod 0700 "$work"

finish() {
	rc=$?
	trap - EXIT INT TERM
	set +e
	if [ -s "$work/session-destroy.json" ]; then
		ubus call session destroy "$(cat "$work/session-destroy.json")" >/dev/null 2>&1
	fi
	if [ -f "$profile_path" ]; then
		ucode "$main" maintenance-get >"$work/cleanup-state.json" 2>/dev/null
		ucode -e 'import { readfile, writefile } from "fs";
			const state = json(readfile(ARGV[0]));
			writefile(ARGV[1], sprintf("%J", {request:{revision:state.result.revision,id:ARGV[2]}}));' \
			"$work/cleanup-state.json" "$work/cleanup-request.json" "$profile" 2>/dev/null
		(
			exec 9>/var/lock/opl-netfleet-deploy.lock
			flock -w 10 9
			ucode "$main" profile-delete "$work/cleanup-request.json" 9>&- >/dev/null 2>&1
		)
	fi
	# No session token, private backup, or uploaded request remains in the receipt directory.
	rm -f "$success_upload" "$stale_upload" "$invalid_upload" "$denied_upload" \
		"$work/session.json" "$work/session-id" "$work/session-destroy.json" "$work/grant-file.json" \
		"$work/grant-ubus.json" "$work/grant-upload.json" "$work/rpc-request.json" "$work/upload-request.json" \
		"$work/stale-request.json" "$work/invalid-request.json" "$work/profile-response.json" \
		"$work/backup-response.json" "$work/expected-profile.yaml" "$work/cleanup-request.json"
	if [ "$rc" -ne 0 ]; then
		echo "LuCI transfer qualification failed at: $stage" >&2
	fi
	exit "$rc"
}
trap finish EXIT INT TERM
assert_json() { [ "$(jsonfilter -i "$1" -e "$2")" = "$3" ]; }
rpc_request() {
	ucode -e 'import { readfile, writefile } from "fs";
		const args = ARGV[3] == "" ? {} : json(ARGV[3]);
		writefile(ARGV[1], sprintf("%J", {jsonrpc:"2.0",id:1,method:"call",params:[readfile(ARGV[0]),"opl-netfleet",ARGV[2],args]}));' \
		"$work/session-id" "$work/rpc-request.json" "$1" "${2:-}"
	curl -q -fsS --noproxy '*' --proxy '' --connect-timeout 3 --max-time 90 \
		-H 'Content-Type: application/json' --data-binary "@$work/rpc-request.json" \
		http://127.0.0.1/ubus >"$work/rpc-response.json"
	assert_json "$work/rpc-response.json" '@.result[0]' 0
}
upload() {
	curl -q -fsS --noproxy '*' --proxy '' --connect-timeout 3 --max-time 45 \
		-F "sessionid=<$work/session-id" -F "filename=$1" -F "filedata=@$2;type=application/json" \
		http://127.0.0.1/cgi-bin/cgi-upload >"$work/upload-response.json"
	ucode -e 'import { readfile, lstat } from "fs";
		const response = json(readfile(ARGV[0])), info = lstat(ARGV[1]);
		if (response.error || info?.type != "file" || info.uid != 0 || (info.mode & 0777) != 0600) exit(1);' \
		"$work/upload-response.json" "$1"
}
execute() {
	curl -q -fsS --noproxy '*' --proxy '' --connect-timeout 3 --max-time 90 \
		--data-urlencode "sessionid@$work/session-id" --data-urlencode "command=$1" \
		http://127.0.0.1/cgi-bin/cgi-exec >"$2"
}
unchanged_runtime() {
	ucode -e 'import { readfile, popen } from "fs";
		const before = json(readfile(ARGV[0]));
		const process = popen("ubus call service list '\''{\"name\":\"opl-netfleet-core\"}'\''");
		const after = json(process.read("all")); if (process.close() != 0) exit(1);
		if (before["opl-netfleet-core"].instances.core.pid != after["opl-netfleet-core"].instances.core.pid) exit(1);' \
		"$work/service-before.json"
	sha256sum -c "$work/runtime-before.sha256" >/dev/null
}

stage=installed_acl
ucode -e 'import { readfile } from "fs";
	const acl = json(readfile(ARGV[0]))["luci-app-netfleet"];
	for (let method in ["maintenance_get"])
		if (index(acl?.read?.ubus?.["opl-netfleet"] ?? [], method) < 0) exit(1);
	for (let method in ["profile_save","profile_delete"])
		if (index(acl?.write?.ubus?.["opl-netfleet"] ?? [], method) < 0) exit(1);
	if (index(acl?.write?.["cgi-io"] ?? [], "upload") < 0 || index(acl?.read?.["cgi-io"] ?? [], "exec") < 0 ||
		index(acl?.write?.file?.["/usr/libexec/opl-netfleet-transfer profile-get *"] ?? [], "exec") < 0 ||
		index(acl?.write?.file?.["/usr/libexec/opl-netfleet-transfer backup-export"] ?? [], "exec") < 0 ||
		index(acl?.write?.file?.["/tmp/opl-netfleet-upload.*.json"] ?? [], "write") < 0) exit(1);' \
	/usr/share/rpcd/acl.d/luci-app-netfleet.json
ubus call service list '{"name":"opl-netfleet-core"}' >"$work/service-before.json"
assert_json "$work/service-before.json" '@["opl-netfleet-core"].instances.core.running' true
sha256sum /etc/config/netfleet /etc/opl-netfleet/policy.json /etc/opl-netfleet/native/run/config.yaml >"$work/runtime-before.sha256"
stage=session
ubus call session create '{"timeout":600}' >"$work/session.json"
ucode -e 'import { readfile, writefile } from "fs";
	const session = json(readfile(ARGV[0])).ubus_rpc_session;
	if (!match(session ?? "", /^[a-f0-9]{32}$/)) exit(1);
	writefile(ARGV[1]+"/session-id", session);
	writefile(ARGV[1]+"/session-destroy.json", sprintf("%J", {ubus_rpc_session:session}));
	writefile(ARGV[1]+"/grant-upload.json", sprintf("%J", {ubus_rpc_session:session,scope:"cgi-io",objects:[["upload","write"],["exec","read"]]}));
	writefile(ARGV[1]+"/grant-file.json", sprintf("%J", {ubus_rpc_session:session,scope:"file",objects:[
		["/usr/libexec/opl-netfleet-transfer profile-get *","exec"],
		["/usr/libexec/opl-netfleet-transfer backup-export","exec"],
		[ARGV[2],"write"],[ARGV[3],"write"],[ARGV[4],"write"]]}));
	writefile(ARGV[1]+"/grant-ubus.json", sprintf("%J", {ubus_rpc_session:session,scope:"ubus",objects:[
		["opl-netfleet","maintenance_get"],["opl-netfleet","profile_save"],["opl-netfleet","profile_delete"]]}));' \
	"$work/session.json" "$work" "$success_upload" "$stale_upload" "$invalid_upload"
ubus call session grant "$(cat "$work/grant-file.json")" >/dev/null
ubus call session grant "$(cat "$work/grant-upload.json")" >/dev/null
ubus call session grant "$(cat "$work/grant-ubus.json")" >/dev/null
rpc_request maintenance_get
assert_json "$work/rpc-response.json" '@.result[1].ok' true

stage=large_profile_upload
ucode -e 'import { readfile, writefile } from "fs";
	const revision = json(readfile(ARGV[0])).result[1].result.revision;
	let content = "";
	const line = "#" + sprintf("%1024s", "transport fixture") + "\n";
	for (let i = 0; i < 1200; i++) content += line;
	content += "proxies: []\nproxy-groups: []\nrules: [\"MATCH,DIRECT\"]\n";
	if (length(content) <= 1048576) exit(1);
	writefile(ARGV[1], content);
	writefile(ARGV[2], sprintf("%J", {request:{revision:revision,id:ARGV[3],content:content}}));
	writefile(ARGV[4], sprintf("%J", {request:{revision:"stale",id:ARGV[3],content:content}}));' \
	"$work/rpc-response.json" "$work/expected-profile.yaml" "$work/upload-request.json" "$profile" "$work/stale-request.json"
upload "$success_upload" "$work/upload-request.json"
rpc_request profile_save "{\"request\":{\"upload_id\":\"$success_id\"}}"
assert_json "$work/rpc-response.json" '@.result[1].ok' true
test ! -e "$success_upload"
cmp "$profile_path" "$work/expected-profile.yaml"
unchanged_runtime

stage=full_profile_download
execute "$helper profile-get $profile" "$work/profile-response.json"
ucode -e 'import { readfile, stat } from "fs";
	const response = json(readfile(ARGV[0]));
	if (stat(ARGV[0]).size <= 1048576 || response.ok != true || response.result.profile.content != readfile(ARGV[1])) exit(1);' \
	"$work/profile-response.json" "$work/expected-profile.yaml"
stage=full_backup_download
execute "$helper backup-export" "$work/backup-response.json"
ucode -e 'import { readfile, stat } from "fs";
	const response = json(readfile(ARGV[0]));
	const backup = response?.result?.backup;
	const file = filter(backup?.files ?? [], value => value.path == "native/profiles/"+ARGV[2])[0];
	if (stat(ARGV[0]).size <= 1048576 || response.ok != true || backup.format != "netfleet-backup-v1" ||
		file == null || b64dec(file.content) != readfile(ARGV[1])) exit(1);' \
	"$work/backup-response.json" "$work/expected-profile.yaml" "$profile"
unchanged_runtime

stage=failed_upload_consumption
upload "$stale_upload" "$work/stale-request.json"
rpc_request profile_save "{\"request\":{\"upload_id\":\"$stale_id\"}}"
assert_json "$work/rpc-response.json" '@.result[1].ok' false
assert_json "$work/rpc-response.json" '@.result[1].error' maintenance_revision_changed
test ! -e "$stale_upload"
printf '%s\n' '{invalid' >"$work/invalid-request.json"
upload "$invalid_upload" "$work/invalid-request.json"
rpc_request profile_save "{\"request\":{\"upload_id\":\"$invalid_id\"}}"
assert_json "$work/rpc-response.json" '@.result[1].ok' false
assert_json "$work/rpc-response.json" '@.result[1].error' invalid_maintenance_request
test ! -e "$invalid_upload"
cmp "$profile_path" "$work/expected-profile.yaml"
unchanged_runtime

stage=unauthenticated_transfer_rejected
upload_status=$(curl -q -sS --noproxy '*' --proxy '' --connect-timeout 3 --max-time 30 \
	-F 'sessionid=00000000000000000000000000000000' -F "filename=$denied_upload" \
	-F "filedata=@$work/invalid-request.json;type=application/json" -o "$work/denied-upload.json" -w '%{http_code}' \
	http://127.0.0.1/cgi-bin/cgi-upload)
# cgi-upload reports denied uploads in its JSON failure envelope with HTTP 200.
test "$upload_status" = 200
assert_json "$work/denied-upload.json" '@.failure[0]' 1
test ! -e "$denied_upload"
execute_status=$(curl -q -sS --noproxy '*' --proxy '' --connect-timeout 3 --max-time 30 \
	--data-urlencode 'sessionid=00000000000000000000000000000000' --data-urlencode "command=$helper profile-get $profile" \
	-o "$work/denied-exec.json" -w '%{http_code}' http://127.0.0.1/cgi-bin/cgi-exec)
test "$execute_status" = 403
stage=command_whitelist
command_status=$(curl -q -sS --noproxy '*' --proxy '' --connect-timeout 3 --max-time 30 \
	--data-urlencode "sessionid@$work/session-id" --data-urlencode 'command=/sbin/uci show netfleet' \
	-o "$work/denied-command.json" -w '%{http_code}' http://127.0.0.1/cgi-bin/cgi-exec)
test "$command_status" = 403

stage=profile_cleanup
rpc_request maintenance_get
revision=$(jsonfilter -i "$work/rpc-response.json" -e '@.result[1].result.revision')
rpc_request profile_delete "{\"request\":{\"revision\":\"$revision\",\"id\":\"$profile\"}}"
assert_json "$work/rpc-response.json" '@.result[1].ok' true
test ! -e "$profile_path"
unchanged_runtime
stage=complete
printf '%s\n' '{"ok":true,"checks":{"luci_transfer_minimal_acl":true,"luci_large_profile_upload":true,"luci_upload_private_mode":true,"luci_large_profile_download":true,"luci_large_backup_download":true,"luci_upload_success_cleanup":true,"luci_upload_failure_cleanup":true,"luci_wrong_session_rejected":true,"luci_transfer_command_whitelist":true,"luci_transfer_running_profile_unchanged":true}}' >"$work/qualification.json"
