#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf '%s\n' 'Usage: scripts/prepare-openwrt-sdk.sh --sdk <openwrt-sdk>'
}

die() {
  printf 'prepare-openwrt-sdk: %s\n' "$1" >&2
  exit 1
}

sdk=''
while (($#)); do
  case "$1" in
    --sdk)
      (($# >= 2)) || die '--sdk requires a path'
      sdk=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

[[ -n "$sdk" ]] || die 'OpenWrt SDK is required'
sdk=$(cd "$sdk" 2>/dev/null && pwd) || die 'SDK is unavailable'
[[ -f "$sdk/Makefile" ]] || die "not an OpenWrt SDK: $sdk"

make_command=${MAKE:-make}
command -v "$make_command" >/dev/null 2>&1 || die "make command is unavailable: $make_command"

"$make_command" -C "$sdk" defconfig

[[ -f "$sdk/.config" ]] || die 'prepared SDK has no build configuration'
package_arch=$("$make_command" -s -C "$sdk" val.ARCH_PACKAGES 2>/dev/null | tail -1)
[[ -n "$package_arch" && "$package_arch" != *' undefined' ]] || die 'prepared SDK package architecture is unreadable'
printf 'prepared_sdk=%s package_arch=%s\n' "$sdk" "$package_arch"
