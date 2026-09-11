#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

git diff --check
python3 -m unittest tests.test_mvp_layout tests.test_platform_composition tests.test_openwrt_vm tests.test_release_tools tests.test_macos_build tests.test_native_lifecycle tests.test_backend_health tests.test_luci_management tests.test_plugin_sdk tests.test_plugin_update

if command -v "${UCODE:-ucode}" >/dev/null 2>&1; then
	./scripts/check-mvp.sh
else
	printf '%s\n' 'ucode unavailable; source UCode contracts deferred to OpenWrt/QEMU qualification.' >&2
fi

if command -v bun >/dev/null 2>&1; then
	./scripts/check-ui.sh
	(cd "$root/ui" && bun run build:desktop)
else
	printf '%s\n' 'bun unavailable; shared React UI gates and the desktop production build are deferred.' >&2
fi

if command -v node >/dev/null 2>&1 && [ -f "$root/desktop/tests/runtime.test.mjs" ]; then
	node --test "$root/desktop/tests/runtime.test.mjs"
else
	printf '%s\n' 'node unavailable; macOS desktop runtime contracts deferred.' >&2
fi

printf '%s\n' '快速检查通过；完整 fake-device 部署矩阵请运行 scripts/check-full.sh。'
