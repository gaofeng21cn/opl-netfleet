#!/usr/bin/env bash
set -euo pipefail

# Prevent macOS metadata from leaking into the temporary deployment archives.
export COPYFILE_DISABLE=1

usage() {
	cat <<'EOF'
Usage: scripts/deploy-openwrt.sh <ssh-target> [options]

Options:
  --ref <git-ref>       Immutable source ref to deploy (default: origin/main)
  --packages <dir>      Versioned package directory with manifest.json
  --release <tag>       Download a GitHub Release package set into the local cache
  --instance <dir>      Generated deployment bundle: policy, subscriptions, Nikki mixin and platform
  --leave-disabled      Explicitly disable an active target, then install and stage
  --activate            Enable the staged candidate after protected validation
  --presentation-only   Update LuCI bytes on an already healthy matching active target
  --qualification <file>
                        Override the cached VM receipt for the exact commit/tree
  --dry-run             Build and verify the exact bundle without contacting target
  -h, --help            Show this help
EOF
}

die() {
	printf 'deploy-openwrt: %s\n' "$1" >&2
	exit 1
}

sha256_file() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	else
		shasum -a 256 "$1" | awk '{print $1}'
	fi
}

epoch_ms() {
	local value
	value=$(date +%s%3N 2>/dev/null || true)
	if [[ "$value" =~ ^[0-9]+$ ]]; then
		printf '%s\n' "$value"
	else
		printf '%s000\n' "$(date +%s)"
	fi
}

verify_qualification_receipt() {
	python3 - "$1" "$2" "$3" "${packages_dir:-}" <<'PY'
import json
from pathlib import Path
import sys

try:
    receipt = json.loads(Path(sys.argv[1]).read_text())
except (OSError, json.JSONDecodeError):
    raise SystemExit(1)

checks = receipt.get("checks")
required_checks = (
    "boot",
    "ssh",
    "var_symlink",
    "ubus",
    "deploy_failure_rollback",
    "post_failure_management",
)
valid = (
    receipt.get("schema") in {"opl-netfleet-openwrt-vm-qualification.v1", "opl-netfleet-openwrt-vm-qualification.v2"}
    and receipt.get("qualified") is True
    and receipt.get("source_commit") == sys.argv[2]
    and receipt.get("source_tree") == sys.argv[3]
    and isinstance(checks, dict)
    and all(checks.get(name) is True for name in required_checks)
)
if valid and receipt.get("schema") == "opl-netfleet-openwrt-vm-qualification.v2":
    valid = receipt.get("package_qualified") is True
    package = receipt.get("package")
    package_dir = sys.argv[4]
    if valid and package_dir:
        try:
            manifest_sha = __import__("hashlib").sha256((Path(package_dir) / "manifest.json").read_bytes()).hexdigest()
        except OSError:
            valid = False
        else:
            valid = isinstance(package, dict) and package.get("manifest_sha256") == manifest_sha
raise SystemExit(0 if valid else 1)
PY
}

