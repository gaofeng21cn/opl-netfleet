#!/bin/sh
# Strict integration entry: missing prerequisites are failures, never skipped gates.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
lane=${1:-shared}
case "$lane" in
  shared|macos) [ "$#" -le 1 ] || exit 2 ;;
  *) printf '%s\n' 'Usage: scripts/check-platform.sh [shared|macos]' >&2; exit 2 ;;
esac
for program in python3 bun node "${UCODE:-ucode}"; do
  command -v "$program" >/dev/null 2>&1 || { printf 'Required tool missing: %s\n' "$program" >&2; exit 2; }
done
if [ -n "${UCODE_LIB:-}" ]; then set -- -L "$UCODE_LIB"; else set --; fi
"${UCODE:-ucode}" "$@" -e 'import * as fs from "fs"; import * as socket from "socket"; assert(type(fs.open) == "function");'
if [ "$lane" = macos ]; then
  [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || { printf '%s\n' 'macOS integration requires Apple Silicon.' >&2; exit 2; }
  : "${NETFLEET_RUNTIME_ROOT:?Provide the runtime from scripts/macos/bootstrap.py}"
fi
./scripts/check-fast.sh
if [ "$lane" = macos ]; then
  node --test desktop/tests/bridge.test.mjs
  node desktop/tests/qualification.mjs
  node desktop/tests/owner-crash.mjs
  bun desktop/tests/react-client.ts
  python3 scripts/macos/build-app.py
  '.build/macos/OPL NetFleet.app/Contents/Resources/runtime/bin/netfleet-network-helper' --self-test
fi
printf 'Strict %s integration passed. OpenWrt deployment still requires exact-source QEMU qualification.\n' "$lane"
