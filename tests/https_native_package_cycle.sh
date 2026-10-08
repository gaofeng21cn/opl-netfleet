#!/bin/sh
# Sourced by the live network fixture, with the base already forwarding.
set -x
test -f /tmp/netfleet-compat-vm-authorized
cycle=/tmp/compat-runtime/upgrade.json
test -f "$cycle"
ucode - "$cycle" <<'UC'
import * as fs from 'fs';import {sha256} from 'digest';
const value=json(fs.readfile(ARGV[0]));
const text=fs.readfile('/tmp/compat-runtime/composition.json');
if(text) {const previous=json(text).previous_engine;if(previous?.sha256!=value.old.sha256||'rollback/'+previous?.artifact!=value.old.file)die('previous_engine_identity_mismatch');}
for(let key in ['old','new']) {
 const item=value[key];
 if(!match(item.file,/^(rollback\/)?[a-zA-Z0-9_.-]+\.apk$/)||sha256(fs.readfile('/tmp/compat-runtime/'+item.file))!=item.sha256)die('upgrade_artifact_invalid');
}
UC
cycle_old=/tmp/compat-runtime/$(jsonfilter -i "$cycle" -e '@.old.file')
cycle_new=/tmp/compat-runtime/$(jsonfilter -i "$cycle" -e '@.new.file')
old_version=$(apk adbdump --format json "$cycle_old" | jsonfilter -e '@.info.version')
new_version=$(apk adbdump --format json "$cycle_new" | jsonfilter -e '@.info.version')
sha256sum /etc/opl-netfleet/compatibility/config.json /etc/opl-netfleet/compatibility/trust.json \
 /etc/opl-netfleet/compatibility/ca/mitmproxy-ca.pem >"$work/cycle-private.sha256"
processes
cycle_engine=$engine_pid
ip netns exec nfcompat-client curl --noproxy '*' --http1.1 --connect-timeout 3 --max-time 195 \
 --cacert "$work/client-ca.pem" --resolve 'wire.example:443:198.51.100.10' -fsSN \
 'https://wire.example/compat-wire/long-events' >"$work/package-cycle-events.txt" 2>"$work/package-cycle-events.log" &
cycle_stream=$!
sleep 1
kill -0 "$cycle_stream"
grep -q '^data: 0$' "$work/package-cycle-events.txt"
cycle_install() {
 (
  exec 9>/var/lock/opl-netfleet-deploy.lock
  flock -w 10 9
  # Explicit owner admission precedes APK: a rejected drain cannot write files.
  ucode /usr/libexec/opl-netfleet/main.uc plugin-package-drain https-compat >"$work/cycle-drain.json"
  apk --no-network --repositories-file /dev/null --force-reinstall add "$1" 9>&-
 ) >>"$work/cycle.log" 2>&1
 test "$(pidof mihomo)" = "$base_pid"
 processes
 test "$engine_pid" = "$cycle_engine"
 sha256sum -c "$work/base.sha256" >>"$work/cycle.log"
 sha256sum -c "$work/cycle-private.sha256" >>"$work/cycle.log"
 wait_intercepting
 probe 4 h2; probe 6 h2
}
# Feed update exercises the same components owner used by every plugin. Generic
# worker failure/rollback is qualified in guest-components-qualify.sh; no second
# HTTPS updater is staged or run here.
cycle_install "$cycle_old"
transaction=$(mktemp -d /tmp/netfleet-plugin-update-test.XXXXXX)
mkdir "$transaction/feed" "$transaction/old"
cp "$cycle_new" "$transaction/feed/"
cp /tmp/compat-runtime/compat-packages.adb "$transaction/feed/packages.adb"
cp "$cycle_old" "$transaction/old/"
cp /tmp/scripts/update-openwrt-plugins-remote.sh "$transaction/run.sh"
cp /tmp/scripts/observe-openwrt.uc "$transaction/observe.uc"
# A signed local Feed exercises the same solver and transaction without
# refreshing unrelated Internet repositories during the package cycle.
printf '%s/packages.adb\n' "$transaction/feed" >/etc/apk/repositories.d/netfleet-cycle.list
apk --no-network query --from none -X "$transaction/feed/packages.adb" \
 --format json --fields name,version opl-netfleet-https-compat >>"$work/cycle.log"
