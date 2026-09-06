#!/bin/sh
set -eu

# Called inside the native qualification guest after shared enable/select.
# Its real DNS, gateway, controller and authenticated probe fixtures remain active.
work=${1:?network proof directory required}
mkdir -p "$work"
chmod 0700 "$work"
service=/etc/init.d/opl-netfleet-core
cp -p "$service" "$work/core-service"
cleanup() {
	cp -p "$work/core-service" "$service"
	rm -f "$work/fail-next-start"
}
trap cleanup EXIT HUP INT TERM

ucode /tmp/tests/network_device.uc "$work" apply >"$work/apply.log" 2>&1
ucode /usr/libexec/opl-netfleet/main.uc status >"$work/status.json"
[ "$(jsonfilter -i "$work/status.json" -e '@.result.runtime.lan_runtime.transparent_proxy_ready')" = true ]
[ "$(jsonfilter -i "$work/status.json" -e '@.result.runtime.lan_runtime.dns_ready')" = true ]
! nft list chain inet netfleet lan_tproxy >/dev/null 2>&1
! nft list chain inet netfleet router_tproxy >/dev/null 2>&1
dig +short +tries=1 +time=3 @127.0.0.1 -p 1053 native-proof.test >"$work/dns.log"
grep -qx 203.0.113.42 "$work/dns.log"

# Fail one official-owner start, then allow the same owner to restore its snapshot.
sed "/^start_service() {/a\\
\tif [ -e '$work/fail-next-start' ]; then rm -f '$work/fail-next-start'; return 1; fi" \
	"$work/core-service" >"$work/failing-service"
chmod 0755 "$work/failing-service"
cp -p "$work/failing-service" "$service"
touch "$work/fail-next-start"
ucode /tmp/tests/network_device.uc "$work" rollback >"$work/rollback.log" 2>&1
cp -p "$work/core-service" "$service"
ucode /tmp/tests/network_device.uc "$work" restore >"$work/restore.log" 2>&1
ucode /usr/libexec/opl-netfleet/main.uc probe >"$work/probe.json"
[ "$(jsonfilter -i "$work/probe.json" -e '@.result.ok')" = true ]
nft list chain inet netfleet lan_tproxy >"$work/lan.nft"
nft list chain inet netfleet router_tproxy >"$work/router.nft"
printf '{"ok":true,"checks":{"network_projection":true,"candidate_zero_mutation":true,"network_apply":true,"listener_authentication":true,"selectors_preserved":true,"revision_guard":true,"invalid_input_zero_mutation":true,"disabled_scope_readiness":true,"private_snapshot_rollback":true,"restored_business_probe":true}}\n'
