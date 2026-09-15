#!/bin/sh
# Called only with a verified private stage by update-openwrt-plugins.py.
set -eu
umask 077
stage=${1:?private stage required}
seconds=${2:-${NETFLEET_PLUGIN_OBSERVE_SECONDS:-10}}
case "$seconds" in ''|*[!0-9]*) exit 2 ;; esac
[ "$seconds" -ge 10 ] && [ "$seconds" -le 1800 ]
now_ms() { awk '{ printf "%.0f\n", $1 * 1000 }' /proc/uptime; }
started_ms=$(now_ms)
main=/usr/libexec/opl-netfleet/main.uc
# An operator window serializes cooperating deployment/canary executors without
# holding the network mutation lock during normal supervisor observation.
exec 8>/var/lock/opl-netfleet-operator.lock
flock -n 8 || { printf '%s\n' '{"ok":false,"error":"operator_window_busy"}'; exit 1; }
cd "$stage"
sha256sum -c SHA256SUMS >transfer.log 2>&1
prepared_ms=$(now_ms)
if [ -f feed-request.json ]; then
 # The installed owner validates the confirmed APK plan under the shared lock.
 # No shipped controller copy, archive selection or plugin-specific worker.
 root=/etc/opl-netfleet/package-transactions
 mkdir -p "$root/archives"
 chmod 700 "$root/archives"
 for file in old/*.apk; do
  [ -f "$file" ] || continue
  apk --no-network verify "$file" >>transfer.log 2>&1
  target="$root/archives/${file##*/}"
  if [ -e "$target" ]; then cmp -s "$file" "$target"; else cp "$file" "$target"; fi
 done
 flock -w 10 /var/lock/opl-netfleet-deploy.lock \
  ucode "$main" components-plugin "$stage/feed-request.json" >start.json
else
 # Qualified offline bootstrap is reserved for repairing an older default
 # components entry. Ordinary updates always use the installed Feed owner above.
 cp -R /usr/libexec/opl-netfleet runtime
 cp -R components/. runtime/plugins/components/
 cp /usr/share/opl-netfleet/system.json runtime/system.json
 flock -w 10 /var/lock/opl-netfleet-deploy.lock \
  ucode "$stage/runtime/main.uc" components-install "$stage" >start.json
fi
id=$(jsonfilter -i start.json -e '@.result.operation.id')
case "$id" in ''|*[!a-f0-9]*) cat start.json; exit 1 ;; esac
[ "${#id}" = 32 ]
printf '{"id":"%s","phase":"installing"}\n' "$id"
transaction=/etc/opl-netfleet/package-transactions/$id
# Poll the retained transaction owner; installed code can be under maintenance.
for attempt in $(seq 1 300); do
 phase=$(jsonfilter -i "$transaction/journal.json" -e '@.phase' 2>/dev/null || true)
 case "$phase" in complete) break ;; failed|rolled_back) printf '{"ok":false,"id":"%s","error":"update_rolled_back"}\n' "$id"; exit 1 ;; esac
 ucode "$transaction/code/plugins/components/recover.uc" operation >operation.json 2>/dev/null || true
 state=$(jsonfilter -i operation.json -e '@.result.packages.state' 2>/dev/null || true)
 case "$state" in failed|interrupted) cat operation.json; exit 1 ;; esac
 sleep 1
done
[ "$phase" = complete ] || { printf '{"ok":false,"id":"%s","error":"update_result_pending"}\n' "$id"; exit 1; }
# Normal scheduler cycles continue here. Browser navigation can be inspected in
# the same operator window; write actions are separate explicit acceptance work.
installed_ms=$(now_ms)
observed=0
ucode "$stage/observe.uc" "$seconds" "$stage/acceptance.json" || observed=$?
[ ! -f acceptance.json ] || cat acceptance.json
finished_ms=$(now_ms)
printf '{"device_timings":{"prepare_ms":%s,"transaction_ms":%s,"observe_ms":%s,"total_ms":%s}}\n' \
 "$((prepared_ms - started_ms))" "$((installed_ms - prepared_ms))" "$((finished_ms - installed_ms))" "$((finished_ms - started_ms))"
exit "$observed"
