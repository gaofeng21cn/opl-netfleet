#!/bin/sh
# Isolated QEMU only: synthetic endpoints behind the real TProxy fixture.
set -eu
port=${1:?fixture TLS port}
work=${2:?private results directory}
mkdir -p "$work"
main=/usr/libexec/opl-netfleet/main.uc
pid=$(ubus call service list '{"name":"opl-netfleet-core"}' | jsonfilter -e '@["opl-netfleet-core"].instances.core.pid')
[ -n "$pid" ]
pids=''
for family in 4 6; do
 destination=198.19.0.1
 [ "$family" != 6 ] || destination='[2001:db8:2::1]'
 for copy in 1 2; do
  ip netns exec nf-client curl -q -fsS --noproxy '*' --connect-timeout 3 --max-time 60 \
   --cacert /tmp/local-probe.crt --resolve "netfleet-probe.test:$port:$destination" \
   "https://netfleet-probe.test:$port/native-workload/payload" -o "$work/payload-$family-$copy" \
   --write-out '%{json}' >"$work/transfer-$family-$copy.json" &
  pids="$pids $!"
 done
 ip netns exec nf-client curl -q -fsSN --noproxy '*' --connect-timeout 3 --max-time 45 \
  --cacert /tmp/local-probe.crt --resolve "netfleet-probe.test:$port:$destination" \
  "https://netfleet-probe.test:$port/native-workload/events" >"$work/events-$family" &
 pids="$pids $!"
done
# Control-plane reads run while the sustained streams and bulk transfers are active.
for round in 1 2 3 4 5; do
 ucode "$main" status >"$work/status-$round.json"
 [ "$(jsonfilter -i "$work/status-$round.json" -e '@.result.runtime.lan_runtime.dns_ready')" = true ]
done
for child in $pids; do wait "$child"; done
for family in 4 6; do
 [ "$(grep -c '^data:' "$work/events-$family")" = 30 ]
 for copy in 1 2; do
  [ "$(wc -c <"$work/payload-$family-$copy")" = 8388608 ]
  [ "$(sha256sum "$work/payload-$family-$copy" | cut -d " " -f 1)" = "bbaa115f96618af1795a163c141952220f6402261f03093eecd0488d3584c82a" ]
 done
done
[ "$(ubus call service list '{"name":"opl-netfleet-core"}' | jsonfilter -e '@["opl-netfleet-core"].instances.core.pid')" = "$pid" ]
printf '{"ok":true,"bytes_per_transfer":8388608,"concurrent_transfers":4,"stream_seconds":30,"families":[4,6],"status_reads":5,"core_pid_unchanged":true}\n'
