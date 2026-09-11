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
# Start from the old signed engine, then exercise the actual update worker.
cycle_install "$cycle_old"
cycle_transaction() {
 transaction=$(mktemp -d /tmp/netfleet-https-update-test.XXXXXX)
 cp "$cycle_old" "$cycle_new" "$transaction/"
 cp /tmp/scripts/https-compat/update-remote.sh /tmp/scripts/https-compat/update-guard.uc "$transaction/"
 ucode - "$transaction" "$2" "$3" "$1" <<'UC'
import * as fs from 'fs';
const base=json(fs.readfile('/tmp/compat-base-identity.json'));
if(ARGV[3]=='bad-base')base.runtime_sha256['/usr/libexec/opl-netfleet/main.uc']=sprintf('%064d',0);
fs.writefile(ARGV[0]+'/request.json',sprintf('%J',{old:fs.basename(ARGV[1]),new:fs.basename(ARGV[2]),base_runtime:base.runtime_sha256}));
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
  competing=$(mktemp -d /tmp/netfleet-https-update-test.XXXXXX)
  cp "$transaction"/*.apk "$transaction/request.json" "$transaction/SHA256SUMS" "$transaction"/update-* "$competing/"
  if sh "$competing/update-remote.sh" start "$competing" >"$competing/start.log" 2>&1; then exit 1; fi
  test ! -f "$competing/journal.json"
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
 case "$1" in accept) test "$result" = complete;; bad-base) test "$result" = rejected;; *) test "$result" = rolled_back;; esac
 # A terminal journal can precede the worker releasing its operator lock.
 # Wait for the old service to disappear before starting another transaction.
 for attempt in $(seq 1 20); do
  ubus call service list '{"name":"opl-netfleet-https-update"}' >"$transaction/cleanup.json"
  if ! jsonfilter -i "$transaction/cleanup.json" -e '@["opl-netfleet-https-update"].instances' | grep -q .; then break; fi
  sleep 1
 done
 ! jsonfilter -i "$transaction/cleanup.json" -e '@["opl-netfleet-https-update"].instances' | grep -q .
 test "$(pidof mihomo)" = "$base_pid"
 sha256sum -c "$work/base.sha256" >>"$work/cycle.log"
 sha256sum -c "$work/cycle-private.sha256" >>"$work/cycle.log"
 wait_intercepting
 probe 4 h2;probe 6 h2
}
cycle_transaction bad-base "$cycle_old" "$cycle_new"
# A client can keep its TLS connection alive across the old controller's whole
# 30-second drain window. Exercise the installer bridge with the old signed APK.
mkfifo "$work/keepalive.in"
timeout -k 1 120 ip netns exec nfcompat-client openssl s_client -quiet -ign_eof \
 -connect 198.51.100.10:443 -servername wire.example -verify_return_error \
 -CAfile "$work/client-ca.pem" <"$work/keepalive.in" >"$work/keepalive.out" 2>"$work/keepalive.log" &
keepalive_client=$!
timeout -k 1 120 sh -c 'while true; do printf "GET /wire HTTP/1.1\r\nHost: wire.example\r\n\r\n"; sleep 3; done' >"$work/keepalive.in" &
keepalive_sender=$!
for attempt in $(seq 1 20); do grep -q wire-ok "$work/keepalive.out" && break; sleep 1; done
grep -q wire-ok "$work/keepalive.out"
kill -0 "$keepalive_client"
cycle_transaction reject "$cycle_old" "$cycle_new"
! kill -0 "$keepalive_client" 2>/dev/null
wait "$keepalive_client" || true
kill "$keepalive_sender" 2>/dev/null || true
wait "$keepalive_sender" || true
rm "$work/keepalive.in"
cycle_transaction accept "$cycle_old" "$cycle_new"
if [ -n "$probe_port" ]; then
 wire -fsSN 'https://wire.example/compat-wire/events' >"$work/drain-events.txt" &
 draining_stream=$!
 for attempt in $(seq 1 20); do grep -q '^data: 0$' "$work/drain-events.txt" && break; sleep 0.1; done
 grep -q '^data: 0$' "$work/drain-events.txt"
 kill -0 "$draining_stream"
fi
cycle_transaction kill "$cycle_new" "$cycle_old"
if [ -n "${draining_stream:-}" ]; then
 wait "$draining_stream"
 test "$(grep -c '^data:' "$work/drain-events.txt")" = 30
fi
echo 'engine package cycle: actual acceptance rollback, upgrade, interrupted-worker recovery, stable base and private state passed'
