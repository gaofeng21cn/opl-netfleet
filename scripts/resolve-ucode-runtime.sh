#!/bin/sh
# Resolve and validate the UCode runtime used by host-side contracts.
# Usage: UCODE_PREFLIGHT='fs socket' . scripts/resolve-ucode-runtime.sh
# Modules come from the environment on purpose: a sourced script inherits the
# caller's positional parameters on shells whose dot builtin ignores arguments,
# which would preflight the caller's own arguments instead of the modules.
set -eu
_root=${NETFLEET_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}
# A runtime that cannot run a shell command still loads modules, so the popen
# smoke test from the macOS bootstrap is part of candidate validation: a stale
# or half-built cache must be skipped instead of failing every later check.
_smoke='import * as fs from "fs"; for (let command in ["printf shell-ok", ["printf", "shell-ok"]]) { let p = fs.popen(command); assert(p != null); assert(p.read("all") == "shell-ok"); assert(p.close() == 0); } print("ok\n");'
_works() {
  [ -x "$1" ] || return 1
  _libdir=$2
  if [ -n "$_libdir" ]; then
    "$1" -L "$_libdir" -e "$_smoke" >/dev/null 2>&1 || return 1
  else
    "$1" -e "$_smoke" >/dev/null 2>&1 || return 1
  fi
}
_module_dir() {
  CDPATH= cd -- "$(dirname "$1")/../lib/ucode" 2>/dev/null && pwd
}
if [ -n "${UCODE:-}" ]; then
  _ucode=$UCODE
else
  _ucode=''
  for _candidate in \
    "${NETFLEET_MACOS_RUNTIME:-}/bin/ucode" \
    "$_root/.build/macos/OPL NetFleet.app/Contents/Resources/runtime/bin/ucode" \
    "$HOME"/.cache/opl-netfleet/macos/builds/*/runtime/bin/ucode \
    "$HOME/.cache/opl-netfleet/macos/runtime/bin/ucode" \
    "$HOME/.cache/opl-netfleet/macos/build/ucode/ucode" \
    "$(command -v ucode 2>/dev/null || true)"; do
    [ -n "$_candidate" ] || continue
    _works "$_candidate" "$(_module_dir "$_candidate")" && { _ucode=$_candidate; break; }
  done
  [ -n "$_ucode" ] || _ucode=$(command -v ucode 2>/dev/null || printf 'ucode')
fi
command -v "$_ucode" >/dev/null 2>&1 || [ -x "$_ucode" ] || {
  printf 'UCode runtime missing: %s\n' "$_ucode" >&2; exit 2;
}
if [ -n "${UCODE_LIB:-}" ]; then
  _lib=$UCODE_LIB
else
  _lib=$(CDPATH= cd -- "$(dirname "$_ucode")/../lib/ucode" 2>/dev/null && pwd || true)
  [ -d "$_lib" ] || _lib=''
fi
export UCODE=$_ucode
export UCODE_LIB=$_lib
_args=''
_modules=${UCODE_PREFLIGHT:-}
# shellcheck disable=SC2086
for _module in $_modules; do
  case "$_module" in
    fs|socket|digest|uci|ubus|uloop) ;;
    *) printf 'Unknown UCode preflight module: %s\n' "$_module" >&2; exit 2;;
  esac
  # A caller may pass the bootstrap form (a directory or a `*.so` glob); only a
  # plain directory can be checked per module, the preflight below covers the rest.
  if [ -d "$_lib" ] && [ ! -f "$_lib/$_module.so" ]; then
    printf 'UCode module missing: %s (runtime=%s, module_dir=%s)\n' "$_module" "$_ucode" "$_lib" >&2
    exit 2
  fi
  _args="$_args import * as $_module from \"$_module\";"
done
if [ -n "$_modules" ]; then
  # Use eval only with the fixed module names above; paths are passed separately.
  # shellcheck disable=SC2086
  "$_ucode" ${_lib:+-L "$_lib"} -e "$_args print(\"ucode-runtime-ok\\n\");" >/dev/null || {
    printf 'UCode runtime preflight failed: %s\n' "$_ucode" >&2; exit 2;
  }
fi
if [ "${NETFLEET_UCODE_REPORT:-0}" = 1 ]; then
  printf "UCODE=%s\nUCODE_LIB=%s\n" "$UCODE" "$UCODE_LIB"
  for _module in fs socket digest uci ubus uloop; do
    [ -z "$UCODE_LIB" ] || [ -f "$UCODE_LIB/$_module.so" ] && printf "module.%s=%s\n" "$_module" present || printf "module.%s=%s\n" "$_module" missing
  done
fi
unset _root _ucode _lib _args _candidate _module _libdir _smoke _modules
unset -f _works _module_dir
