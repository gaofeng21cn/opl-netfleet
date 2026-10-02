#!/bin/sh
# Recover the post-install acceptance window independently of the SSH caller.
# An incomplete package write remains owned by the component transaction.
set -eu
umask 077
stage=${1:?private canary directory required}
mode=${2:-guard}
main=/usr/libexec/opl-netfleet/main.uc
ucode - "$stage" <<'UC'
import * as fs from 'fs';
const item=fs.lstat(ARGV[0]);
if(item?.type!='directory'||item.uid!=0||(item.mode&0777)!=0700)die('private_canary_directory_required');
UC
cd "$stage"
if [ "$mode" = guard ]; then
 seconds=$(jsonfilter -i rollback.json -e '@.timeout_seconds')
 case "$seconds" in ''|*[!0-9]*) exit 2 ;; esac
 [ "$seconds" -ge 30 ] && [ "$seconds" -le 900 ]
 deadline=$(( $(date +%s) + seconds ))
 printf '%s\n' '{"state":"armed"}' >guard-state.json
 while [ ! -f canary-accepted.json ]; do
  [ "$(date +%s)" -lt "$deadline" ] || break
  sleep 2
 done
 if [ -f canary-accepted.json ]; then
  ucode - <<'UC'
import * as fs from 'fs';
const accepted=json(fs.readfile('canary-accepted.json')),rollback=json(fs.readfile('rollback.json'));
if(accepted?.accepted!==true||accepted.sha256!=rollback.new.sha256||accepted.business!==true)die('canary_acceptance_invalid');
UC
  printf '%s\n' '{"state":"accepted"}' >guard-state.json
  exit 0
 fi
elif [ "$mode" != restore ]; then
 exit 2
fi
exec >>guard.log 2>&1
exec 8>/var/lock/opl-netfleet-operator.lock
flock -w 60 8
exec 9>/var/lock/opl-netfleet-deploy.lock
flock -w 60 9
if [ -f /etc/opl-netfleet/package-transactions/pending.json ]; then
 printf '%s\n' '{"state":"pending_transaction_recovery_required"}' >guard-state.json
 /etc/init.d/opl-netfleet-update-recovery start 9>&-
 exit 1
fi
ucode - "$stage" <<'UC'
import * as fs from 'fs';import {sha256} from 'digest';
const dir=ARGV[0],value=json(fs.readfile(dir+'/rollback.json'));
if(value.package!='opl-netfleet-https-compat')die('canary_package_not_allowed');
for(let key in ['old','new']) {
 const item=value[key];
 if(!match(item.version,/^[0-9]+\.[0-9]+\.[0-9]+(-r[0-9]+)?$/)||item.artifact!=value.package+'-'+item.version+'.apk'||
    sha256(fs.readfile(dir+'/'+key+'/'+item.artifact)??'')!=item.sha256)die('canary_archive_identity_changed');
}
UC
apk --no-network verify old/*.apk new/*.apk
sha256sum -c private.sha256
test "$(pidof mihomo)" = "$(jsonfilter -i rollback.json -e '@.core_pid')"
old_version=$(jsonfilter -i rollback.json -e '@.old.version')
new_version=$(jsonfilter -i rollback.json -e '@.new.version')
installed=$(apk --no-network query --from installed --format json --fields name,version opl-netfleet-https-compat | jsonfilter -e '@[0].version')
if [ "$installed" = "$old_version" ]; then
 printf '%s\n' '{"state":"original_package_retained"}' >guard-state.json
 exit 0
fi
test "$installed" = "$new_version"
sha256sum -c new-runtime.sha256
printf '%s\n' '{"state":"restoring"}' >guard-state.json
NETFLEET_PACKAGE_RESTORE=1 ucode "$main" plugin-package-drain https-compat >drain.json
test "$(jsonfilter -i drain.json -e '@.ok')" = true
NETFLEET_PACKAGE_RESTORE=1 apk --preserve-env --no-network --repositories-file /dev/null --force-reinstall add old/*.apk 9>&-
sha256sum -c private.sha256
test "$(pidof mihomo)" = "$(jsonfilter -i rollback.json -e '@.core_pid')"
installed=$(apk --no-network query --from installed --format json --fields name,version opl-netfleet-https-compat | jsonfilter -e '@[0].version')
test "$installed" = "$old_version"
flock -u 9
intercepting=$(jsonfilter -i rollback.json -e '@.intercepting')
for attempt in $(seq 1 60); do
 ucode "$main" compatibility-get >restored.json
 [ "$(jsonfilter -i restored.json -e '@.ok')" = true ] || exit 1
 [ "$(jsonfilter -i restored.json -e '@.result.intercepting')" = "$intercepting" ] && break
 sleep 2
done
test "$(jsonfilter -i restored.json -e '@.result.intercepting')" = "$intercepting"
printf '%s\n' '{"state":"restored"}' >guard-state.json
