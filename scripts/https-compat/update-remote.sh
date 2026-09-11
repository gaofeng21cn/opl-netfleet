#!/bin/sh
# HTTPS engine package only. Kernel lifecycle retains resource ownership.
set -eu
umask 077
mode=${1:?}; stage=${2:?}
case "$stage" in /tmp/netfleet-https-update-*) ;; *) exit 2;; esac
cd "$stage"
main=/usr/libexec/opl-netfleet/main.uc
service=opl-netfleet-https-update
phase() { printf '{"phase":"%s"}\n' "$1" >journal.new; mv journal.new journal.json; }
if [ "$mode" = start ]; then
 sha256sum -c SHA256SUMS >transfer.log 2>&1
 [ ! -e journal.json ]
 exec 8>/var/lock/opl-netfleet-operator.lock
 flock -n 8 || { printf '%s\n' 'update_operator_busy' >&2; exit 1; }
 # Admission precedes procd replacement: another start must not terminate a
 # running transaction before its worker has acquired the operator lock.
 ucode - "$service" <<'UC'
import * as fs from 'fs';
const p=fs.popen('ubus call service list'),state=json(p.read('all'));
if(p.close()||state[ARGV[0]]!=null)die('https_update_already_registered');
UC
 phase prepared
 ucode - "$stage" "$service" <<'UC'
import * as fs from 'fs';
const value={name:ARGV[1],instances:{update:{command:['/usr/bin/timeout','-k','5','600','/bin/sh',ARGV[0]+'/update-remote.sh','run',ARGV[0]],respawn:['3600','2','3'],stdout:false,stderr:false,term_timeout:30}}};
const quote=v=>"'"+replace(v,"'","'\\''")+"'";
if(system('ubus call service add '+quote(sprintf('%J',value))))die('update_start_failed');
UC
 exit 0
fi
[ "$mode" = run ]
exec >>worker.log 2>&1
exec 8>/var/lock/opl-netfleet-operator.lock
flock -w 60 8 || exit 1
printf '%s\n' "$$" >worker.pid
exec 9>/var/lock/opl-netfleet-deploy.lock
old=$(jsonfilter -i request.json -e '@.old')
new=$(jsonfilter -i request.json -e '@.new')
case "$old$new" in *[!a-zA-Z0-9._-]*) exit 2;; esac
[ -f "$old" ] && [ -f "$new" ]
finish() {
 trap - EXIT INT TERM
 ubus call service delete '{"name":"opl-netfleet-https-update"}' >/dev/null 2>&1 || true
}
check_base() {
 sha256sum -c base-before.sha256 >/dev/null &&
 [ "$(pidof mihomo)" = "$(cat base-pid)" ] &&
 ucode "$main" native-gateway-status >gateway.json &&
 [ "$(jsonfilter -i gateway.json -e '@.result.ready')" = true ]
}
install() {
 flock -w 15 9 || return 1
 if ! ucode "$main" plugin-package-drain https-compat >drain.json; then
  # Older engines wait for idle TCP clients without initiating graceful stop.
  # Their failed drain has already revoked leases and entered maintenance.
  if [ "$(jsonfilter -i drain.json -e '@.error')" != healthy_connections_still_draining ]; then flock -u 9;return 1;fi
  if ! ucode - >graceful-drain.json <<'UC'
import * as fs from 'fs';
const quote=v=>"'"+replace(v,"'","'\\''")+"'";
const state=json(fs.readfile('/var/run/opl-netfleet-compat/state.json'));
if(state.maintenance!==true||state.intercepting!==false)die('draining_state_unconfirmed');
const p=fs.popen('ubus call service list'),services=json(p.read('all'));if(p.close())die('draining_service_unconfirmed');
const current=services['opl-netfleet-compat']?.instances?.engine,pid=current?.pid;
if(!current?.running){print('{"drained":true}\n');exit(0);}
if(type(pid)!='int'||pid<=1||fs.readlink(`/proc/${pid}/exe`)!='/usr/libexec/opl-netfleet-compat/haproxy')die('draining_engine_unconfirmed');
function birth(){const s=fs.readfile(`/proc/${pid}/stat`);return s?split(trim(substr(s,rindex(s,') ')+2)),/\s+/)[19]:null;}
const now=()=>+split(fs.readfile('/proc/uptime'),' ')[0],started=birth(),until=now()+30;
if(started!=null){
 if(system('ubus call service signal '+quote(sprintf('%J',{name:'opl-netfleet-compat',instance:'engine',signal:10}))))die('draining_signal_failed');
 while(birth()==started){if(now()>=until)die('healthy_connections_still_draining');sleep(200);}
}
print('{"drained":true}\n');
UC
  then flock -u 9;return 1;fi
  ucode "$main" plugin-package-drain https-compat >drain.json || { flock -u 9;return 1; }
 fi
 # No source/feed resolution and no other package may be downloaded.
 touch package-write-started
 apk --no-network --repositories-file /dev/null ${2:-} add "$stage/$1" 9>&- || { flock -u 9; return 1; }
 ucode "$main" plugin-package-resume https-compat >resume.json || { flock -u 9; return 1; }
 flock -u 9
}
verify() {
 check_base || return 1
 sha256sum -c private-before.sha256 >/dev/null || return 1
 for attempt in $(seq 1 90); do
  ucode "$main" compatibility-get >state.json || return 1
  requested=$(jsonfilter -i state.json -e '@.result.requested')
  # A concurrent user disable is authoritative; never enable on their behalf.
  if [ "$requested" = false ]; then return 0; fi
  [ "$(jsonfilter -i state.json -e '@.result.intercepting')" != true ] || return 0
  sleep 1
 done
 return 1
}
rollback() {
 trap - EXIT INT TERM
 if [ ! -f package-write-started ]; then
  # No APK was attempted. Keep new traffic bypassed and healthy requests alive.
  # Reinstalling the unchanged old package cannot resolve a pending drain.
  if [ "$(jsonfilter -i drain.json -e '@.error' 2>/dev/null)" = healthy_connections_still_draining ]; then phase deferred
  else phase rejected;fi
  finish
  return
 fi
 phase recovering
 if install "$old" --force-reinstall && verify; then phase rolled_back
 else
  # Preserve user intent, revoke only this plugin's new takeover.
  flock -w 15 9 && ucode "$main" plugin-package-drain https-compat >bypass.json || true
  flock -u 9
  phase recovery_failed
 fi
 finish
}
current=$(jsonfilter -i journal.json -e '@.phase')
case "$current" in complete|rolled_back|recovery_failed|rejected|deferred) finish;exit 0;; esac
sha256sum -c SHA256SUMS >transfer.log 2>&1
if [ "$current" != prepared ]; then rollback;exit 0;fi
trap 'phase rejected; finish' EXIT INT TERM
flock -w 15 9
# Guard checks exact APK metadata, installed old bytes, dependencies and base health.
ucode "$stage/update-guard.uc" "$stage"
pidof mihomo >base-pid
sha256sum /etc/config/netfleet /etc/opl-netfleet/native/run/config.yaml >base-before.sha256
find /etc/opl-netfleet/compatibility -type f -exec sha256sum '{}' ';' >private-before.sha256
phase installing
flock -u 9
trap rollback EXIT INT TERM
install "$new"
phase verifying
if [ -f /tmp/netfleet-compat-vm-authorized ] && [ -f hold-acceptance ]; then sleep 120 8>&- 9>&-;fi
# Deliberate VM-only acceptance failure exercises the real rollback consumer.
if [ -f /tmp/netfleet-compat-vm-authorized ] && [ -f reject-acceptance ]; then exit 1;fi
verify
phase complete
finish
