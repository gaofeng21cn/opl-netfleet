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
  apk --no-network --repositories-file /dev/null add "$1" 9>&-
 ) >>"$work/cycle.log" 2>&1
 test "$(pidof mihomo)" = "$base_pid"
 sha256sum -c "$work/base.sha256" >>"$work/cycle.log"
 sha256sum -c "$work/cycle-private.sha256" >>"$work/cycle.log"
 wait_intercepting
 probe 4 h2; probe 6 h2
}
# Start from the old signed engine, then exercise the actual update worker.
cycle_install "$cycle_old"
cycle_transaction() {
 transaction=$(mktemp -d /tmp/netfleet-https-update-test.XXXXXX)
 cp "$cycle_old" "$cycle_new" "$transaction/"
 cp /tmp/scripts/https-compat/update-remote.sh /tmp/scripts/https-compat/update-guard.uc "$transaction/"
 ucode - "$transaction" "$2" "$3" <<'UC'
import * as fs from 'fs';
fs.writefile(ARGV[0]+'/request.json',sprintf('%J',{old:fs.basename(ARGV[1]),new:fs.basename(ARGV[2])}));
UC
 (cd "$transaction"; sha256sum *.apk request.json update-remote.sh update-guard.uc >SHA256SUMS)
 case "$1" in reject) touch "$transaction/reject-acceptance";; kill) touch "$transaction/hold-acceptance";; esac
 sh "$transaction/update-remote.sh" start "$transaction"
 if [ "$1" = kill ]; then
  for attempt in $(seq 1 90); do
   [ "$(jsonfilter -i "$transaction/journal.json" -e '@.phase')" != verifying ] || break
   sleep 1
  done
  test "$(jsonfilter -i "$transaction/journal.json" -e '@.phase')" = verifying
  # SIGKILL the worker shell; procd must respawn it and recover old bytes.
  ubus call service list '{"name":"opl-netfleet-https-update"}' >"$transaction/procd.json"
  test "$(jsonfilter -i "$transaction/procd.json" -e '@["opl-netfleet-https-update"].instances.update.respawn.threshold')" = 3600
  test "$(jsonfilter -i "$transaction/procd.json" -e '@["opl-netfleet-https-update"].instances.update.respawn.timeout')" = 2
  worker_shell=$(cat "$transaction/worker.pid")
  test -n "$worker_shell"
  kill -KILL "$worker_shell"
 fi
 for attempt in $(seq 1 150); do
  result=$(jsonfilter -i "$transaction/journal.json" -e '@.phase')
  case "$result" in complete|rolled_back|recovery_failed|rejected) break;; esac
  sleep 1
 done
 if [ "$1" = accept ]; then test "$result" = complete; else test "$result" = rolled_back;fi
 test "$(pidof mihomo)" = "$base_pid"
 sha256sum -c "$work/base.sha256" >>"$work/cycle.log"
 sha256sum -c "$work/cycle-private.sha256" >>"$work/cycle.log"
 wait_intercepting
 probe 4 h2;probe 6 h2
}
cycle_transaction reject "$cycle_old" "$cycle_new"
cycle_transaction accept "$cycle_old" "$cycle_new"
cycle_transaction kill "$cycle_new" "$cycle_old"
echo 'engine package cycle: actual acceptance rollback, upgrade, interrupted-worker recovery, stable base and private state passed'
