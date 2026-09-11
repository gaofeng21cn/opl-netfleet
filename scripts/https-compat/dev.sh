#!/usr/bin/env bash
# Developer-only entry point. Device installation stays with the package owner.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
usage() {
  cat <<'EOF'
Usage: scripts/https-compat/dev.sh check|build|vm|qualify

check    Run portable policy/recovery and plugin SDK contracts against working files.
         Requires UCODE (default: ucode); optional UCODE_LIB module path.
build    Build signed optional packages with the existing OpenWrt SDK builder.
         Requires SDK, SIGNING_KEY, OUTPUT. REF defaults to HEAD (committed source).
vm       Run the isolated native HTTPS diagnostic lane; never deploy to a device.
qualify  Run full base-package qualification, then the native HTTPS diagnostic lane.
         vm/qualify require PACKAGES, COMPAT_PACKAGES, OUTPUT; REF defaults to HEAD.
         QEMU currently requires macOS on Apple Silicon. OUTPUT must be outside Git.

Portable checks are not TLS/network or package qualification. The compatibility
diagnostic receipt alone never authorizes deployment. No real devices are contacted.
EOF
}
require() { [[ -n "${!1:-}" ]] || { printf '%s is required\n' "$1" >&2; exit 2; }; }
case "${1:---help}" in
  --help|-h) usage; exit 0 ;;
  check|build|vm|qualify) action=$1 ;;
  *) usage >&2; exit 2 ;;
esac
[[ $# == 1 ]] || { usage >&2; exit 2; }
cd "$root"
if [[ "$action" == check ]]; then
  interpreter=${UCODE:-ucode}
  command -v "$interpreter" >/dev/null || { printf 'Set UCODE to a native UCode executable.\n' >&2; exit 2; }
  args=()
  [[ -z "${UCODE_LIB:-}" ]] || args=(-L "$UCODE_LIB")
  runtime="$root/openwrt/https-compat/files/usr/libexec/opl-netfleet-compat"
  "$interpreter" "${args[@]}" tests/https_native_policy_bounds.uc "$runtime"
  "$interpreter" "${args[@]}" tests/https_native_recovery.uc "$runtime"
  python3 -m unittest discover -s tests -p test_plugin_sdk.py
  printf '%s\n' 'Portable contracts passed; run vm for real OpenWrt/TLS/fault coverage.'
  exit 0
fi
require OUTPUT
mkdir -p "$OUTPUT"
OUTPUT=$(cd "$OUTPUT" && pwd)
case "$OUTPUT/" in "$root/"*) printf 'OUTPUT must be outside the worktree.\n' >&2; exit 2 ;; esac
ref=${REF:-HEAD}
[[ "$ref" != -* ]] || { printf 'Invalid REF.\n' >&2; exit 2; }
# Resolve once so both lanes consume the same immutable source.
commit=$(git rev-parse --verify "${ref}^{commit}")
if [[ "$action" == build ]]; then
  require SDK; require SIGNING_KEY
  exec bash scripts/https-compat/build-package.sh "$SDK" "$SIGNING_KEY" "$OUTPUT" "$commit"
fi
require PACKAGES; require COMPAT_PACKAGES
[[ -f "$COMPAT_PACKAGES/compat-manifest.json" ]] || { printf 'Signed compatibility candidate missing.\n' >&2; exit 2; }
if [[ "$action" == qualify ]]; then
  bash scripts/openwrt-vm.sh --ref "$commit" --packages "$PACKAGES" --output "$OUTPUT/qualification.json"
fi
exec bash scripts/openwrt-vm.sh --ref "$commit" --packages "$PACKAGES" \
  --diagnostic compatibility --compat-package "$COMPAT_PACKAGES" --output "$OUTPUT/compatibility.json"