apk adbdump --format json "$cycle_new" >"$transaction/metadata.json"
ucode - "$transaction" <<'UC'
import * as fs from 'fs';
const dir=ARGV[0],m=json(fs.readfile(dir+'/metadata.json')).info;
const p=fs.popen('apk --no-network query --from installed --format json --fields name,version '+m.name);
const before=json(p.read('all'))[0].version;if(p.close()!=0)die('installed_read_failed');
fs.writefile(dir+'/request.json',sprintf('%J',{request:{name:m.name,action:'update',version:m.version,before_version:before}}));
UC
ucode /usr/libexec/opl-netfleet/main.uc components-plugin-plan "$transaction/request.json" >"$transaction/plan.json"
ucode - "$transaction" <<'UC'
import * as fs from 'fs';
const dir=ARGV[0],value=json(fs.readfile(dir+'/request.json')),plan=json(fs.readfile(dir+'/plan.json'));
if(!plan.ok||!length(plan.result.names))die('generic_engine_plan_failed');
value.request.confirm=true;value.request.plan=plan.result;
fs.writefile(dir+'/feed-request.json',sprintf('%J',value));
UC
(cd "$transaction"; sha256sum run.sh observe.uc feed-request.json old/*.apk >SHA256SUMS)
if ! sh "$transaction/run.sh" "$transaction" 10 >"$transaction/result.json"; then
    cat "$transaction/result.json"
    failed_id=$(jsonfilter -i "$transaction/start.json" -e '@.result.operation.id')
    if [ -n "$failed_id" ]; then
        cat "/etc/opl-netfleet/package-transactions/$failed_id/journal.json"
        tail -60 "/etc/opl-netfleet/package-transactions/$failed_id/log"
    fi
    exit 1
fi
cycle_id=$(jsonfilter -i "$transaction/start.json" -e '@.result.operation.id')
test -n "$cycle_id"
cycle_journal=/etc/opl-netfleet/package-transactions/$cycle_id/journal.json
test "$(jsonfilter -i "$cycle_journal" -e '@.phase')" = complete
test "$(jsonfilter -i "$cycle_journal" -e '@.drained[0]')" = https-compat
test "$(pidof mihomo)" = "$base_pid"
sha256sum -c "$work/base.sha256" >>"$work/cycle.log"
sha256sum -c "$work/cycle-private.sha256" >>"$work/cycle.log"
wait_intercepting
probe 4 h2; probe 6 h2
cycle_install "$cycle_old"
test "$(pidof mihomo)" = "$base_pid"
sha256sum -c "$work/base.sha256" >>"$work/cycle.log"
sha256sum -c "$work/cycle-private.sha256" >>"$work/cycle.log"
probe 4 h2; probe 6 h2
cycle_install "$cycle_new"
rm /etc/apk/repositories.d/netfleet-cycle.list
guard=$(mktemp -d /tmp/netfleet-https-guard-test.XXXXXX)
mkdir "$guard/old" "$guard/new"
cp "$cycle_old" "$guard/old/"
cp "$cycle_new" "$guard/new/"
cp /tmp/scripts/https-compat/canary-rollback.sh "$guard/guard.sh"
sha256sum /etc/config/netfleet /etc/opl-netfleet/native/run/config.yaml \
 /etc/opl-netfleet/compatibility/config.json /etc/opl-netfleet/compatibility/trust.json \
 /etc/opl-netfleet/compatibility/ca/mitmproxy-ca.pem >"$guard/private.sha256"
sha256sum /usr/libexec/opl-netfleet-compat/control.uc /usr/libexec/opl-netfleet-compat/haproxy \
 /usr/lib/ucode/netfleet_interception.so >"$guard/new-runtime.sha256"
# A failed/partial acceptance writer must not prevent autonomous archive restore.
printf '%s' '{"accepted":true}\n' >"$guard/canary-accepted.json"
ucode - "$guard" "$cycle_old" "$cycle_new" "$base_pid" <<'UC'
import * as fs from 'fs';import {sha256} from 'digest';
function artifact(path) {
 const p=fs.popen('apk adbdump --format json '+path),info=json(p.read('all')).info;
 if(p.close()!=0)die('guard_package_metadata_failed');
 return {version:info.version,artifact:fs.basename(path),sha256:sha256(fs.readfile(path))};
}
const dir=ARGV[0],name='netfleet-https-guard-test';
fs.writefile(dir+'/rollback.json',sprintf('%J',{package:'opl-netfleet-https-compat',timeout_seconds:30,
 core_pid:ARGV[3],intercepting:true,old:artifact(ARGV[1]),new:artifact(ARGV[2])}));
const request=sprintf('%J',{name,instances:{guard:{command:['/bin/sh',dir+'/guard.sh',dir,'guard'],
 stdout:false,stderr:false,term_timeout:5}}});
if(system("ubus call service set '"+replace(request,"'","'\\''")+"'")!=0)die('guard_start_failed');
UC
for attempt in $(seq 1 80); do
 [ -f "$guard/guard-state.json" ] && [ "$(jsonfilter -i "$guard/guard-state.json" -e '@.state')" = restored ] && break
 sleep 2
done
if [ "$(jsonfilter -i "$guard/guard-state.json" -e '@.state')" != restored ]; then
 cat "$guard/guard-state.json" "$guard/guard.log"; exit 1
fi
test "$(apk --no-network query --from installed --format json --fields version opl-netfleet-https-compat | jsonfilter -e '@[0].version')" = "$old_version"
sha256sum -c "$guard/private.sha256"
test "$(pidof mihomo)" = "$base_pid"
probe 4 h2; probe 6 h2
ubus call service delete '{"name":"netfleet-https-guard-test"}' >/dev/null 2>&1 || true
cp "$guard/guard-state.json" "$work/canary-rollback.json"
cycle_install "$cycle_new"
wait "$cycle_stream"
test "$(grep -c '^data:' "$work/package-cycle-events.txt")" = 360
printf '%s\n' 'engine generic Feed update and autonomous exact archive rollback: stable base and private state passed'
set +x
