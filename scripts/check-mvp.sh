#!/bin/sh
set -eu

root_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
if [ "${NETFLEET_UCODE_RESOLVED:-0}" != 1 ]; then
	UCODE_PREFLIGHT='fs socket' . "$root_dir/scripts/resolve-ucode-runtime.sh"
fi
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
	shared_work=$(mktemp -d "${TMPDIR:-/tmp}/netfleet-mvp-check.XXXXXX")
	trap 'rm -rf "$shared_work"' EXIT INT TERM

	# These contracts drive the OpenWrt host itself: libuci is an OpenWrt C
	# module and process identity reads /proc. Every other contract in this
	# list is portable and still gates shared business code wherever UCode
	# runs, including the pinned macOS runtime.
	if "$ucode_bin" "$@" -e 'import { cursor } from "uci"; import * as fs from "fs"; if (fs.readfile("/proc/self/stat") == null) die("openwrt_host_primitives_absent");' >/dev/null 2>&1; then
		openwrt_host=1
	else
		openwrt_host=0
	fi
	"$ucode_bin" "$@" -c -s -o "$shared_work/main.uc" "$runtime_dir/main.uc"
	rm -f "$shared_work/main.uc"

	# Stage an immutable shared runtime once so contracts skip copying and SHA256.
	mkdir -p "$shared_work/runtime/plugins"
	cp -R "$runtime_dir"/. "$shared_work/runtime/"
	for p in "$root_dir/plugins"/*; do
		[ -f "$p/manifest.json" ] || continue
		[ "$(basename "$p")" = "device-identity" ] || cp -R "$p" "$shared_work/runtime/plugins/"
	done
	chmod -R u+rwX,go-w "$shared_work/runtime"
	export NETFLEET_TEST_RUNTIME="$shared_work/runtime"

	contracts="
plugin_schema_contract.uc
host_adapter_contract.uc
composition_contract.uc
compiler_contract.uc
selection_contract.uc
portable_services_contract.uc
storage_contract.uc
status_contract.uc
evidence_contract.uc
activation_contract.uc
native_dataplane_contract.uc
events_contract.uc
subscriptions_contract.uc
config_contract.uc
onboarding_contract.uc
backend_migration_contract.uc
network_contract.uc
maintenance_contract.uc
dashboard_version_contract.uc
components_contract.uc
site_sync_contract.uc
https_lifecycle_contract.uc"
	if [ "$openwrt_host" = 1 ]; then
		contracts="$contracts
adapter_contract.uc
backend_contract.uc
operation_contract.uc"
	else
		printf '%s\n' 'OpenWrt host primitives unavailable (libuci, /proc); adapter, backend and operation contracts deferred to OpenWrt/QEMU qualification.' >&2
	fi

	if command -v python3 >/dev/null 2>&1; then
		export NETFLEET_TEST_DIGESTS="$shared_work/digests.json"
		python3 - "$ucode_bin" "${UCODE_LIB:-}" "$root_dir/tests" "$NETFLEET_TEST_RUNTIME" "$NETFLEET_TEST_DIGESTS" $contracts <<'PY'
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

ucode_bin, ucode_lib, tests_dir, runtime_dir, digests_path, *contracts = sys.argv[1:]
rt_real = os.path.realpath(runtime_dir)
digests = {}
for dirpath, dirnames, filenames in os.walk(rt_real):
    dirnames.sort()
    for name in sorted(filenames):
        full = os.path.join(dirpath, name)
        if os.path.isfile(full):
            digests[full] = hashlib.sha256(Path(full).read_bytes()).hexdigest()
Path(digests_path).write_text(json.dumps(digests))

base_cmd = [ucode_bin]
if ucode_lib:
    base_cmd.extend(['-L', ucode_lib])

def run_contract(name: str):
    res = subprocess.run([*base_cmd, os.path.join(tests_dir, name)], capture_output=True, text=True)
    return name, res.returncode, res.stdout, res.stderr

with ThreadPoolExecutor(max_workers=min(8, os.cpu_count() or 4)) as pool:
    results = list(pool.map(run_contract, contracts))

failed = False
for name, rc, out, err in results:
    if out:
        sys.stdout.write(out)
    if err:
        sys.stderr.write(err)
    if rc != 0:
        sys.stderr.write(f'FAILED contract {name} (exit {rc})\n')
        failed = True
sys.exit(1 if failed else 0)
PY
	else
		for contract in $contracts; do
			"$ucode_bin" "$@" "$root_dir/tests/$contract"
		done
	fi
else
	printf '%s\n' 'ucode unavailable; run this gate on OpenWrt or provide UCODE in CI.' >&2
	exit 2
fi

[ "${NETFLEET_SKIP_DIFF_CHECK:-0}" = 1 ] || git -C "$root_dir" diff --check
