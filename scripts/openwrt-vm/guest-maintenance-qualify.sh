#!/bin/sh
set -eu
umask 077
work=/tmp/netfleet-maintenance-fixture
main=/usr/libexec/opl-netfleet/main.uc
gateway=/usr/libexec/opl-netfleet/application/native_gateway.uc
test -f /tmp/netfleet-setup-vm-authorized
test "$(jsonfilter -i /etc/opl-netfleet/backend.json -e '@.kind')" = native-mihomo
test -f /etc/opl-netfleet/policy.json
mkdir -p "$work"
stage=active
finish() {
	rc=$?
	trap - EXIT INT TERM
	if [ "$rc" -ne 0 ]; then
		echo "Maintenance qualification failed at: $stage" >&2
		for path in "$work"/*.log; do [ ! -f "$path" ] || tail -60 "$path" >&2; done
	fi
	exit "$rc"
}
trap finish EXIT INT TERM
ucode /tmp/tests/maintenance_device.uc >"$work/active.log" 2>&1
ucode "$main" probe >"$work/probe-result.json"
[ "$(jsonfilter -i "$work/probe-result.json" -e '@.result.ok')" = true ]
stage=stopped
supervisor_running=0
/etc/init.d/opl-netfleet running >/dev/null 2>&1 && supervisor_running=1
/etc/init.d/opl-netfleet stop
/etc/init.d/opl-netfleet-core stop
for attempt in $(seq 1 15); do
	ucode "$gateway" status >"$work/stopped-result.json"
	[ "$(jsonfilter -i "$work/stopped-result.json" -e '@.result.core_running')" != false ] || break
	sleep 1
done
[ "$(jsonfilter -i "$work/stopped-result.json" -e '@.result.clean')" = true ]
ucode /tmp/tests/maintenance_device.uc stopped >"$work/stopped.log" 2>&1
stage=resume
/etc/init.d/opl-netfleet-core start
for attempt in $(seq 1 20); do
	ucode "$gateway" status >"$work/resume-result.json"
	[ "$(jsonfilter -i "$work/resume-result.json" -e '@.result.ready')" != true ] || break
	sleep 1
done
[ "$(jsonfilter -i "$work/resume-result.json" -e '@.result.ready')" = true ]
[ "$supervisor_running" != 1 ] || /etc/init.d/opl-netfleet start
ucode "$main" probe >"$work/final-probe-result.json"
[ "$(jsonfilter -i "$work/final-probe-result.json" -e '@.result.ok')" = true ]
stage=complete
printf '%s\n' '{"ok":true,"checks":{"maintenance_profiles_json_yaml":true,"maintenance_profile_revision":true,"maintenance_backup_whitelist":true,"maintenance_backup_active":true,"maintenance_backup_stopped":true,"maintenance_restore_rollback":true,"maintenance_private_uci_preserved":true,"maintenance_core_restart_reload":true,"maintenance_logs_without_controller":true,"maintenance_diagnostic_redaction":true}}' >"$work/qualification.json"