instance_summary() {
	python3 - "$1" "$2" <<'PY'
import json
from pathlib import Path
import re
import sys

try:
    policy = json.loads(Path(sys.argv[1]).read_text())
    platform = json.loads(Path(sys.argv[2]).read_text())
except (OSError, json.JSONDecodeError) as exc:
    raise SystemExit(f"deploy-openwrt: deployment bundle JSON is invalid: {exc}")

bool_fields = {
    'scheduled_restart', 'test_profile', 'fast_reload', 'api_secret_required',
    'allow_lan', 'selection_cache', 'log_clear_at_stop', 'ipv6', 'unified_delay', 'tcp_concurrent',
    'tun_enabled', 'dns_enabled', 'dns_ipv6', 'fake_ip_cache', 'sniffer_enabled',
    'sniffer_force_dns_mapping', 'sniffer_parse_pure_ip',
    'sniffer_override_destination', 'ipv4_dns_hijack', 'ipv6_dns_hijack',
    'ipv4_proxy', 'ipv6_proxy', 'fake_ip_ping_hijack',
    'bypass_china_mainland_ip', 'bypass_china_mainland_ip6',
}
string_fields = {
    'api_listen', 'log_level', 'dns_cache_algorithm', 'dns_mode', 'tcp_mode',
    'udp_mode',
}
target = policy.get('main', {}).get('target')
if platform.get('schema_version') != 1 or set(platform) != {'schema_version', 'target', 'nikki', 'openwrt'}:
    raise SystemExit('deploy-openwrt: platform schema is unsupported')
if not isinstance(target, str) or platform.get('target') != target:
    raise SystemExit('deploy-openwrt: platform target does not match policy target')
nikki = platform.get('nikki')
if not isinstance(nikki, dict) or set(nikki) != bool_fields | string_fields:
    raise SystemExit('deploy-openwrt: platform Nikki fields are invalid')
if any(not isinstance(nikki[name], bool) for name in bool_fields) or any(not isinstance(nikki[name], str) or not nikki[name] for name in string_fields):
    raise SystemExit('deploy-openwrt: platform Nikki values are invalid')
if nikki['api_listen'] != '0.0.0.0:9090' or nikki['log_level'] not in {'error', 'warning', 'info'} or nikki['dns_cache_algorithm'] not in {'lru', 'arc'}:
    raise SystemExit('deploy-openwrt: platform controller, log or DNS cache value is invalid')
if not nikki['api_secret_required'] or not nikki['allow_lan']:
    raise SystemExit('deploy-openwrt: platform API secret and LAN listeners must be required')
if nikki['dns_mode'] != 'redir-host' or nikki['tcp_mode'] != 'tproxy' or nikki['udp_mode'] != 'tproxy':
    raise SystemExit('deploy-openwrt: platform must use redir-host and TCP/UDP TProxy')
if nikki['tun_enabled'] or nikki['fake_ip_cache'] or nikki['sniffer_override_destination']:
    raise SystemExit('deploy-openwrt: platform v1 requires TUN, fake-IP cache and destination override off')
openwrt = platform.get('openwrt')
if not isinstance(openwrt, dict) or set(openwrt) != {'software_flow_offload', 'hardware_flow_offload'} or any(not isinstance(value, bool) for value in openwrt.values()):
    raise SystemExit('deploy-openwrt: platform OpenWrt fields are invalid')
if openwrt['software_flow_offload'] or openwrt['hardware_flow_offload']:
    raise SystemExit('deploy-openwrt: flow offload requires a separate qualification')

def safe(value):
    return re.sub(r"[^A-Za-z0-9_.:@+-]", "?", str(value))

policy_source = policy.get("policy_source") if isinstance(policy.get("policy_source"), dict) else {}
recovery_profile = policy.get("recovery_profile") if isinstance(policy.get("recovery_profile"), dict) else {}
providers = policy.get("providers") if isinstance(policy.get("providers"), dict) else {}
capabilities = policy.get("capabilities") if isinstance(policy.get("capabilities"), dict) else {}
provider_roles = ",".join(
    f"{safe(name)}:{safe(value.get('role', 'unspecified'))}"
    for name, value in sorted(providers.items()) if isinstance(value, dict)
) or "none"
capability_ids = ",".join(safe(name) for name in sorted(capabilities)) or "none"
print(
    f"policy_source={safe(policy_source.get('ref', 'unset'))} "
    f"recovery_profile={safe(recovery_profile.get('ref', 'unset'))} "
    f"providers={provider_roles} capabilities={capability_ids}"
)
PY
}

target=""
source_ref="origin/main"
activate=0
leave_disabled=0
presentation_only=0
dry_run=0
instance_dir=""
packages_dir=""
release_tag=""
qualification=""
qualification_source="none"
started_ms=$(epoch_ms)

