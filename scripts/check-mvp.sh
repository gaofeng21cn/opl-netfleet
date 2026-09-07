#!/bin/sh
set -eu

root_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
runtime_dir=$root_dir/openwrt/files/usr/libexec/opl-netfleet

if command -v ucode >/dev/null 2>&1; then
	ucode -c -s -o /tmp/opl-netfleet-main.uc "$runtime_dir/main.uc"
	rm -f /tmp/opl-netfleet-main.uc
	ucode "$root_dir/tests/compiler_contract.uc"
	ucode "$root_dir/tests/selection_contract.uc"
	ucode "$root_dir/tests/adapter_contract.uc"
	ucode "$root_dir/tests/status_contract.uc"
	ucode "$root_dir/tests/evidence_contract.uc"
	ucode "$root_dir/tests/activation_contract.uc"
	ucode "$root_dir/tests/events_contract.uc"
	ucode "$root_dir/tests/subscription_contract.uc"
	ucode "$root_dir/tests/config_contract.uc"
	ucode "$root_dir/tests/onboarding_contract.uc"
	ucode "$root_dir/tests/backend_contract.uc"
	ucode "$root_dir/tests/backend_migration_contract.uc"
	ucode "$root_dir/tests/subscriptions_contract.uc"
	ucode "$root_dir/tests/native_setup_contract.uc"
	ucode "$root_dir/tests/operation_contract.uc"
	ucode "$root_dir/tests/network_contract.uc"
	ucode "$root_dir/tests/maintenance_contract.uc"
	ucode "$root_dir/tests/dashboard_version_contract.uc"
	ucode "$root_dir/tests/components_recovery_contract.uc" "$runtime_dir/application/components.uc"
	ucode "$root_dir/tests/extensions_contract.uc"
else
	printf '%s\n' 'ucode unavailable; run this gate on OpenWrt or provide UCODE in CI.' >&2
	exit 2
fi

git -C "$root_dir" diff --check
