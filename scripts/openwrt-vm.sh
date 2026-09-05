#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat <<'EOF'
Usage: scripts/openwrt-vm.sh --output <receipt.json> [--ref <git-ref>] [--packages <candidate-dir>]

Boot a pinned official OpenWrt image with native Apple Silicon QEMU/HVF and
qualify the exact Git commit/tree.
The default suite verifies native runtime, first setup without Nikki, and
Nikki migration in independent clean VMs. Package candidates add a clean lane.
Individual diagnostic lanes cannot authorize deployment. No real devices are contacted.

Options:
  --ref <git-ref>   Source ref to qualify (default: origin/main)
  --packages <dir>  Also install and qualify the exact APK candidate directory
  --diagnostic <lane>  Run only native, setup, migration, runtime, or package diagnostics
  --output <path>   Qualification receipt path outside the repository
  -h, --help        Show this help
EOF
}

die() {
	printf 'openwrt-vm: %s\n' "$1" >&2
	exit 1
}

source_ref=origin/main
output=""
packages=""
diagnostic=all
while (($#)); do
	case "$1" in
		--ref)
			(($# >= 2)) || die "--ref requires a value"
			source_ref=$2
			shift 2
			;;
		--output)
			(($# >= 2)) || die "--output requires a value"
			output=$2
			shift 2
			;;
		--packages)
			(($# >= 2)) || die "--packages requires a directory"
			packages=$2
			shift 2
			;;
		--diagnostic)
			(($# >= 2)) || die "--diagnostic requires a lane"
			diagnostic=$2
			case "$diagnostic" in native|setup|migration|runtime|package) ;; *) die "unknown diagnostic lane: $diagnostic" ;; esac
			shift 2
			;;
		-h|--help)
			usage
			exit 0
			;;
		*) die "unknown argument: $1" ;;
	esac
done

[[ -n "$output" ]] || die "--output is required"
[[ "$diagnostic" != package || -n "$packages" ]] || die "package diagnostic requires --packages"
[[ "$diagnostic" == all || "$diagnostic" == package || "$diagnostic" == setup || -z "$packages" ]] || die "only setup and package diagnostics accept --packages"
[[ "$source_ref" != -* ]] || die "source ref cannot begin with '-'"
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] ||
	die "native QEMU qualification requires macOS on Apple Silicon"
for tool in curl git gzip openssl python3 qemu-img qemu-system-aarch64 ssh ssh-keygen tar; do
	command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done
qemu-system-aarch64 -accel help 2>/dev/null | grep -Eq '(^|[[:space:]])hvf([[:space:]]|$)' ||
	die "qemu-system-aarch64 does not support the HVF accelerator"
qemu_version=$(qemu-system-aarch64 --version | awk 'NR == 1 { print $4 }')
[[ -n "$qemu_version" ]] || die "cannot determine qemu-system-aarch64 version"

firmware=${NETFLEET_QEMU_FIRMWARE:-}
if [[ -z "$firmware" ]]; then
	qemu_bin=$(command -v qemu-system-aarch64)
	qemu_prefix=$(cd -- "$(dirname -- "$qemu_bin")/.." && pwd)
	firmware="$qemu_prefix/share/qemu/edk2-aarch64-code.fd"
fi
[[ -f "$firmware" ]] ||
	die "AArch64 QEMU EFI firmware not found; set NETFLEET_QEMU_FIRMWARE"

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(git -C "$script_dir/.." rev-parse --show-toplevel)
if [[ "$source_ref" == "origin/main" ]]; then
	git -C "$repo_dir" fetch --quiet origin main
fi
source_commit=$(git -C "$repo_dir" rev-parse --verify "${source_ref}^{commit}") ||
	die "source ref does not resolve to a commit: $source_ref"
source_tree=$(git -C "$repo_dir" rev-parse "${source_commit}^{tree}")
[[ "$source_commit" =~ ^[0-9a-f]{40}$ && "$source_tree" =~ ^[0-9a-f]{40}$ ]] ||
	die "invalid source identity"

output_dir=$(cd -- "$(dirname -- "$output")" && pwd)
output_name=$(basename -- "$output")
[[ "$output_name" != */* && "$output_name" != "." && "$output_name" != ".." ]] ||
	die "invalid output name"

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/opl-netfleet-openwrt-vm.XXXXXX")
trap 'rm -rf -- "$work_dir"' EXIT
source_dir=$work_dir/source
mkdir -p "$source_dir"
git -C "$repo_dir" archive "$source_commit" \
	openwrt/Makefile \
	openwrt/mihomo-meta/source.json \
	openwrt/files/usr/libexec/opl-netfleet \
	openwrt/files/etc/init.d/opl-netfleet \
	openwrt/files/etc/init.d/opl-netfleet-core \
	openwrt/files/etc/config/netfleet \
	openwrt/files/usr/share/opl-netfleet/nikki \
	openwrt/files/etc/opl-netfleet/policy-sources/base-v1.json \
	openwrt/files/etc/opl-netfleet/rulesets.lock.json \
	scripts/deploy-openwrt-remote.sh \
	scripts/openwrt-vm \
	scripts/install-netfleet.sh \
	scripts/verify-netfleet-release.py tests |
	tar -C "$source_dir" -xf -

package_archive=""
package_manifest_sha=""
if [[ -n "$packages" ]]; then
	packages=$(cd "$packages" 2>/dev/null && pwd) || die "package candidate directory is unavailable"
	"$source_dir/scripts/verify-netfleet-release.py" \
		--directory "$packages" --source-commit "$source_commit" --source-tree "$source_tree" >/dev/null
	python3 - "$packages/manifest.json" <<'PY'
import json, sys
from pathlib import Path
manifest = json.loads(Path(sys.argv[1]).read_text())
if (
    manifest.get("package_format") != "apk"
    or manifest.get("package_arch") != "noarch"
    or manifest.get("build_target_arch") != "aarch64_generic"
):
    raise SystemExit("openwrt-vm: package candidate must be a noarch APK set built for aarch64_generic")
PY
	package_archive=$work_dir/package-candidate.tar
	tar -cf "$package_archive" -C "$packages" .
	package_manifest_sha=$(shasum -a 256 "$packages/manifest.json" | awk '{print $1}')
fi

rm -f -- "$output_dir/$output_name"
cache_root=${XDG_CACHE_HOME:-$HOME/.cache}
NETFLEET_SOURCE_COMMIT=$source_commit \
NETFLEET_SOURCE_TREE=$source_tree \
NETFLEET_RECEIPT="$output_dir/$output_name" \
NETFLEET_WORKSPACE=$source_dir \
NETFLEET_VM_CACHE="$cache_root/opl-netfleet/openwrt-vm" \
NETFLEET_QEMU_FIRMWARE=$firmware \
NETFLEET_QEMU_VERSION=$qemu_version \
	NETFLEET_VM_LANE=$diagnostic \
	NETFLEET_PACKAGE_ARCHIVE="$package_archive" \
	NETFLEET_PACKAGE_MANIFEST_SHA256="$package_manifest_sha" \
	sh "$source_dir/scripts/openwrt-vm/qualify.sh"

[[ -f "$output_dir/$output_name" ]] || die "qualification receipt was not produced"
python3 - "$output_dir/$output_name" "$source_commit" "$source_tree" "$diagnostic" <<'PY'
import json
from pathlib import Path
import sys

receipt = json.loads(Path(sys.argv[1]).read_text())
passed = (receipt.get("diagnostic_passed") is True and receipt.get("qualified") is False
          if sys.argv[4] != "all" else receipt.get("qualified") is True)
if not (
    passed
    and receipt.get("source_commit") == sys.argv[2]
    and receipt.get("source_tree") == sys.argv[3]
):
    raise SystemExit("openwrt-vm: runner returned an invalid receipt")
print(json.dumps(receipt, ensure_ascii=False, separators=(",", ":")))
PY
