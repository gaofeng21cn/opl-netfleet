#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

# Fail fast on an incomplete host UCode runtime before running business tests.
if [ "${NETFLEET_UCODE_RESOLVED:-0}" != 1 ] && (UCODE_PREFLIGHT='fs socket' . "$root/scripts/resolve-ucode-runtime.sh") >/dev/null 2>&1; then
	UCODE_PREFLIGHT='fs socket' . "$root/scripts/resolve-ucode-runtime.sh"
	export UCODE UCODE_LIB NETFLEET_UCODE_RESOLVED=1
fi

git diff --check
python3 scripts/plugin-catalog.py check
export NETFLEET_SKIP_DIFF_CHECK=1

has_ucode=0
if command -v "${UCODE:-ucode}" >/dev/null 2>&1 || [ -x "${UCODE:-}" ]; then
	has_ucode=1
else
	printf '%s\n' 'ucode unavailable; source UCode contracts deferred to OpenWrt/QEMU qualification.' >&2
fi

has_bun=0
if command -v bun >/dev/null 2>&1; then
	has_bun=1
else
	printf '%s\n' 'bun unavailable; shared React UI gates and the desktop production build are deferred.' >&2
fi

has_node=0
if command -v node >/dev/null 2>&1 && [ -f "$root/desktop/tests/runtime.test.mjs" ]; then
	has_node=1
else
	printf '%s\n' 'node unavailable; macOS desktop runtime contracts deferred.' >&2
fi

python3 - "$root" "$has_ucode" "$has_bun" "$has_node" <<'PY'
from concurrent.futures import ThreadPoolExecutor
import os
import subprocess
import sys

root, has_ucode, has_bun, has_node = sys.argv[1:]

py_modules = [
    'tests.test_release_tools',
    'tests.test_ipk_bundle',
    'tests.test_mvp_layout',
    'tests.test_official_package_mirror',
    'tests.test_native_openwrt',
    'tests.test_openwrt_vm',
    'tests.test_backend_health',
    'tests.test_fail_open_mihomo',
    'tests.test_macos_build',
    'tests.test_plugin_sdk',
    'tests.test_plugin_lifecycle',
    'tests.test_platform_composition',
]

tasks = [(f'python:{m}', [sys.executable, '-m', 'unittest', m]) for m in py_modules]
if has_ucode == '1':
    tasks.append(('ucode:check-mvp', ['./scripts/check-mvp.sh']))
if has_bun == '1':
    tasks.append(('ui:check-ui', ['./scripts/check-ui.sh']))
if has_node == '1':
    tasks.append(('node:test', [
        'node', '--test',
        os.path.join(root, 'desktop/tests/runtime.test.mjs'),
        os.path.join(root, 'tests/desktop-miniapp.test.mjs'),
        os.path.join(root, 'tests/luci-management.test.mjs'),
    ]))

def run_task(item):
    label, cmd = item
    res = subprocess.run(cmd, cwd=root, capture_output=True, text=True)
    return label, res.returncode, res.stdout, res.stderr

with ThreadPoolExecutor(max_workers=min(8, os.cpu_count() or 4)) as pool:
    results = list(pool.map(run_task, tasks))

failed = False
for label, rc, out, err in results:
    if rc != 0:
        failed = True
        sys.stderr.write(f'=== FAILED [{label}] (exit {rc}) ===\n')
        if out:
            sys.stderr.write(out)
        if err:
            sys.stderr.write(err)
    elif label in ('ucode:check-mvp', 'ui:check-ui', 'node:test'):
        if out:
            sys.stdout.write(out)
        if err:
            sys.stderr.write(err)
sys.exit(1 if failed else 0)
PY

printf '%s\n' '快速检查通过；完整 fake-device 部署矩阵请运行 scripts/check-full.sh。'
