#!/bin/sh
# Real signed APKs, components transaction and an active SSE in the isolated guest.
test -f /tmp/netfleet-compat-vm-authorized
runtime_cycle=/tmp/compat-runtime/runtime-cycle
cp "$runtime_cycle/public-key.pem" /etc/apk/keys/runtime-cycle.pem
ucode - "$runtime_cycle" <<'UC'
import * as fs from 'fs'; import {sha256} from 'digest';
const root=ARGV[0], cycle=json(fs.readfile(root+'/cycle.json'));
for(let kind in ['old','new','bad']) {
 const item=cycle[kind];
 if(!match(item.artifact,/^opl-netfleet-plugin-mihomo-[0-9.]+\.apk$/)||sha256(fs.readfile(root+'/'+kind+'/'+item.artifact))!=item.sha256)die('runtime_cycle_identity_changed');
}
UC
runtime_identity() {
    printf '%s ' "$(pidof mihomo)"
    awk '{print $22}' "/proc/$(pidof mihomo)/stat"
    sha256sum /usr/libexec/mihomo /etc/opl-netfleet/native/run/config.yaml
}
runtime_identity >"$work/native-identity.before"
processes
retained_engine=$engine_pid
runtime_request() {
    prior=$1; next=$2; rt_expected=$3
    watcher_before=$(ubus call service list '{"name":"opl-netfleet-core"}' | jsonfilter -e '@["opl-netfleet-core"].instances.lifecycle.pid')
    manager_before=$(ubus call service list '{"name":"opl-netfleet-compat"}' | jsonfilter -e '@["opl-netfleet-compat"].instances.manager.pid')
    rt_stage=$(mktemp -d /tmp/native-retained-stage.XXXXXX)
    mkdir "$rt_stage/old" "$rt_stage/new"
    cp "$runtime_cycle/$prior/"*.apk "$rt_stage/old/"
    cp "$runtime_cycle/$next/"*.apk "$rt_stage/new/"
    ucode - "$runtime_cycle" "$rt_stage" "$prior" "$next" <<'UC'
import * as fs from 'fs';
const c=json(fs.readfile(ARGV[0]+'/cycle.json')),a=c[ARGV[2]],b=c[ARGV[3]];
fs.writefile(ARGV[1]+'/request.json',sprintf('%J',{schema:'opl-netfleet-plugin-install.v1',packages:[{
 name:'opl-netfleet-plugin-mihomo',before_version:a.version,version:b.version,before_sha256:a.sha256,sha256:b.sha256}]}));
UC
    flock /var/lock/opl-netfleet-deploy.lock ucode /usr/libexec/opl-netfleet/main.uc components-install "$rt_stage" >"$rt_stage/start.json"
    rt_id=$(jsonfilter -i "$rt_stage/start.json" -e '@.result.operation.id')
    test -n "$rt_id"
    rt_journal=/etc/opl-netfleet/package-transactions/$rt_id/journal.json
    for attempt in $(seq 1 110); do
        rt_phase=$(jsonfilter -i "$rt_journal" -e '@.phase' 2>/dev/null || true)
        case "$rt_phase" in complete|rolled_back|failed) break ;; esac
        probe 4 h2
        sleep 1
    done
    test "$rt_phase" = "$rt_expected"
    test "$(jsonfilter -i "$rt_journal" -e '@.before.runtime_retained')" = true
    watcher_after=$(ubus call service list '{"name":"opl-netfleet-core"}' | jsonfilter -e '@["opl-netfleet-core"].instances.lifecycle.pid')
    manager_after=$(ubus call service list '{"name":"opl-netfleet-compat"}' | jsonfilter -e '@["opl-netfleet-compat"].instances.manager.pid')
    test -n "$watcher_after"; test "$watcher_after" != "$watcher_before"
    test -n "$manager_after"; test "$manager_after" != "$manager_before"
    runtime_identity >"$work/native-identity.after"
    cmp "$work/native-identity.before" "$work/native-identity.after"
    processes
    test "$engine_pid" = "$retained_engine"
    wait_intercepting
    probe 4 h2; probe 6 h2
}
ip netns exec nfcompat-client curl --noproxy '*' --http1.1 --connect-timeout 3 --max-time 195 \
    --cacert "$work/client-ca.pem" --resolve 'wire.example:443:198.51.100.10' -fsSN \
    'https://wire.example/compat-wire/long-events' >"$work/native-retained-events.txt" 2>"$work/native-retained-events.log" &
rt_stream=$!
sleep 1
kill -0 "$rt_stream"
grep -q '^data: 0$' "$work/native-retained-events.txt"
installed_runtime=$(apk --no-network query --from installed --format json --fields version opl-netfleet-plugin-mihomo | jsonfilter -e '@[0].version')
if [ "$installed_runtime" = "$(jsonfilter -i "$runtime_cycle/cycle.json" -e '@.old.version')" ]; then
    runtime_request old new complete
else
    test "$installed_runtime" = "$(jsonfilter -i "$runtime_cycle/cycle.json" -e '@.new.version')"
    # The preceding generic engine transaction already upgraded this backend.
    test -f "$work/package-cycle-complete"
fi
runtime_request new bad rolled_back
test "$(jsonfilter -i /etc/opl-netfleet/package-transactions/$rt_id/rollback.json -e '@.runtime_restored')" = true
wait "$rt_stream"
test "$(grep -c '^data:' "$work/native-retained-events.txt")" = 360
test ! -e /etc/opl-netfleet/package-transactions/pending.json
printf '%s\n' '{"ok":true,"native_identity_unchanged":true,"engine_unchanged":true,"observers_restored":true,"stream_completed":true,"signed_candidate_rollback":true}' >"$work/native-runtime-cycle.json"
