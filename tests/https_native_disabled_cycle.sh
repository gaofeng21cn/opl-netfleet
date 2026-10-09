#!/bin/sh
# Sourced after the ordinary network fixture has disabled interception.
test -f /tmp/netfleet-compat-vm-authorized
test -f "$work/package-cycle-complete"
ucode /tmp/tests/https_native_guest.uc plugin-unload >"$work/disabled-cycle-unload.json"
assert_compatibility_handoff
apk --no-network --repositories-file /dev/null add "$cycle_old" >"$work/disabled-cycle-old.log" 2>&1
test "$(pidof mihomo)" = "$base_pid"
guard=$(mktemp -d /tmp/netfleet-disabled-guard-test.XXXXXX)
mkdir "$guard/old" "$guard/new"
cp "$cycle_old" "$guard/old/"
cp "$cycle_new" "$guard/new/"
cp /tmp/scripts/https-compat/canary-rollback.sh "$guard/guard.sh"
sha256sum /etc/config/netfleet /etc/opl-netfleet/system.json /etc/opl-netfleet/native/run/config.yaml \
 /etc/opl-netfleet/compatibility/config.json /etc/opl-netfleet/compatibility/trust.json \
 /etc/opl-netfleet/compatibility/ca/mitmproxy-ca.pem >"$guard/private.sha256"
grep -E '^opl-netfleet-https-compat([=<>~!]|$)' /etc/apk/world >"$work/disabled-cycle-world.txt"
ucode - "$guard" "$cycle_old" "$cycle_new" "$base_pid" <<'UC'
import * as fs from 'fs';import {sha256} from 'digest';
function artifact(path) {
 const p=fs.popen('apk adbdump --format json '+path),info=json(p.read('all')).info;
 if(p.close()!=0)die('disabled_guard_metadata_failed');
 return {version:info.version,artifact:fs.basename(path),sha256:sha256(fs.readfile(path))};
}
const pid=ARGV[3],stat=fs.readfile('/proc/'+pid+'/stat');
fs.writefile(ARGV[0]+'/rollback.json',sprintf('%J',{package:'opl-netfleet-https-compat',
 plugin_disabled:true,timeout_seconds:30,core_pid:pid,
 core_birth:split(trim(substr(stat,rindex(stat,') ')+2)),/\s+/)[19],
 world_entry:trim(fs.readfile('/tmp/https-native-network/disabled-cycle-world.txt')),
 old:artifact(ARGV[1]),new:artifact(ARGV[2])}));
UC
# This must reject an incapable owner before installing any archive.
sh "$guard/guard.sh" "$guard" validate
cycle_expected_protocol=http/1.1
cycle_update
unset cycle_expected_protocol
test "$(jsonfilter -i "$cycle_journal" -e '@.before.runtime_retained')" = true
test "$(pidof mihomo)" = "$base_pid"
sha256sum -c "$guard/private.sha256"
sha256sum /usr/libexec/opl-netfleet-compat/control.uc /usr/libexec/opl-netfleet-compat/haproxy \
 /usr/lib/ucode/netfleet_interception.so >"$guard/new-runtime.sha256"
ucode - "$guard" <<'UC'
import * as fs from 'fs';
const request=sprintf('%J',{name:'netfleet-disabled-guard-test',instances:{guard:{
 command:['/bin/sh',ARGV[0]+'/guard.sh',ARGV[0],'guard'],stdout:false,stderr:false,term_timeout:5}}});
if(system("ubus call service set '"+replace(request,"'","'\\''")+"'")!=0)die('disabled_guard_start_failed');
UC
for attempt in $(seq 1 80); do
 [ -f "$guard/guard-state.json" ] && [ "$(jsonfilter -i "$guard/guard-state.json" -e '@.state')" = restored ] && break
 sleep 2
done
test "$(jsonfilter -i "$guard/guard-state.json" -e '@.state')" = restored || {
 cat "$guard/guard-state.json" "$guard/guard.log"; exit 1;
}
test "$(apk --no-network query --from installed --format json --fields version opl-netfleet-https-compat | jsonfilter -e '@[0].version')" = "$old_version"
test "$(pidof mihomo)" = "$base_pid"
sha256sum -c "$guard/private.sha256"
grep -E '^opl-netfleet-https-compat([=<>~!]|$)' /etc/apk/world >"$work/disabled-cycle-restored-world.txt"
cmp "$work/disabled-cycle-world.txt" "$work/disabled-cycle-restored-world.txt"
assert_compatibility_handoff
probe 4 http/1.1
probe 6 http/1.1
ucode /usr/libexec/opl-netfleet/main.uc plugins-system-get >"$work/disabled-cycle-system.json"
ucode - "$work/disabled-cycle-system.json" <<'UC'
import * as fs from 'fs';
const value=json(fs.readfile(ARGV[0])).result;
if({...value.defaults.enabled,...value.config.enabled}['https-compat']!==false)die('disabled_guard_enabled_plugin');
UC
ubus call service delete '{"name":"netfleet-disabled-guard-test"}' >/dev/null 2>&1 || true
cp "$guard/guard-state.json" "$work/disabled-canary-rollback.json"
printf '%s\n' 'disabled engine update and autonomous rollback: core, plugin setting, private configuration and base traffic preserved'
