#!/bin/sh
# Resolve and validate the UCode runtime used by host-side contracts.
# Usage: . scripts/resolve-ucode-runtime.sh [module ...]
set -eu
_root=${NETFLEET_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}
if [ -n "${UCODE:-}" ]; then
  _ucode=$UCODE
else
  _ucode=''
  for _candidate in \
    "${NETFLEET_MACOS_RUNTIME:-}/bin/ucode" \
    "$_root/.cache/macos/runtime/bin/ucode" \
    "$HOME/.cache/opl-netfleet/macos/runtime/bin/ucode" \
    "$HOME/.cache/opl-netfleet/macos/build/ucode/ucode"; do
    [ -x "$_candidate" ] && { _ucode=$_candidate; break; }
  done
  [ -n "$_ucode" ] || _ucode=ucode
fi
command -v "$_ucode" >/dev/null 2>&1 || [ -x "$_ucode" ] || {
  printf 'UCode runtime missing: %s\n' "$_ucode" >&2; exit 2;
}
if [ -n "${UCODE_LIB:-}" ]; then
  _lib=$UCODE_LIB
else
  _lib=$(CDPATH= cd -- "$(dirname "$_ucode")/../lib/ucode" 2>/dev/null || true)
  [ -d "$_lib" ] || _lib=''
fi
export UCODE=$_ucode
export UCODE_LIB=$_lib
_args=''
[ -n "$_lib" ] && _args="-L $_lib"
for _module in "$@"; do
  case "$_module" in
    fs|socket|digest|uci|ubus|uloop) ;;
    *) printf 'Unknown UCode preflight module: %s\n' "$_module" >&2; exit 2;;
  esac
  if [ -n "$_lib" ] && [ ! -f "$_lib/$_module.so" ]; then
    printf 'UCode module missing: %s (runtime=%s, module_dir=%s)\n' "$_module" "$_ucode" "$_lib" >&2
    exit 2
  fi
  _args="$_args import * as $_module from \"$_module\";"
done
if [ "$#" -gt 0 ]; then
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
unset _root _ucode _lib _args _candidate _module
