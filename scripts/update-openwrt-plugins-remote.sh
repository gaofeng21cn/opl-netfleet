#!/bin/sh
# Called only with a verified private stage by update-openwrt-plugins.py.
set -eu
umask 077
stage=${1:?private stage required}
seconds=${2:?observation window required}
case "$seconds" in ''|*[!0-9]*) exit 2 ;; esac
[ "$seconds" -ge 10 ] && [ "$seconds" -le 1800 ]
main=/usr/libexec/opl-netfleet/main.uc
# An operator window serializes cooperating deployment/canary executors without
# holding the network mutation lock during normal supervisor observation.
exec 8>/var/lock/opl-netfleet-operator.lock
flock -n 8 || { printf '%s\n' '{"ok":false,"error":"operator_window_busy"}'; exit 1; }
cd "$stage"
sha256sum -c SHA256SUMS >transfer.log 2>&1
# Execute the qualified transaction implementation with the target's actual
# plugins and composition. It snapshots this code before replacing itself.
cp -R /usr/libexec/opl-netfleet runtime
cp -R components/. runtime/plugins/components/
cp /usr/share/opl-netfleet/system.json runtime/system.json
flock -w 10 /var/lock/opl-netfleet-deploy.lock \
 ucode "$stage/runtime/main.uc" components-install "$stage" >start.json
id=$(jsonfilter -i start.json -e '@.result.operation.id')
case "$id" in ''|*[!a-f0-9]*) cat start.json; exit 1 ;; esac
[ "${#id}" = 32 ]
printf '{"id":"%s","phase":"installing"}\n' "$id"
transaction=/etc/opl-netfleet/package-transactions/$id
for attempt in $(seq 1 300); do
 phase=$(jsonfilter -i "$transaction/journal.json" -e '@.phase' 2>/dev/null || true)
 case "$phase" in complete) break ;; rolled_back) printf '{"ok":false,"id":"%s","error":"update_rolled_back"}\n' "$id"; exit 1 ;; esac
 ucode "$main" components-operation >operation.json 2>/dev/null || true
 state=$(jsonfilter -i operation.json -e '@.result.packages.state' 2>/dev/null || true)
 case "$state" in failed|interrupted) cat operation.json; exit 1 ;; esac
 sleep 1
done
[ "$phase" = complete ] || { printf '{"ok":false,"id":"%s","error":"update_result_pending"}\n' "$id"; exit 1; }
# Normal scheduler cycles continue here. Browser navigation can be inspected in
# the same operator window; write actions are separate explicit acceptance work.
observed=0
ucode "$stage/observe.uc" "$seconds" "$stage/acceptance.json" || observed=$?
[ ! -f acceptance.json ] || cat acceptance.json
exit "$observed"
