#!/bin/sh
# Sourced by the live network fixture, with the base already forwarding.
test -f /tmp/netfleet-compat-vm-authorized
cycle=/tmp/compat-runtime/upgrade.json
test -f "$cycle"
ucode - "$cycle" <<'UC'
import * as fs from 'fs';import {sha256} from 'digest';
const value=json(fs.readfile(ARGV[0]));
for(let key in ['old','new']) {
 const item=value[key];
 if(!match(item.file,/^(rollback\/)?[a-zA-Z0-9_.-]+\.apk$/)||sha256(fs.readfile('/tmp/compat-runtime/'+item.file))!=item.sha256)die('upgrade_artifact_invalid');
}
UC
cycle_old=/tmp/compat-runtime/$(jsonfilter -i "$cycle" -e '@.old.file')
cycle_new=/tmp/compat-runtime/$(jsonfilter -i "$cycle" -e '@.new.file')
sha256sum /etc/opl-netfleet/compatibility/config.json /etc/opl-netfleet/compatibility/trust.json \
 /etc/opl-netfleet/compatibility/ca/mitmproxy-ca.pem >"$work/cycle-private.sha256"
cycle_install() {
 (
  exec 9>/var/lock/opl-netfleet-deploy.lock
  flock -w 10 9
  # Explicit owner admission precedes APK: a rejected drain cannot write files.
  ucode /usr/libexec/opl-netfleet/main.uc plugin-package-drain https-compat >"$work/cycle-drain.json"
  apk --no-network --repositories-file /dev/null --force-reinstall add "$1" 9>&-
 ) >>"$work/cycle.log" 2>&1
 test "$(pidof mihomo)" = "$base_pid"
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
uhttpd -f -p 127.0.0.1:19984 -h "$transaction/feed" >"$transaction/http.log" 2>&1 &
cycle_server=$!
printf 'http://127.0.0.1:19984/packages.adb\n' >/etc/apk/repositories.d/netfleet-cycle.list
apk --timeout 10 update >>"$work/cycle.log" 2>&1
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
sh "$transaction/run.sh" "$transaction" 10 >"$transaction/result.json"
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
kill "$cycle_server"
wait "$cycle_server" || true
rm /etc/apk/repositories.d/netfleet-cycle.list
printf '%s\n' 'engine generic Feed update: APK plan, resource drain, stable base and private state passed'
