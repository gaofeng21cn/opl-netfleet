#!/bin/sh
set -eu
umask 077
work=/tmp/netfleet-maintenance-fixture
main=/usr/libexec/opl-netfleet/main.uc
gateway=/usr/libexec/opl-netfleet/main.uc
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
stage=composition
ucode -e '
import * as fs from "fs";
import { execute } from "/usr/libexec/opl-netfleet/kernel/host.uc";
import { create } from "/usr/libexec/opl-netfleet/adapters/openwrt.uc";
const root = "/usr/libexec/opl-netfleet", options = { adapter: create() };
const path = "/tmp/netfleet-maintenance-fixture/composition-request.json";
function check(value, label) { if (!value) die(label); };
function get() { const value = execute(["plugins-system-get"], root, options); check(value.ok, sprintf("%J", value)); return value.result; };
function apply(config, revision) {
  check(fs.writefile(path, sprintf("%J", { request: { config, revision, confirm: true } })) && fs.chmod(path, 0600), "private composition request");
  const result = execute(["plugins-system-apply", path], root, options);
  check(result.ok, sprintf("%J", result));
};
const original = get(), config = json(sprintf("%J", original.config));
config.config = { ...(config.config ?? {}), models: { qualification: true } };
apply(config, original.revision);
check(get().config.config.models.qualification == true, "active composition readback");
apply(original.config, get().revision);
fs.unlink(path);
print("active_composition_roundtrip_ok\n");
' >"$work/composition.log" 2>&1
ucode "$main" probe >"$work/probe-result.json"
[ "$(jsonfilter -i "$work/probe-result.json" -e '@.result.ok')" = true ]
stage=stopped
supervisor_running=0
/etc/init.d/opl-netfleet running >/dev/null 2>&1 && supervisor_running=1
/etc/init.d/opl-netfleet stop
/etc/init.d/opl-netfleet-core stop
for attempt in $(seq 1 15); do
	ucode "$gateway" native-gateway-status >"$work/stopped-result.json"
	[ "$(jsonfilter -i "$work/stopped-result.json" -e '@.result.core_running')" != false ] || break
	sleep 1
done
[ "$(jsonfilter -i "$work/stopped-result.json" -e '@.result.clean')" = true ]
ucode /tmp/tests/maintenance_device.uc stopped >"$work/stopped.log" 2>&1
stage=resume
/etc/init.d/opl-netfleet-core start
for attempt in $(seq 1 20); do
	ucode "$gateway" native-gateway-status >"$work/resume-result.json"
	[ "$(jsonfilter -i "$work/resume-result.json" -e '@.result.ready')" != true ] || break
	sleep 1
done
[ "$(jsonfilter -i "$work/resume-result.json" -e '@.result.ready')" = true ]
[ "$supervisor_running" != 1 ] || /etc/init.d/opl-netfleet start
ucode "$main" probe >"$work/final-probe-result.json"
[ "$(jsonfilter -i "$work/final-probe-result.json" -e '@.result.ok')" = true ]
stage=complete
printf '%s\n' '{"ok":true,"checks":{"maintenance_profiles_json_yaml":true,"maintenance_profile_revision":true,"maintenance_backup_whitelist":true,"maintenance_backup_active":true,"maintenance_backup_stopped":true,"maintenance_restore_rollback":true,"maintenance_private_uci_preserved":true,"maintenance_core_restart_reload":true,"maintenance_logs_without_controller":true,"maintenance_diagnostic_redaction":true}}' >"$work/qualification.json"
