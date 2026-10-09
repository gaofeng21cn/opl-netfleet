#!/bin/sh
# Recover the post-install acceptance window independently of the SSH caller.
# An incomplete package write remains owned by the component transaction.
set -eu
umask 077
stage=${1:?private canary directory required}
mode=${2:-guard}
main=/usr/libexec/opl-netfleet/main.uc
case "$mode" in guard|restore|validate) ;; *) exit 2 ;; esac
ucode - "$stage" <<'UC'
import * as fs from 'fs';
const item=fs.lstat(ARGV[0]);
if(item?.type!='directory'||item.uid!=0||(item.mode&0777)!=0700)die('private_canary_directory_required');
UC
cd "$stage"
state() {
 printf '{"state":"%s"}\n' "$1" >guard-state.json.pending
 mv guard-state.json.pending guard-state.json
}
trap 'result=$?; if [ "$result" -ne 0 ]; then state recovery_failed; fi' EXIT
validate() {
 ucode - "$stage" <<'UC'
import * as fs from 'fs';import {sha256} from 'digest';
const dir=ARGV[0],value=json(fs.readfile(dir+'/rollback.json'));
if(index(['opl-netfleet-https-compat','opl-netfleet-plugin-mihomo'],value.package)<0)die('canary_package_not_allowed');
if(value.world_entry!=null && (type(value.world_entry)!='string'||length(value.world_entry)>1024||
   match(value.world_entry,/[\r\n]/)||!match(value.world_entry,/^(opl-netfleet-https-compat|opl-netfleet-plugin-mihomo)([=<>~!]|$)/)))die('canary_world_entry_invalid');
if(value.engine_identity!=null) {
 const e=value.engine_identity;
 if(type(e.pid)!='int'||e.pid<=1)die('canary_engine_identity_invalid');
 const stat=fs.readfile('/proc/'+e.pid+'/stat');
 if(!stat||split(trim(substr(stat,rindex(stat,') ')+2)),/\s+/)[19]!=e.birth||
    sha256(fs.readfile('/proc/'+e.pid+'/exe')??'')!=e.sha256)die('canary_engine_identity_changed');
}
const companions=value.companions ?? [];
if(type(companions)!='array'||length(companions)>3||length(filter(companions,row=>index(['opl-netfleet-plugin-mihomo','opl-netfleet','opl-netfleet-plugin-network'],row.package)<0)))die('canary_companion_not_allowed');
const names=[value.package,...map(companions,row=>row.package)];
if(length(uniq(sort(names)))!=length(names))die('canary_companion_not_allowed');
const packages=fs.popen("apk --no-network query --from installed --format json --fields name,version 'opl-netfleet-https-compat' 'opl-netfleet-plugin-mihomo' 'opl-netfleet' 'opl-netfleet-plugin-network'");
const installed=json(packages.read('all'));if(packages.close()!=0)die('canary_installed_read_failed');
const version=name=>filter(installed,row=>row.name==name)[0]?.version;
for(let row in companions) if(version(row.package)!=(version(value.package)==value.new.version?row.new.version:row.old.version))die('canary_companion_identity_changed');
for(let row in [value,...companions]) for(let key in ['old','new']) {
 const item=row[key];
 if(!match(item.version,/^[0-9]+\.[0-9]+\.[0-9]+(-r[0-9]+)?$/)||item.artifact!=row.package+'-'+item.version+'.apk'||
    sha256(fs.readfile(dir+'/'+key+'/'+item.artifact)??'')!=item.sha256)die('canary_archive_identity_changed');
}
UC
 apk --no-network verify old/*.apk new/*.apk
 sha256sum -c private.sha256
 test "$(pidof mihomo)" = "$(jsonfilter -i rollback.json -e '@.core_pid')"
 old_version=$(jsonfilter -i rollback.json -e '@.old.version')
 new_version=$(jsonfilter -i rollback.json -e '@.new.version')
 primary=$(jsonfilter -i rollback.json -e '@.package')
 installed=$(apk --no-network query --from installed --format json --fields name,version "$primary" | jsonfilter -e '@[0].version')
 if [ "$installed" = "$new_version" ]; then
  sha256sum -c new-runtime.sha256
 else
  test "$installed" = "$old_version"
 fi
}
accepted() {
 ucode - <<'UC'
import * as fs from 'fs';
const accepted=json(fs.readfile('canary-accepted.json')),rollback=json(fs.readfile('rollback.json'));
if(accepted?.accepted!==true||accepted.sha256!=rollback.new.sha256||accepted.business!==true)die('canary_acceptance_invalid');
UC
}
# Refuse to arm against an obsolete process/configuration snapshot. This is
# read-only and must complete before the caller changes any package or service.
validate >>guard.log 2>&1
if [ "$mode" = validate ]; then exit 0; fi
if [ "$mode" = guard ]; then
 seconds=$(jsonfilter -i rollback.json -e '@.timeout_seconds')
 case "$seconds" in ''|*[!0-9]*) exit 2 ;; esac
 [ "$seconds" -ge 30 ] && [ "$seconds" -le 900 ]
 deadline=$(( $(date +%s) + seconds ))
 state armed
 while :; do
  if [ -f canary-accepted.json ]; then
   if accepted >>guard.log 2>&1; then
    validate >>guard.log 2>&1
    test "$installed" = "$new_version"
    state accepted
    exit 0
   fi
   # A partial or malformed acceptance file must never disarm recovery.
   # Keep the original deadline so a bad writer cannot extend the window.
   state invalid_acceptance_waiting
  fi
  [ "$(date +%s)" -lt "$deadline" ] || break
  sleep 2
 done
fi
state recovery_requested
exec >>guard.log 2>&1
exec 8>/var/lock/opl-netfleet-operator.lock
flock -w 60 8
exec 9>/var/lock/opl-netfleet-deploy.lock
flock -w 60 9
if [ -f /etc/opl-netfleet/package-transactions/pending.json ]; then
 state pending_transaction_recovery_required
 /etc/init.d/opl-netfleet-update-recovery start 9>&-
 exit 0
fi
validate
if [ "$installed" = "$old_version" ]; then
 state original_package_retained
 exit 0
fi
test "$installed" = "$new_version"
sha256sum -c new-runtime.sha256
state restoring
transaction_id=$(jsonfilter -i /etc/opl-netfleet/package-transactions/request.json -e '@.id')
case "$transaction_id" in ''|*[!a-f0-9]*) exit 1 ;; esac
[ "${#transaction_id}" = 32 ]
transaction=/etc/opl-netfleet/package-transactions/$transaction_id
ucode - "$stage" "$transaction" <<'UC'
import * as fs from 'fs';import {sha256} from 'digest';
const wanted=json(fs.readfile(ARGV[0]+'/rollback.json')), dir=ARGV[1], state=json(fs.readfile(dir+'/journal.json'));
const rows=[wanted,...(wanted.companions ?? [])];
if(state?.phase!='complete'||state.before?.runtime_retained!==true||
 sprintf('%J',sort(state.names??[]))!=sprintf('%J',sort(map(rows,row=>row.package))))die('canary_transaction_identity_changed');
for(let row in rows) if(state.versions[row.package]!=row.old.version||state.candidates[row.package]!=row.new.version||
 sha256(fs.readfile(dir+'/old/'+row.old.artifact))!=row.old.sha256||
 sha256(fs.readfile(dir+'/new/'+row.new.artifact))!=row.new.sha256)die('canary_transaction_identity_changed');
UC
ucode "$transaction/code/plugins/components/recover.uc" rollback "$transaction_id" >recovery-request.json
flock -u 9
for attempt in $(seq 1 90); do
 phase=$(jsonfilter -i "$transaction/journal.json" -e '@.phase')
 [ "$phase" != rolled_back ] || break
 sleep 1
done
test "$phase" = rolled_back
test ! -e /etc/opl-netfleet/package-transactions/pending.json
validate
sha256sum -c private.sha256
test "$(pidof mihomo)" = "$(jsonfilter -i rollback.json -e '@.core_pid')"
installed=$(apk --no-network query --from installed --format json --fields name,version "$primary" | jsonfilter -e '@[0].version')
test "$installed" = "$old_version"
flock -u 9
if [ "$(jsonfilter -i rollback.json -e '@.plugin_disabled')" = true ]; then
 ucode "$main" plugins-system-get >restored-plugins.json
 ucode - restored-plugins.json <<'UC'
import * as fs from 'fs';
const value=json(fs.readfile(ARGV[0])).result;
const enabled={...value.defaults.enabled,...value.config.enabled};
if(enabled['https-compat']!==false)die('canary_disabled_state_changed');
UC
 state restored
 exit 0
fi
intercepting=$(jsonfilter -i rollback.json -e '@.intercepting')
for attempt in $(seq 1 60); do
 ucode "$main" compatibility-get >restored.json
 [ "$(jsonfilter -i restored.json -e '@.ok')" = true ] || exit 1
 [ "$(jsonfilter -i restored.json -e '@.result.intercepting')" = "$intercepting" ] && break
 sleep 2
done
test "$(jsonfilter -i restored.json -e '@.result.intercepting')" = "$intercepting"
state restored
