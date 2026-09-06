#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

git diff --check
python3 -m unittest tests.test_mvp_layout tests.test_openwrt_vm tests.test_release_tools tests.test_native_lifecycle tests.test_luci_management

if command -v ucode >/dev/null 2>&1; then
	./scripts/check-mvp.sh
else
	printf '%s\n' 'ucode unavailable; source UCode contracts deferred to OpenWrt/QEMU qualification.' >&2
fi

printf '%s\n' '快速检查通过；完整 fake-device 部署矩阵请运行 scripts/check-full.sh。'
