#!/bin/sh
# Source from the isolated setup qualification, never from a real device.
test -f /tmp/netfleet-setup-vm-authorized
cohort="$work/native-cohort"
mkdir -m 700 -p "$cohort/old" "$cohort/new" "$cohort/extracted"
ucode - "$work/fixture.json" <<'UC' >"$cohort/packages.tsv"
import * as fs from 'fs';
const rows=json(fs.readfile(ARGV[0])).native_cohort;
assert(length(rows)==3);
for (let row in rows) printf('%s\t%s\t%s\n',row.name,row.old.artifact,row.new.artifact);
UC
while IFS="$(printf '\t')" read -r name old new; do
 uclient-fetch -q -O "$cohort/old/$old" "$feed_url/components-fixtures/native-cohort/$old"
 uclient-fetch -q -O "$cohort/new/$new" "$feed_url/$new"
done <"$cohort/packages.tsv"
apk --no-network verify "$cohort"/old/*.apk "$cohort"/new/*.apk
stage=native_cohort_baseline
install_fixture "$cohort"/old/*.apk >"$cohort/baseline.log" 2>&1
restore_fixture_world
rpc_ready
unchanged
core_pid_before=$(pidof mihomo)
core_birth_before=$(awk '{print $22}' "/proc/$core_pid_before/stat")
sha256sum /usr/libexec/mihomo /etc/opl-netfleet/native/run/config.yaml >"$cohort/runtime.before"
# Keep the exact original intent and archives available to the component owner.
guard="$cohort/guard"
mkdir -m 700 "$guard" "$guard/old" "$guard/new"
cp "$cohort"/old/*.apk "$guard/old/"
cp "$cohort"/new/*.apk "$guard/new/"
cp /tmp/scripts/https-compat/canary-rollback.sh "$guard/guard.sh"
cp "$cohort/runtime.before" "$guard/private.sha256"
sha256sum /etc/config/netfleet /etc/opl-netfleet/policy.json /etc/opl-netfleet/backend.json >>"$guard/private.sha256"
for archive in "$cohort"/new/*.apk; do apk extract --destination "$cohort/extracted" "$archive"; done
(cd "$cohort/extracted" && find usr -type f -exec sha256sum '{}' +) | sed 's@  usr/@  /usr/@' >"$guard/new-runtime.sha256"
ucode - "$work/fixture.json" "$guard" "$core_pid_before" <<'UC'
import * as fs from 'fs';
const rows=json(fs.readfile(ARGV[0])).native_cohort;
const primary=filter(rows,row=>row.name=='opl-netfleet-plugin-mihomo')[0];
fs.writefile(ARGV[1]+'/rollback.json',sprintf('%J',{package:primary.name,old:primary.old,new:primary.new,
 companions:map(filter(rows,row=>row!=primary),row=>({package:row.name,old:row.old,new:row.new})),
 core_pid:ARGV[2],plugin_disabled:true,timeout_seconds:60}));
UC
sh "$guard/guard.sh" "$guard" validate
printf '%s' '{"accepted":true}' >"$guard/canary-accepted.json"
ubus call service set "{\"name\":\"netfleet-native-cohort-guard\",\"instances\":{\"guard\":{\"command\":[\"/bin/sh\",\"$guard/guard.sh\",\"$guard\",\"guard\"],\"stdout\":false,\"stderr\":false}}}"
stage=native_cohort_retained_update
native_cohort_update() {
 ucode - "$work/fixture.json" "$cohort/request.json" <<'UC'
import * as fs from 'fs';
const primary=filter(json(fs.readfile(ARGV[0])).native_cohort,row=>row.name=='opl-netfleet-plugin-mihomo')[0];
fs.writefile(ARGV[1],sprintf('%J',{request:{name:primary.name,action:'update',version:primary.new.version,before_version:primary.old.version,confirm:false}}));
UC
 ucode "$main" components-plugin-plan "$cohort/request.json" >"$cohort/plan.json"
 assert_json "$cohort/plan.json" '@.ok' true
 ucode - "$cohort" <<'UC'
import * as fs from 'fs';
const dir=ARGV[0],r=json(fs.readfile(dir+'/request.json')),plan=json(fs.readfile(dir+'/plan.json')).result;
assert(sprintf('%J',sort(plan.names))==sprintf('%J',sort(['opl-netfleet','opl-netfleet-plugin-mihomo','opl-netfleet-plugin-network'])));
r.request.confirm=true;r.request.plan=plan;fs.writefile(dir+'/request.json',sprintf('%J',r));
UC
 ucode "$main" components-plugin "$cohort/request.json" >"$cohort/start.json"
 assert_json "$cohort/start.json" '@.ok' true
 rt_id=$(jsonfilter -i "$cohort/start.json" -e '@.result.operation.id')
 wait_operation "$rt_id"
 assert_json "$work/operation-result.json" '@.result.packages.state' succeeded
 assert_json "/etc/opl-netfleet/package-transactions/$rt_id/journal.json" '@.before.runtime_retained' true
 test "$(pidof mihomo)" = "$core_pid_before"
 test "$(awk '{print $22}' "/proc/$core_pid_before/stat")" = "$core_birth_before"
 sha256sum -c "$cohort/runtime.before"
 unchanged
}
native_cohort_update
stage=native_cohort_autonomous_rollback
for attempt in $(seq 1 90); do
 [ "$(jsonfilter -i "$guard/guard-state.json" -e '@.state' 2>/dev/null || true)" != restored ] || break
 sleep 1
done
if [ "$(jsonfilter -i "$guard/guard-state.json" -e '@.state')" != restored ]; then
 cat "$guard/guard-state.json" "$guard/guard.log"; exit 1
fi
test "$(pidof mihomo)" = "$core_pid_before"
test "$(awk '{print $22}' "/proc/$core_pid_before/stat")" = "$core_birth_before"
sha256sum -c "$cohort/runtime.before"
unchanged
ubus call service delete '{"name":"netfleet-native-cohort-guard"}'
stage=native_cohort_reinstall
native_cohort_update
printf '%s\n' '{"ok":true,"checks":{"native_cohort_retained_update":true,"native_cohort_autonomous_rollback":true,"native_cohort_pid_and_configuration_unchanged":true,"native_cohort_disabled_plugin_preserved":true}}' >"$cohort/qualification.json"
