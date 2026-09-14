#!/bin/sh
set -eu

root_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
runtime_dir=$root_dir/openwrt/files/usr/libexec/opl-netfleet
ucode_bin=${UCODE:-ucode}

if command -v "$ucode_bin" >/dev/null 2>&1; then
	# A runtime that keeps its modules outside the default search path — the
	# pinned macOS build, for example — passes the pattern through UCODE_LIB.
	if [ -n "${UCODE_LIB:-}" ]; then
		set -- -L "$UCODE_LIB"
	else
		set --
	fi
	# These contracts drive the OpenWrt host itself: libuci is an OpenWrt C
	# module and process identity reads /proc. Every other contract in this
	# list is portable and still gates shared business code wherever UCode
	# runs, including the pinned macOS runtime.
	if "$ucode_bin" "$@" -e 'import { cursor } from "uci"; import * as fs from "fs"; if (fs.readfile("/proc/self/stat") == null) die("openwrt_host_primitives_absent");' >/dev/null 2>&1; then
		openwrt_host=1
	else
		openwrt_host=0
	fi
	"$ucode_bin" "$@" -c -s -o /tmp/opl-netfleet-main.uc "$runtime_dir/main.uc"
	rm -f /tmp/opl-netfleet-main.uc
	"$ucode_bin" "$@" "$root_dir/tests/scope_contract.uc"
	"$ucode_bin" "$@" "$root_dir/tests/host_adapter_contract.uc"
	"$ucode_bin" "$@" "$root_dir/tests/composition_contract.uc"
	"$ucode_bin" "$@" "$root_dir/tests/compiler_contract.uc"
	"$ucode_bin" "$@" "$root_dir/tests/selection_contract.uc"
	"$ucode_bin" "$@" "$root_dir/tests/portable_services_contract.uc"
	"$ucode_bin" "$@" "$root_dir/tests/storage_contract.uc"
	"$ucode_bin" "$@" "$root_dir/tests/status_contract.uc"
	"$ucode_bin" "$@" "$root_dir/tests/evidence_contract.uc"
	"$ucode_bin" "$@" "$root_dir/tests/activation_contract.uc"
	"$ucode_bin" "$@" "$root_dir/tests/operating_mode_contract.uc"
	"$ucode_bin" "$@" "$root_dir/tests/path_activation_contract.uc"
	"$ucode_bin" "$@" "$root_dir/tests/gateway_cleanup_contract.uc"
	"$ucode_bin" "$@" "$root_dir/tests/events_contract.uc"
	"$ucode_bin" "$@" "$root_dir/tests/subscription_contract.uc"
	"$ucode_bin" "$@" "$root_dir/tests/refresh_history_contract.uc"
	"$ucode_bin" "$@" "$root_dir/tests/config_contract.uc"
	"$ucode_bin" "$@" "$root_dir/tests/onboarding_contract.uc"
	"$ucode_bin" "$@" "$root_dir/tests/backend_migration_contract.uc"
	"$ucode_bin" "$@" "$root_dir/tests/subscriptions_contract.uc"
	"$ucode_bin" "$@" "$root_dir/tests/native_setup_contract.uc"
	"$ucode_bin" "$@" "$root_dir/tests/network_contract.uc"
	"$ucode_bin" "$@" "$root_dir/tests/maintenance_contract.uc"
	"$ucode_bin" "$@" "$root_dir/tests/dashboard_version_contract.uc"
	"$ucode_bin" "$@" "$root_dir/tests/components_recovery_contract.uc" "$runtime_dir/plugins/components/lib/control.uc"
	"$ucode_bin" "$@" "$root_dir/tests/extensions_contract.uc"
	"$ucode_bin" "$@" "$root_dir/tests/plugins_contract.uc"
	if [ "$openwrt_host" = 1 ]; then
		"$ucode_bin" "$@" "$root_dir/tests/adapter_contract.uc"
		"$ucode_bin" "$@" "$root_dir/tests/backend_contract.uc"
		"$ucode_bin" "$@" "$root_dir/tests/operation_contract.uc"
	else
		printf '%s\n' 'OpenWrt host primitives unavailable (libuci, /proc); adapter, backend and operation contracts deferred to OpenWrt/QEMU qualification.' >&2
	fi
else
	printf '%s\n' 'ucode unavailable; run this gate on OpenWrt or provide UCODE in CI.' >&2
	exit 2
fi

git -C "$root_dir" diff --check