while (($#)); do
	case "$1" in
		--ref)
			(($# >= 2)) || die "--ref requires a value"
			source_ref=$2
			shift 2
			;;
		--leave-disabled)
			leave_disabled=1
			shift
			;;
		--activate)
			activate=1
			shift
			;;
		--presentation-only)
			presentation_only=1
			shift
			;;
		--qualification)
			(($# >= 2)) || die "--qualification requires a value"
			qualification=$2
			shift 2
			;;
		--instance)
			(($# >= 2)) || die "--instance requires a value"
			instance_dir=$2
			shift 2
			;;
		--packages)
			(($# >= 2)) || die "--packages requires a value"
			packages_dir=$2
			shift 2
			;;
		--release)
			(($# >= 2)) || die "--release requires a value"
			release_tag=$2
			shift 2
			;;
		--dry-run)
			dry_run=1
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		-*)
			die "unknown option: $1"
			;;
		*)
			[[ -z "$target" ]] || die "only one ssh target is allowed"
			target=$1
			shift
			;;
	esac
done

[[ -n "$target" ]] || die "ssh target is required"
[[ "$target" != -* ]] || die "ssh target cannot begin with '-'"
[[ "$target" =~ ^[A-Za-z0-9._@%:+-]+$ ]] || die "ssh target contains unsupported characters"
[[ "$source_ref" != -* ]] || die "source ref cannot begin with '-'"
[[ -z "$packages_dir" || -z "$release_tag" ]] || die "--packages and --release are mutually exclusive"
((activate + leave_disabled + presentation_only <= 1)) ||
	die "--activate, --leave-disabled and --presentation-only are mutually exclusive"
((!presentation_only)) || [[ -n "$instance_dir" ]] || die "--presentation-only requires --instance"
if ((activate)); then
	if [[ -n "$qualification" ]]; then
		[[ -f "$qualification" ]] || die "qualification receipt is unavailable: $qualification"
		qualification=$(cd -- "$(dirname -- "$qualification")" && pwd)/$(basename -- "$qualification")
		qualification_source=explicit
	fi
elif [[ -n "$qualification" ]]; then
	die "--qualification is only valid with --activate"
fi
if [[ -n "$instance_dir" ]]; then
	[[ -d "$instance_dir" ]] || die "deployment bundle directory is unavailable: $instance_dir"
	instance_dir=$(cd -- "$instance_dir" && pwd)
	for name in policy.json subscriptions.json nikki-mixin.yaml platform.json; do
		[[ -f "$instance_dir/$name" ]] || die "deployment bundle file is unavailable: $instance_dir/$name"
	done
	command -v python3 >/dev/null 2>&1 || die "python3 is required to validate deployment bundles"
	instance_description=$(instance_summary "$instance_dir/policy.json" "$instance_dir/platform.json") || exit 1
	printf 'deploy-openwrt: deployment bundle %s\n' "$instance_description" >&2
fi

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

product_version=$(git -C "$repo_dir" show "${source_commit}:openwrt/Makefile" |
	sed -n 's/^PKG_VERSION:=\([0-9][0-9A-Za-z.+~-]*\)$/\1/p' | head -1)
[[ "$product_version" =~ ^[0-9][0-9A-Za-z.+~-]*$ ]] ||
	die "NetFleet product version is unreadable"

release_mode=source
release_format=source
if [[ -n "$release_tag" ]]; then
	command -v gh >/dev/null 2>&1 || die "gh is required to download release packages"
	cache_root=${XDG_CACHE_HOME:-${HOME:+$HOME/.cache}}
	[[ -n "$cache_root" && "$cache_root" = /* ]] || die "XDG_CACHE_HOME or HOME is required for the release cache"
	remote_url=$(git -C "$repo_dir" remote get-url origin)
	case "$remote_url" in
		git@github.com:*) release_repo=${remote_url#git@github.com:}; release_repo=${release_repo%.git} ;;
		https://github.com/*) release_repo=${remote_url#https://github.com/}; release_repo=${release_repo%.git} ;;
		*) die "origin is not a supported GitHub repository" ;;
	esac
	if [[ "$release_tag" == latest ]]; then
		release_tag=$(gh release view --repo "$release_repo" --json tagName --jq .tagName)
	fi
	[[ "$release_tag" =~ ^[A-Za-z0-9._+-]+$ ]] || die "release tag contains unsupported characters"
	packages_dir=$cache_root/opl-netfleet/releases/$release_tag
	if [[ ! -f "$packages_dir/manifest.json" ]]; then
		download_dir=$(mktemp -d "${TMPDIR:-/tmp}/opl-netfleet-release.XXXXXX")
		trap 'rm -rf -- "$download_dir"' EXIT
		gh release download "$release_tag" --repo "$release_repo" --dir "$download_dir"
		mkdir -p "$(dirname "$packages_dir")"
		chmod 0700 "$download_dir"
		mv "$download_dir" "$packages_dir"
		trap - EXIT
	fi
fi
if [[ -n "$packages_dir" ]]; then
	[[ -d "$packages_dir" ]] || die "package directory is unavailable: $packages_dir"
	packages_dir=$(cd -- "$packages_dir" && pwd)
	command -v python3 >/dev/null 2>&1 || die "python3 is required to verify package releases"
	package_summary=$(python3 - "$packages_dir" "$source_commit" "$source_tree" <<'PY'
import hashlib, json, re, sys
from pathlib import Path

root = Path(sys.argv[1])
try:
    manifest = json.loads((root / "manifest.json").read_text())
except (OSError, json.JSONDecodeError) as exc:
    raise SystemExit(f"deploy-openwrt: package manifest is unreadable: {exc}")
if manifest.get("schema") != "opl-netfleet-package-manifest.v2":
    raise SystemExit("deploy-openwrt: package manifest schema is unsupported")
if manifest.get("source_commit") != sys.argv[2] or manifest.get("source_tree") != sys.argv[3]:
    raise SystemExit("deploy-openwrt: package manifest does not match the selected source")
package_format = manifest.get("package_format")
if package_format not in {"apk", "ipk"}:
    raise SystemExit("deploy-openwrt: package format is unsupported")
arch = manifest.get("package_arch")
if not isinstance(arch, str) or not re.fullmatch(r"[A-Za-z0-9_.+-]+", arch):
    raise SystemExit("deploy-openwrt: package architecture is invalid")
legacy_versions = {"0.2.0", "0.3.0", "0.3.1", "0.3.2", "0.3.3", "0.4.0"}
build_target_arch = manifest.get("build_target_arch")
if build_target_arch is None and manifest.get("package_version") not in legacy_versions:
    raise SystemExit("deploy-openwrt: package build target architecture is missing")
if build_target_arch is not None and (
    not isinstance(build_target_arch, str)
    or not re.fullmatch(r"[A-Za-z0-9_.+-]+", build_target_arch)
):
    raise SystemExit("deploy-openwrt: package build target architecture is invalid")
if package_format == "apk" and manifest.get("package_version") not in legacy_versions and arch != "noarch":
    raise SystemExit("deploy-openwrt: release APK architecture must be noarch")
required = []
for field in ("files_manifest",):
    value = manifest.get(field)
    if not isinstance(value, dict):
        raise SystemExit(f"deploy-openwrt: package manifest missing {field}")
    required.append(value)
artifacts = manifest.get("artifacts")
if not isinstance(artifacts, list) or len(artifacts) != 2 or {item.get("package") for item in artifacts if isinstance(item, dict)} != {"opl-netfleet", "luci-app-netfleet"}:
    raise SystemExit("deploy-openwrt: package artifact set is invalid")
artifact_files = manifest.get("artifact_files")
if not isinstance(artifact_files, dict) or artifact_files != {item["package"]: item["name"] for item in artifacts}:
    raise SystemExit("deploy-openwrt: package artifact mapping is invalid")
required.extend(artifacts)
key = manifest.get("apk_public_key")
if package_format == "apk":
    if not isinstance(key, dict):
        raise SystemExit("deploy-openwrt: signed APK release is missing its public key")
    required.append(key)
    feed_index = manifest.get("feed_index")
    if feed_index is not None:
        if not isinstance(feed_index, dict) or feed_index.get("name") != "packages.adb":
            raise SystemExit("deploy-openwrt: APK release feed index identity is invalid")
        required.append(feed_index)
    elif manifest.get("package_version") not in legacy_versions:
        raise SystemExit("deploy-openwrt: APK release is missing packages.adb feed index")
elif key is not None:
    raise SystemExit("deploy-openwrt: IPK release must not declare an APK key")
names = {"manifest.json"}
for item in required:
    name, digest = item.get("name"), item.get("sha256")
    if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9_.+-]+", name) or name in names:
        raise SystemExit("deploy-openwrt: package artifact name is invalid")
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise SystemExit("deploy-openwrt: package artifact digest is invalid")
    path = root / name
    if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
        raise SystemExit(f"deploy-openwrt: package artifact identity mismatch: {name}")
    names.add(name)
print(f"format={package_format} arch={arch} build_target={build_target_arch or 'legacy'}")
PY
	) || exit 1
	release_mode=package
	release_format=${package_summary#format=}
	release_format=${release_format%% *}
	printf 'deploy-openwrt: release package %s\n' "$package_summary" >&2
fi

activation_qualified=false
qualification_digest=""
if ((activate)); then
	command -v python3 >/dev/null 2>&1 || die "python3 is required to verify qualification receipts"
	cache_root=${XDG_CACHE_HOME:-${HOME:+$HOME/.cache}}
	[[ -n "$cache_root" && "$cache_root" = /* ]] ||
		die "XDG_CACHE_HOME or HOME is required for the VM qualification cache"
	qualification_dir=$cache_root/opl-netfleet/vm-qualifications
	mkdir -p "$qualification_dir"
	chmod 0700 "$qualification_dir"
	qualification_cache=$qualification_dir/$source_commit-$source_tree.json
	if [[ -z "$qualification" ]]; then
		qualification=$qualification_cache
		if [[ -f "$qualification" ]] &&
			verify_qualification_receipt "$qualification" "$source_commit" "$source_tree"; then
			qualification_source=cache
		else
			printf 'deploy-openwrt: qualification=generate commit=%s tree=%s\n' \
				"$source_commit" "$source_tree" >&2
			"$script_dir/openwrt-vm.sh" --ref "$source_commit" --output "$qualification" >&2
			qualification_source=generated
		fi
	fi
	verify_qualification_receipt "$qualification" "$source_commit" "$source_tree" ||
		die "qualification receipt does not match this source or required VM gates"
	if [[ "$qualification_source" == explicit && "$qualification" != "$qualification_cache" ]]; then
		qualification_temporary=$qualification_cache.tmp.$$
		rm -f -- "$qualification_temporary"
		cp -- "$qualification" "$qualification_temporary"
		chmod 0600 "$qualification_temporary"
		mv -f -- "$qualification_temporary" "$qualification_cache"
		printf 'deploy-openwrt: qualification_cache=%s\n' "$qualification_cache" >&2
	fi
	printf 'deploy-openwrt: qualification=%s\n' "$qualification_source" >&2
	qualification_digest=$(sha256_file "$qualification")
	activation_qualified=true
fi

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/opl-netfleet-deploy.XXXXXX")
trap 'rm -rf -- "$work_dir"' EXIT
source_dir=$work_dir/source
bundle_dir=$work_dir/bundle
payload_dir=$work_dir/payload
mkdir -p "$source_dir" "$bundle_dir" "$payload_dir"

if [[ "$release_mode" == package ]]; then
	git -C "$repo_dir" archive "$source_commit" scripts/deploy-openwrt-remote.sh openwrt/files/etc/opl-netfleet/rulesets.lock.json |
		tar -C "$source_dir" -xf -
else
	git -C "$repo_dir" archive "$source_commit" openwrt scripts/deploy-openwrt-remote.sh |
		tar -C "$source_dir" -xf -
fi

required=(
	"openwrt/files/usr/libexec/opl-netfleet/main.uc"
	"openwrt/files/usr/libexec/opl-netfleet/supervisor.uc"
	"openwrt/files/usr/libexec/opl-netfleet/output.uc"
	"openwrt/files/usr/libexec/rpcd/opl-netfleet"
	"openwrt/files/etc/init.d/opl-netfleet"
	"openwrt/files/etc/opl-netfleet/policy.example.json"
	"openwrt/files/etc/opl-netfleet/policy-sources/base-v1.json"
	"openwrt/files/etc/opl-netfleet/rulesets.lock.json"
	"openwrt/luci-app-netfleet/htdocs/luci-static/resources/netfleet/api.js"
	"openwrt/luci-app-netfleet/htdocs/luci-static/resources/netfleet/config.js"
	"openwrt/luci-app-netfleet/htdocs/luci-static/resources/netfleet/native.css"
	"openwrt/luci-app-netfleet/htdocs/luci-static/resources/view/netfleet/overview.js"
	"openwrt/luci-app-netfleet/root/usr/share/luci/menu.d/luci-app-netfleet.json"
	"openwrt/luci-app-netfleet/root/usr/share/rpcd/acl.d/luci-app-netfleet.json"
	"scripts/deploy-openwrt-remote.sh"
)
if [[ "$release_mode" == source ]]; then
	for path in "${required[@]}"; do
		[[ -f "$source_dir/$path" ]] || die "source artifact is incomplete: $path"
	done
fi

if [[ "$release_mode" == source ]]; then
	mkdir -p "$payload_dir/usr/libexec" "$payload_dir/usr/libexec/rpcd" \
		"$payload_dir/etc/opl-netfleet" "$payload_dir/etc/init.d" "$payload_dir/www" \
		"$payload_dir/usr/share/luci" "$payload_dir/usr/share/rpcd"
	cp -R "$source_dir/openwrt/files/usr/libexec/opl-netfleet" "$payload_dir/usr/libexec/"
	cp "$source_dir/openwrt/files/usr/libexec/rpcd/opl-netfleet" \
		"$payload_dir/usr/libexec/rpcd/opl-netfleet"
	cp "$source_dir/openwrt/files/etc/init.d/opl-netfleet" \
		"$payload_dir/etc/init.d/opl-netfleet"
	cp -R "$source_dir/openwrt/files/etc/opl-netfleet/." "$payload_dir/etc/opl-netfleet/"
	cp -R "$source_dir/openwrt/luci-app-netfleet/htdocs/." "$payload_dir/www/"
	cp -R "$source_dir/openwrt/luci-app-netfleet/root/." "$payload_dir/"
	view_version="v${product_version//./_}"
	view_source="$payload_dir/www/luci-static/resources/view/netfleet/overview.js"
	view_target="$payload_dir/www/luci-static/resources/view/netfleet/overview-${view_version}.js"
	mv "$view_source" "$view_target"
	grep -Fq "\"path\": \"netfleet/overview-${view_version}\"" \
		"$payload_dir/usr/share/luci/menu.d/luci-app-netfleet.json" ||
		die "LuCI menu view does not match package version: $product_version"
fi

policy_schema=""
if [[ "$release_mode" == source ]]; then
	find "$payload_dir" -type f -exec chmod 0644 {} +
	chmod 0755 "$payload_dir/usr/libexec/opl-netfleet/main.uc" \
		"$payload_dir/usr/libexec/opl-netfleet/supervisor.uc" \
		"$payload_dir/usr/libexec/rpcd/opl-netfleet" \
		"$payload_dir/etc/init.d/opl-netfleet"
	if command -v xattr >/dev/null 2>&1; then
		xattr -cr "$payload_dir" >/dev/null 2>&1 || die "cannot sanitize temporary payload metadata"
	fi
	policy_schema=$(sed -n 's/^[[:space:]]*"schema_version"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
		"$payload_dir/etc/opl-netfleet/policy.example.json" | head -1)
else
	policy_schema=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["policy_schema"])' "$packages_dir/manifest.json")
fi
[[ "$policy_schema" =~ ^[0-9]+$ ]] || die "policy schema is unreadable"

instance=false
policy_digest=""
subscriptions_digest=""
mixin_digest=""
platform_digest=""
rulesets_lock=$source_dir/openwrt/files/etc/opl-netfleet/rulesets.lock.json
[[ -f "$rulesets_lock" ]] || die "source artifact is incomplete: openwrt/files/etc/opl-netfleet/rulesets.lock.json"
rulesets_lock_digest=$(sha256_file "$rulesets_lock")
cp "$rulesets_lock" "$bundle_dir/rulesets.lock.json"
chmod 0644 "$bundle_dir/rulesets.lock.json"
if [[ -n "$instance_dir" ]]; then
	instance=true
	policy_digest=$(sha256_file "$instance_dir/policy.json")
	subscriptions_digest=$(sha256_file "$instance_dir/subscriptions.json")
	mixin_digest=$(sha256_file "$instance_dir/nikki-mixin.yaml")
	platform_digest=$(sha256_file "$instance_dir/platform.json")
	cp "$instance_dir/policy.json" "$bundle_dir/policy.json"
	cp "$instance_dir/subscriptions.json" "$bundle_dir/subscriptions.json"
	cp "$instance_dir/nikki-mixin.yaml" "$bundle_dir/nikki-mixin.yaml"
	cp "$instance_dir/platform.json" "$bundle_dir/platform.json"
	chmod 0600 "$bundle_dir/policy.json"
	chmod 0600 "$bundle_dir/subscriptions.json"
	chmod 0600 "$bundle_dir/nikki-mixin.yaml"
	chmod 0600 "$bundle_dir/platform.json"
fi
if [[ "$release_mode" == package ]]; then
	cp "$packages_dir/manifest.json" "$bundle_dir/package-manifest.json"
	while IFS= read -r name; do
		cp "$packages_dir/$name" "$bundle_dir/$name"
	done < <(python3 - "$packages_dir/manifest.json" <<'PY'
import json, sys
value=json.load(open(sys.argv[1]))
for name in ('opl-netfleet', 'luci-app-netfleet'):
    print(value['artifact_files'][name])
key=value.get('apk_public_key')
if key:
    print(key['name'])
feed=value.get('feed_index')
if feed:
    print(feed['name'])
PY
	)
fi

files_manifest=$bundle_dir/FILES.sha256
if [[ "$release_mode" == package ]]; then
	cp "$packages_dir/FILES.sha256" "$files_manifest"
else
	: >"$files_manifest"
	while IFS= read -r path; do
		relative=${path#"$payload_dir"/}
		[[ "$relative" != "$path" && "$relative" != *" "* && "$relative" != *$'\n'* ]] ||
			die "unsupported payload path: $path"
		printf '%s  %s\n' "$(sha256_file "$path")" "$relative" >>"$files_manifest"
	done < <(find "$payload_dir" -type f | LC_ALL=C sort)
fi
file_count=$(wc -l <"$files_manifest" | tr -d ' ')

runtime_files_manifest=$work_dir/RUNTIME_FILES.sha256
: >"$runtime_files_manifest"
while read -r expected path extra; do
	[[ -n "$expected" ]] || continue
	[[ -z "${extra:-}" ]] || die "invalid payload manifest entry: $path"
	case "$path" in
		www/luci-static/resources/netfleet/*|\
		www/luci-static/resources/view/netfleet/*|\
		usr/share/luci/menu.d/luci-app-netfleet.json)
			continue
			;;
	esac
	printf '%s  %s\n' "$expected" "$path" >>"$runtime_files_manifest"
done <"$files_manifest"
runtime_payload_digest=$(sha256_file "$runtime_files_manifest")
if [[ "$release_mode" == package ]]; then
	manifest_runtime_digest=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["runtime_payload_sha256"])' "$packages_dir/manifest.json")
	[[ "$runtime_payload_digest" == "$manifest_runtime_digest" ]] || die "package runtime identity mismatch"
fi

if [[ "$release_mode" == source ]]; then
	COPYFILE_DISABLE=1 tar --no-xattrs -C "$payload_dir" -cf "$bundle_dir/payload.tar" .
fi
cp "$source_dir/scripts/deploy-openwrt-remote.sh" "$bundle_dir/deploy-openwrt-remote.sh"
chmod 0755 "$bundle_dir/deploy-openwrt-remote.sh"
if [[ "$instance" == "true" ]]; then
	printf '{"schema":"opl-netfleet-deploy-bundle.v5","product_version":"%s","source_commit":"%s","source_tree":"%s","policy_schema":%s,"file_count":%s,"runtime_payload_sha256":"%s","release_mode":"%s","release_format":"%s","instance":true,"policy_sha256":"%s","subscriptions_sha256":"%s","nikki_mixin_sha256":"%s","platform_sha256":"%s","rulesets_lock_sha256":"%s","activation_qualified":%s,"qualification_sha256":"%s"}\n' \
		"$product_version" "$source_commit" "$source_tree" "$policy_schema" "$file_count" "$runtime_payload_digest" "$release_mode" "$release_format" "$policy_digest" "$subscriptions_digest" "$mixin_digest" "$platform_digest" "$rulesets_lock_digest" "$activation_qualified" "$qualification_digest" >"$bundle_dir/bundle.json"
else
	printf '{"schema":"opl-netfleet-deploy-bundle.v5","product_version":"%s","source_commit":"%s","source_tree":"%s","policy_schema":%s,"file_count":%s,"runtime_payload_sha256":"%s","release_mode":"%s","release_format":"%s","instance":false,"rulesets_lock_sha256":"%s","activation_qualified":%s,"qualification_sha256":"%s"}\n' \
		"$product_version" "$source_commit" "$source_tree" "$policy_schema" "$file_count" "$runtime_payload_digest" "$release_mode" "$release_format" "$rulesets_lock_digest" "$activation_qualified" "$qualification_digest" >"$bundle_dir/bundle.json"
fi

(
	cd "$bundle_dir"
	: >SHA256SUMS
	for path in FILES.sha256 bundle.json deploy-openwrt-remote.sh rulesets.lock.json; do
		printf '%s  %s\n' "$(sha256_file "$path")" "$path" >>SHA256SUMS
	done
	if [[ "$release_mode" == source ]]; then
		printf '%s  %s\n' "$(sha256_file payload.tar)" payload.tar >>SHA256SUMS
	fi
	if [[ "$instance" == "true" ]]; then
		{
			printf '%s  %s\n' "$(sha256_file policy.json)" policy.json
			printf '%s  %s\n' "$(sha256_file subscriptions.json)" subscriptions.json
			printf '%s  %s\n' "$(sha256_file nikki-mixin.yaml)" nikki-mixin.yaml
			printf '%s  %s\n' "$(sha256_file platform.json)" platform.json
		} >>SHA256SUMS
	fi
	if [[ "$release_mode" == package ]]; then
		printf '%s  %s\n' "$(sha256_file package-manifest.json)" package-manifest.json >>SHA256SUMS
		for package_file in *.$release_format opl-netfleet-apk.pem packages.adb; do
			[[ -f "$package_file" ]] || continue
			printf '%s  %s\n' "$(sha256_file "$package_file")" "$package_file" >>SHA256SUMS
		done
	fi
)
if command -v xattr >/dev/null 2>&1; then
	xattr -cr "$bundle_dir" >/dev/null 2>&1 || die "cannot sanitize temporary bundle metadata"
fi

if ((dry_run)); then
	mode=stage
	((leave_disabled)) && mode=leave_disabled
	((activate)) && mode=activate
	((presentation_only)) && mode=presentation_only
	finished_ms=$(epoch_ms)
	prepare_elapsed_ms=$((finished_ms - started_ms))
	printf 'deploy-openwrt: prepare_elapsed_ms=%s\n' "$prepare_elapsed_ms" >&2
	printf '{"ok":true,"action":"bundle","target":"%s","product_version":"%s","source_commit":"%s","source_tree":"%s","policy_schema":%s,"file_count":%s,"instance":%s,"mode":"%s","release_mode":"%s","release_format":"%s","activation_qualified":%s,"qualification_source":"%s","prepare_elapsed_ms":%s}\n' \
		"$target" "$product_version" "$source_commit" "$source_tree" "$policy_schema" "$file_count" "$instance" "$mode" "$release_mode" "$release_format" "$activation_qualified" "$qualification_source" "$prepare_elapsed_ms"
	exit 0
fi

ssh_bin=${OPL_NETFLEET_SSH_BIN:-ssh}
command -v "$ssh_bin" >/dev/null 2>&1 || die "ssh client is unavailable: $ssh_bin"
remote_mode=--stage-only
((leave_disabled)) && remote_mode=--leave-disabled
((activate)) && remote_mode=--preserve-state
((presentation_only)) && remote_mode=--presentation-only
[[ "$instance" != "true" ]] || remote_mode="$remote_mode --instance"

	bundle_ready_ms=$(epoch_ms)
	tar --no-xattrs -C "$bundle_dir" -cf - . | "$ssh_bin" -o BatchMode=yes -o ConnectTimeout=10 "$target" \
	"set -eu; stage=\$(mktemp -d /tmp/opl-netfleet-deploy.XXXXXX); trap 'rm -rf -- \"\$stage\"' EXIT; tar -C \"\$stage\" -xf -; /bin/sh \"\$stage/deploy-openwrt-remote.sh\" --bundle \"\$stage\" $remote_mode"
	finished_ms=$(epoch_ms)
	printf 'deploy-openwrt: prepare_elapsed_ms=%s transfer_and_target_elapsed_ms=%s total_elapsed_ms=%s\n' \
		$((bundle_ready_ms - started_ms)) $((finished_ms - bundle_ready_ms)) $((finished_ms - started_ms)) >&2
