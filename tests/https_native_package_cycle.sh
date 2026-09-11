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
# Exact old/new versions; no other installed package is in the transaction.
cycle_install "$cycle_old"
cycle_install "$cycle_new"
# Exercise a rejected acceptance by restoring the old signed engine, then retry.
cycle_install "$cycle_old"
cycle_install "$cycle_new"
echo 'engine package cycle: old/new, acceptance rollback, retry, stable base and private state passed'
