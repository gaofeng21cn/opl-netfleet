#!/usr/bin/env python3
"""Host-side OpenWrt deployment orchestrator for OPL NetFleet.

Builds and verifies signed OpenWrt package deployment bundles (apk/ipk) and
orchestrates bundle upload + zero-Python router-side atomic switch gate
execution via pyinfra.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import io
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
from typing import Any

USAGE_TEXT = """Usage: scripts/deploy-openwrt.sh <ssh-target> [options]

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
"""

LEGACY_PACKAGE_VERSIONS = frozenset({"0.2.0", "0.3.0", "0.3.1", "0.3.2", "0.3.3", "0.4.0"})

REQUIRED_VM_CHECKS = (
    "boot",
    "ssh",
    "var_symlink",
    "ubus",
    "deploy_failure_rollback",
    "post_failure_management",
)

PLATFORM_BOOL_FIELDS = frozenset({
    "scheduled_restart",
    "test_profile",
    "fast_reload",
    "api_secret_required",
    "allow_lan",
    "selection_cache",
    "log_clear_at_stop",
    "ipv6",
    "unified_delay",
    "tcp_concurrent",
    "tun_enabled",
    "dns_enabled",
    "dns_ipv6",
    "fake_ip_cache",
    "sniffer_enabled",
    "sniffer_force_dns_mapping",
    "sniffer_parse_pure_ip",
    "sniffer_override_destination",
    "ipv4_dns_hijack",
    "ipv6_dns_hijack",
    "ipv4_proxy",
    "ipv6_proxy",
    "fake_ip_ping_hijack",
    "bypass_china_mainland_ip",
    "bypass_china_mainland_ip6",
})

PLATFORM_STRING_FIELDS = frozenset({
    "api_listen",
    "log_level",
    "dns_cache_algorithm",
    "dns_mode",
    "tcp_mode",
    "udp_mode",
})

LUCI_PRESENTATION_PREFIXES = (
    "www/luci-static/resources/netfleet/",
    "www/luci-static/resources/view/netfleet/",
)

LUCI_PRESENTATION_EXACT = frozenset({
    "usr/share/luci/menu.d/luci-app-netfleet.json",
    "usr/share/rpcd/acl.d/luci-app-netfleet.json",
})

INSTANCE_FILES = (
    "policy.json",
    "subscriptions.json",
    "nikki-mixin.yaml",
    "platform.json",
)


class DeployError(RuntimeError):
    """Structured host-side preflight or deployment error."""


@dataclass(frozen=True)
class PackageRelease:
    directory: Path
    manifest: dict[str, Any]
    package_format: str
    package_arch: str
    build_target_arch: str | None
    policy_schema: int
    runtime_payload_sha256: str
    file_count: int
    bundle_files: tuple[str, ...]


@dataclass(frozen=True)
class QualificationResult:
    qualified: bool
    source: str
    digest: str


def die(message: str) -> None:
    raise DeployError(message)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def now_ms() -> int:
    return time.time_ns() // 1_000_000


def sanitize_log_token(value: Any) -> str:
    return re.sub(r"[^A-Za-z0-9_.:@+-]", "?", str(value))


def is_presentation_path(rel_path: str) -> bool:
    return rel_path.startswith(LUCI_PRESENTATION_PREFIXES) or rel_path in LUCI_PRESENTATION_EXACT


def validate_instance_bundle(instance_dir: Path) -> str:
    if not instance_dir.is_dir():
        die(f"deployment bundle directory is unavailable: {instance_dir}")
    for name in INSTANCE_FILES:
        if not (instance_dir / name).is_file():
            die(f"deployment bundle file is unavailable: {instance_dir / name}")

    try:
        policy = json.loads((instance_dir / "policy.json").read_text(encoding="utf-8"))
        platform = json.loads((instance_dir / "platform.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        die(f"deployment bundle JSON is invalid: {exc}")

    target = policy.get("main", {}).get("target") if isinstance(policy.get("main"), dict) else None
    if platform.get("schema_version") != 1 or set(platform) != {"schema_version", "target", "nikki", "openwrt"}:
        die("platform schema is unsupported")
    if not isinstance(target, str) or platform.get("target") != target:
        die("platform target does not match policy target")

    nikki = platform.get("nikki")
    if not isinstance(nikki, dict) or set(nikki) != PLATFORM_BOOL_FIELDS | PLATFORM_STRING_FIELDS:
        die("platform Nikki fields are invalid")
    if any(not isinstance(nikki[name], bool) for name in PLATFORM_BOOL_FIELDS) or any(
        not isinstance(nikki[name], str) or not nikki[name] for name in PLATFORM_STRING_FIELDS
    ):
        die("platform Nikki values are invalid")
    if (
        nikki["api_listen"] != "0.0.0.0:9090"
        or nikki["log_level"] not in {"error", "warning", "info"}
        or nikki["dns_cache_algorithm"] not in {"lru", "arc"}
    ):
        die("platform controller, log or DNS cache value is invalid")
    if not nikki["api_secret_required"] or not nikki["allow_lan"]:
        die("platform API secret and LAN listeners must be required")
    if nikki["dns_mode"] != "redir-host" or nikki["tcp_mode"] != "tproxy" or nikki["udp_mode"] != "tproxy":
        die("platform must use redir-host and TCP/UDP TProxy")
    if nikki["tun_enabled"] or nikki["fake_ip_cache"] or nikki["sniffer_override_destination"]:
        die("platform v1 requires TUN, fake-IP cache and destination override off")

    openwrt = platform.get("openwrt")
    if (
        not isinstance(openwrt, dict)
        or set(openwrt) != {"software_flow_offload", "hardware_flow_offload"}
        or any(not isinstance(value, bool) for value in openwrt.values())
    ):
        die("platform OpenWrt fields are invalid")
    if openwrt["software_flow_offload"] or openwrt["hardware_flow_offload"]:
        die("flow offload requires a separate qualification")

    policy_source = policy.get("policy_source") if isinstance(policy.get("policy_source"), dict) else {}
    recovery_profile = policy.get("recovery_profile") if isinstance(policy.get("recovery_profile"), dict) else {}
    providers = policy.get("providers") if isinstance(policy.get("providers"), dict) else {}
    capabilities = policy.get("capabilities") if isinstance(policy.get("capabilities"), dict) else {}
    provider_roles = ",".join(
        f"{sanitize_log_token(name)}:{sanitize_log_token(value.get('role', 'unspecified'))}"
        for name, value in sorted(providers.items())
        if isinstance(value, dict)
    ) or "none"
    capability_ids = ",".join(sanitize_log_token(name) for name in sorted(capabilities)) or "none"
    return (
        f"policy_source={sanitize_log_token(policy_source.get('ref', 'unset'))} "
        f"recovery_profile={sanitize_log_token(recovery_profile.get('ref', 'unset'))} "
        f"providers={provider_roles} capabilities={capability_ids}"
    )


def verify_qualification_receipt(
    receipt_path: Path,
    source_commit: str,
    source_tree: str,
    packages_dir: Path | None,
) -> bool:
    try:
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return False

    checks = receipt.get("checks")
    valid = (
        receipt.get("schema")
        in {"opl-netfleet-openwrt-vm-qualification.v1", "opl-netfleet-openwrt-vm-qualification.v2"}
        and receipt.get("qualified") is True
        and receipt.get("source_commit") == source_commit
        and receipt.get("source_tree") == source_tree
        and isinstance(checks, dict)
        and all(checks.get(name) is True for name in REQUIRED_VM_CHECKS)
    )
    if valid and receipt.get("schema") == "opl-netfleet-openwrt-vm-qualification.v2":
        valid = receipt.get("package_qualified") is True
        package = receipt.get("package")
        if valid and packages_dir is not None:
            try:
                manifest_sha = sha256_file(packages_dir / "manifest.json")
            except OSError:
                return False
            valid = isinstance(package, dict) and package.get("manifest_sha256") == manifest_sha
    return valid


def resolve_cache_root(purpose: str) -> Path:
    cache_root = os.environ.get("XDG_CACHE_HOME") or (
        str(Path(os.environ["HOME"]) / ".cache") if os.environ.get("HOME") else ""
    )
    if not cache_root or not cache_root.startswith("/"):
        die(f"XDG_CACHE_HOME or HOME is required for the {purpose}")
    return Path(cache_root)


def git_output(repo_dir: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo_dir), *args],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        die(result.stderr.strip() or f"git command failed: {' '.join(args)}")
    return result.stdout


def resolve_source_identity(repo_dir: Path, source_ref: str) -> tuple[str, str, str]:
    if source_ref == "origin/main":
        subprocess.run(
            ["git", "-C", str(repo_dir), "fetch", "--quiet", "origin", "main"],
            check=True,
        )
    commit_res = subprocess.run(
        ["git", "-C", str(repo_dir), "rev-parse", "--verify", f"{source_ref}^{{commit}}"],
        text=True,
        capture_output=True,
        check=False,
    )
    if commit_res.returncode != 0:
        die(f"source ref does not resolve to a commit: {source_ref}")
    source_commit = commit_res.stdout.strip()
    source_tree = git_output(repo_dir, "rev-parse", f"{source_commit}^{{tree}}").strip()
    if not re.fullmatch(r"[0-9a-f]{40}", source_commit) or not re.fullmatch(r"[0-9a-f]{40}", source_tree):
        die("invalid source identity")

    makefile = git_output(repo_dir, "show", f"{source_commit}:openwrt/Makefile")
    match = re.search(r"^PKG_VERSION:=([0-9][0-9A-Za-z.+~-]*)$", makefile, flags=re.MULTILINE)
    if not match:
        die("NetFleet product version is unreadable")
    product_version = match.group(1)

    luci_makefile = git_output(repo_dir, "show", f"{source_commit}:openwrt/luci-app-netfleet/Makefile")
    if not re.search(r"^PKG_VERSION:=([0-9][0-9A-Za-z.+~-]*)$", luci_makefile, flags=re.MULTILINE):
        die("LuCI package version is unreadable")
    return source_commit, source_tree, product_version


def download_release_packages(repo_dir: Path, release_tag: str) -> Path:
    if not shutil.which("gh"):
        die("gh is required to download release packages")
    cache_root = resolve_cache_root("release cache")
    remote_url = git_output(repo_dir, "remote", "get-url", "origin").strip()
    if remote_url.startswith("git@github.com:"):
        release_repo = remote_url.removeprefix("git@github.com:").removesuffix(".git")
    elif remote_url.startswith("https://github.com/"):
        release_repo = remote_url.removeprefix("https://github.com/").removesuffix(".git")
    else:
        die("origin is not a supported GitHub repository")

    if release_tag == "latest":
        view = subprocess.run(
            ["gh", "release", "view", "--repo", release_repo, "--json", "tagName", "--jq", ".tagName"],
            text=True,
            capture_output=True,
            check=False,
        )
        if view.returncode != 0 or not view.stdout.strip():
            die("failed to resolve latest GitHub release tag")
        release_tag = view.stdout.strip()

    if not re.fullmatch(r"[A-Za-z0-9._+-]+", release_tag):
        die("release tag contains unsupported characters")

    packages_dir = cache_root / "opl-netfleet" / "releases" / release_tag
    if not (packages_dir / "manifest.json").is_file():
        packages_dir.parent.mkdir(parents=True, exist_ok=True)
        download_dir = Path(tempfile.mkdtemp(prefix="opl-netfleet-release."))
        try:
            subprocess.run(
                ["gh", "release", "download", release_tag, "--repo", release_repo, "--dir", str(download_dir)],
                check=True,
            )
            os.chmod(download_dir, 0o700)
            shutil.move(str(download_dir), str(packages_dir))
        except Exception:
            shutil.rmtree(download_dir, ignore_errors=True)
            raise
    return packages_dir


def verify_package_release(packages_dir: Path, source_commit: str, source_tree: str) -> PackageRelease:
    if not packages_dir.is_dir():
        die(f"package directory is unavailable: {packages_dir}")
    resolved_dir = packages_dir.resolve()
    try:
        manifest = json.loads((resolved_dir / "manifest.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        die(f"package manifest is unreadable: {exc}")

    if manifest.get("schema") != "opl-netfleet-package-manifest.v2":
        die("package manifest schema is unsupported")
    if manifest.get("source_commit") != source_commit or manifest.get("source_tree") != source_tree:
        die("package manifest does not match the selected source")

    package_format = manifest.get("package_format")
    if package_format not in {"apk", "ipk"}:
        die("package format is unsupported")

    arch = manifest.get("package_arch")
    if not isinstance(arch, str) or not re.fullmatch(r"[A-Za-z0-9_.+-]+", arch):
        die("package architecture is invalid")

    package_version = manifest.get("package_version")
    build_target_arch = manifest.get("build_target_arch")
    if build_target_arch is None and package_version not in LEGACY_PACKAGE_VERSIONS:
        die("package build target architecture is missing")
    if build_target_arch is not None and (
        not isinstance(build_target_arch, str) or not re.fullmatch(r"[A-Za-z0-9_.+-]+", build_target_arch)
    ):
        die("package build target architecture is invalid")
    if package_format == "apk" and package_version not in LEGACY_PACKAGE_VERSIONS and arch != "noarch":
        die("release APK architecture must be noarch")

    files_manifest = manifest.get("files_manifest")
    if not isinstance(files_manifest, dict):
        die("package manifest missing files_manifest")

    artifacts = manifest.get("artifacts")
    package_names = (
        [item.get("package") for item in artifacts if isinstance(item, dict)]
        if isinstance(artifacts, list)
        else []
    )
    if (
        len(package_names) != len(artifacts or [])
        or len(set(package_names)) != len(package_names)
        or not {"opl-netfleet", "opl-netfleet-kernel", "luci-app-netfleet"}.issubset(package_names)
        or any(
            not isinstance(name, str)
            or not re.fullmatch(r"(?:opl-netfleet(?:-kernel|-plugin-[a-z][a-z0-9-]*)?|luci-app-netfleet)", name)
            for name in package_names
        )
    ):
        die("package artifact set is invalid")

    artifact_files = manifest.get("artifact_files")
    if not isinstance(artifact_files, dict) or artifact_files != {item["package"]: item["name"] for item in artifacts}:
        die("package artifact mapping is invalid")

    required_items: list[dict[str, Any]] = [files_manifest, *artifacts]
    bundle_files: list[str] = list(artifact_files.values())
    key = manifest.get("apk_public_key")
    if package_format == "apk":
        if not isinstance(key, dict):
            die("signed APK release is missing its public key")
        required_items.append(key)
        bundle_files.append(str(key["name"]))
        feed_index = manifest.get("feed_index")
        if feed_index is not None:
            if not isinstance(feed_index, dict) or feed_index.get("name") != "packages.adb":
                die("APK release feed index identity is invalid")
            required_items.append(feed_index)
            bundle_files.append(str(feed_index["name"]))
        elif package_version not in LEGACY_PACKAGE_VERSIONS:
            die("APK release is missing packages.adb feed index")
    elif key is not None:
        die("IPK release must not declare an APK key")

    seen_names = {"manifest.json"}
    for item in required_items:
        name, digest = item.get("name"), item.get("sha256")
        if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9_.+-]+", name) or name in seen_names:
            die("package artifact name is invalid")
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            die("package artifact digest is invalid")
        path = resolved_dir / name
        if not path.is_file() or sha256_file(path) != digest:
            die(f"package artifact identity mismatch: {name}")
        seen_names.add(name)

    policy_schema = manifest.get("policy_schema")
    if not isinstance(policy_schema, int) or isinstance(policy_schema, bool) or policy_schema < 0:
        die("policy schema is unreadable")

    files_lines = (resolved_dir / "FILES.sha256").read_text(encoding="utf-8").splitlines()
    runtime_lines: list[str] = []
    file_count = 0
    for line in files_lines:
        stripped = line.strip()
        if not stripped:
            continue
        parts = stripped.split()
        if len(parts) != 2:
            die(f"invalid payload manifest entry: {stripped}")
        file_count += 1
        expected_hash, rel_path = parts
        if not is_presentation_path(rel_path):
            runtime_lines.append(f"{expected_hash}  {rel_path}\n")
    runtime_digest = sha256_bytes("".join(runtime_lines).encode("utf-8"))
    if runtime_digest != manifest.get("runtime_payload_sha256"):
        die("package runtime identity mismatch")

    return PackageRelease(
        directory=resolved_dir,
        manifest=manifest,
        package_format=package_format,
        package_arch=arch,
        build_target_arch=build_target_arch,
        policy_schema=policy_schema,
        runtime_payload_sha256=runtime_digest,
        file_count=file_count,
        bundle_files=tuple(bundle_files),
    )


def resolve_qualification(
    *,
    activate: bool,
    explicit_path: Path | None,
    script_dir: Path,
    source_commit: str,
    source_tree: str,
    release: PackageRelease,
) -> QualificationResult:
    if not activate:
        return QualificationResult(qualified=False, source="none", digest="")

    cache_root = resolve_cache_root("VM qualification cache")
    qualification_dir = cache_root / "opl-netfleet" / "vm-qualifications"
    qualification_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(qualification_dir, 0o700)
    qualification_cache = qualification_dir / f"{source_commit}-{source_tree}.json"

    if explicit_path is not None:
        qualification = explicit_path
        qualification_source = "explicit"
    else:
        qualification = qualification_cache
        if qualification.is_file() and verify_qualification_receipt(
            qualification, source_commit, source_tree, release.directory
        ):
            qualification_source = "cache"
        else:
            print(
                f"deploy-openwrt: qualification=generate commit={source_commit} tree={source_tree}",
                file=sys.stderr,
            )
            vm_cmd = [str(script_dir / "openwrt-vm.sh"), "--ref", source_commit, "--output", str(qualification)]
            if release.package_format == "apk":
                vm_cmd.extend(["--packages", str(release.directory)])
            subprocess.run(vm_cmd, stdout=sys.stderr, check=True)
            qualification_source = "generated"

    if not verify_qualification_receipt(qualification, source_commit, source_tree, release.directory):
        die("qualification receipt does not match this source or required VM gates")

    if qualification_source == "explicit" and qualification.resolve() != qualification_cache.resolve():
        temp_cache = qualification_cache.with_name(f"{qualification_cache.name}.tmp.{os.getpid()}")
        temp_cache.unlink(missing_ok=True)
        shutil.copyfile(qualification, temp_cache)
        os.chmod(temp_cache, 0o600)
        os.replace(temp_cache, qualification_cache)
        print(f"deploy-openwrt: qualification_cache={qualification_cache}", file=sys.stderr)

    print(f"deploy-openwrt: qualification={qualification_source}", file=sys.stderr)
    return QualificationResult(
        qualified=True,
        source=qualification_source,
        digest=sha256_file(qualification),
    )


def extract_git_files(repo_dir: Path, source_commit: str, dest: Path, paths: tuple[str, ...]) -> None:
    proc = subprocess.run(
        ["git", "-C", str(repo_dir), "archive", "--format=tar", source_commit, *paths],
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        die(proc.stderr.decode("utf-8", errors="replace").strip() or "git archive failed")
    with tarfile.open(fileobj=io.BytesIO(proc.stdout), mode="r:") as archive:
        archive.extractall(dest, filter="data")


def build_bundle_directory(
    *,
    bundle_dir: Path,
    repo_dir: Path,
    source_commit: str,
    source_tree: str,
    product_version: str,
    release: PackageRelease,
    instance_dir: Path | None,
    qualification: QualificationResult,
) -> dict[str, Any]:
    source_stage = bundle_dir.parent / "source"
    source_stage.mkdir(parents=True, exist_ok=True)
    extract_git_files(
        repo_dir,
        source_commit,
        source_stage,
        ("scripts/deploy-openwrt-remote.sh", "openwrt/files/etc/opl-netfleet/rulesets.lock.json"),
    )
    remote_script = source_stage / "scripts/deploy-openwrt-remote.sh"
    rulesets_lock = source_stage / "openwrt/files/etc/opl-netfleet/rulesets.lock.json"
    if not remote_script.is_file():
        die("source artifact is incomplete: scripts/deploy-openwrt-remote.sh")
    if not rulesets_lock.is_file():
        die("source artifact is incomplete: openwrt/files/etc/opl-netfleet/rulesets.lock.json")

    shutil.copyfile(remote_script, bundle_dir / "deploy-openwrt-remote.sh")
    os.chmod(bundle_dir / "deploy-openwrt-remote.sh", 0o755)
    shutil.copyfile(rulesets_lock, bundle_dir / "rulesets.lock.json")
    os.chmod(bundle_dir / "rulesets.lock.json", 0o644)
    shutil.copyfile(release.directory / "FILES.sha256", bundle_dir / "FILES.sha256")
    os.chmod(bundle_dir / "FILES.sha256", 0o644)
    shutil.copyfile(release.directory / "manifest.json", bundle_dir / "package-manifest.json")
    os.chmod(bundle_dir / "package-manifest.json", 0o644)

    for rel_name in release.bundle_files:
        target_file = bundle_dir / rel_name
        shutil.copyfile(release.directory / rel_name, target_file)
        os.chmod(target_file, 0o644)

    bundle_manifest: dict[str, Any] = {
        "schema": "opl-netfleet-deploy-bundle.v5",
        "product_version": product_version,
        "source_commit": source_commit,
        "source_tree": source_tree,
        "policy_schema": release.policy_schema,
        "file_count": release.file_count,
        "runtime_payload_sha256": release.runtime_payload_sha256,
        "release_mode": "package",
        "release_format": release.package_format,
        "instance": instance_dir is not None,
        "rulesets_lock_sha256": sha256_file(bundle_dir / "rulesets.lock.json"),
        "activation_qualified": qualification.qualified,
        "qualification_sha256": qualification.digest,
    }

    if instance_dir is not None:
        digest_keys = (
            ("policy.json", "policy_sha256"),
            ("subscriptions.json", "subscriptions_sha256"),
            ("nikki-mixin.yaml", "nikki_mixin_sha256"),
            ("platform.json", "platform_sha256"),
        )
        for filename, key_name in digest_keys:
            dst = bundle_dir / filename
            shutil.copyfile(instance_dir / filename, dst)
            os.chmod(dst, 0o600)
            bundle_manifest[key_name] = sha256_file(dst)

    (bundle_dir / "bundle.json").write_text(
        json.dumps(bundle_manifest, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )
    os.chmod(bundle_dir / "bundle.json", 0o644)

    checksum_files = [
        "FILES.sha256",
        "bundle.json",
        "deploy-openwrt-remote.sh",
        "rulesets.lock.json",
        "package-manifest.json",
        *release.bundle_files,
    ]
    if instance_dir is not None:
        checksum_files.extend(INSTANCE_FILES)

    sums_lines = [f"{sha256_file(bundle_dir / name)}  {name}\n" for name in checksum_files]
    (bundle_dir / "SHA256SUMS").write_text("".join(sums_lines), encoding="utf-8")
    os.chmod(bundle_dir / "SHA256SUMS", 0o644)
    return bundle_manifest


def build_bundle_archive(bundle_dir: Path, archive_path: Path) -> Path:
    """Create a deterministic GNU-format tar archive strictly free of xattrs."""
    with tarfile.open(archive_path, "w", format=tarfile.GNU_FORMAT) as archive:
        for path in sorted(bundle_dir.rglob("*")):
            if path.name.startswith("._"):
                continue
            rel = path.relative_to(bundle_dir).as_posix()
            info = archive.gettarinfo(str(path), arcname=rel)
            info.uid = 0
            info.gid = 0
            info.uname = ""
            info.gname = ""
            info.pax_headers = {}
            if path.is_file():
                with path.open("rb") as stream:
                    archive.addfile(info, stream)
            else:
                archive.addfile(info)
    os.chmod(archive_path, 0o600)
    return archive_path


def parse_pyinfra_target(target: str) -> tuple[str, dict[str, Any]]:
    """Map an SSH target string or @local connector to pyinfra inventory data."""
    if target == "@local":
        return "@local", {}

    user: str | None = None
    host_part = target
    if "@" in host_part:
        user, host_part = host_part.split("@", 1)

    port: int | None = None
    if ":" in host_part and host_part.count(":") == 1:
        candidate_host, candidate_port = host_part.rsplit(":", 1)
        if candidate_port.isdigit():
            host_part = candidate_host
            port = int(candidate_port)

    transfer_protocol = os.environ.get("OPL_NETFLEET_SSH_TRANSFER_PROTOCOL", "scp").strip().lower()
    if transfer_protocol not in {"scp", "sftp"}:
        die(f"unsupported transfer protocol: {transfer_protocol}")

    data: dict[str, Any] = {
        "ssh_file_transfer_protocol": transfer_protocol,
        "ssh_connect_retries": 1,
    }
    if user:
        data["ssh_user"] = user
    if port is not None:
        data["ssh_port"] = port
    return host_part, data


def deploy_with_pyinfra(
    *,
    target: str,
    bundle_archive: Path,
    remote_flags: list[str],
    remote_env: dict[str, str] | None = None,
) -> tuple[int, str, str]:
    """Upload the xattr-free bundle and run the router-side atomic gate via pyinfra."""
    try:
        from pyinfra.api import Config, Inventory, State
        from pyinfra.api.connect import connect_all, disconnect_all
        from pyinfra.api.exceptions import PyinfraError
        from pyinfra.api.operation import add_op
        from pyinfra.api.operations import run_ops
        from pyinfra.operations import files, server
    except ImportError as exc:
        die(f"pyinfra is required for host deployment orchestration (run via `uv run`): {exc}")

    host_name, host_data = parse_pyinfra_target(target)
    inventory = Inventory(([(host_name, host_data)], {}))
    config = Config(CONNECT_TIMEOUT=10, FAIL_PERCENT=0)
    state = State(inventory, config)

    nonce = secrets.token_hex(8)
    remote_tar = f"/tmp/opl-netfleet-bundle.{nonce}.tar"
    mode_args = " ".join(shlex.quote(flag) for flag in remote_flags)
    env_prefix = ""
    if remote_env:
        env_prefix = " ".join(f"{key}={shlex.quote(val)}" for key, val in remote_env.items()) + " "
    remote_cmd = (
        f"set -eu; tarball={shlex.quote(remote_tar)}; "
        "stage=$(mktemp -d /tmp/opl-netfleet-deploy.XXXXXX); "
        'trap \'rm -rf -- "$stage" "$tarball"\' EXIT; '
        'tar -C "$stage" -xf "$tarball"; '
        f'{env_prefix}/bin/sh "$stage/deploy-openwrt-remote.sh" --bundle "$stage" {mode_args}'
    )

    connect_all(state)
    host = next(iter(inventory))
    try:
        if not host.connected:
            die(f"failed to connect to target via pyinfra: {target}")
        add_op(
            state,
            files.put,
            name="upload-openwrt-deploy-bundle",
            src=str(bundle_archive),
            dest=remote_tar,
            mode="0600",
            create_remote_dir=False,
        )
        op_results = add_op(
            state,
            server.shell,
            name="execute-openwrt-atomic-switch-gate",
            commands=remote_cmd,
        )
        try:
            run_ops(state)
        except PyinfraError as exc:
            if op_results.get(host) is None and "No hosts remaining" not in str(exc):
                raise
    finally:
        disconnect_all(state)

    meta = op_results.get(host)
    if meta is None:
        return 1, "", f"deploy-openwrt: remote operation did not run on {target}\n"
    stdout_text = "\n".join(meta.stdout_lines) + ("\n" if meta.stdout_lines else "")
    stderr_text = "\n".join(meta.stderr_lines) + ("\n" if meta.stderr_lines else "")
    return (0 if meta.did_succeed() else 1), stdout_text, stderr_text


def deploy_with_ssh_bin(
    *,
    ssh_bin: str,
    target: str,
    bundle_archive: Path,
    remote_flags: list[str],
) -> tuple[int, str, str]:
    if not shutil.which(ssh_bin):
        die(f"ssh client is unavailable: {ssh_bin}")
    mode_args = " ".join(shlex.quote(flag) for flag in remote_flags)
    remote_cmd = (
        "set -eu; stage=$(mktemp -d /tmp/opl-netfleet-deploy.XXXXXX); "
        'trap \'rm -rf -- "$stage"\' EXIT; tar -C "$stage" -xf -; '
        f'/bin/sh "$stage/deploy-openwrt-remote.sh" --bundle "$stage" {mode_args}'
    )
    with bundle_archive.open("rb") as archive_stream:
        proc = subprocess.run(
            [ssh_bin, "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", target, remote_cmd],
            stdin=archive_stream,
            text=False,
            capture_output=True,
            check=False,
        )
    return (
        proc.returncode,
        proc.stdout.decode("utf-8", errors="replace"),
        proc.stderr.decode("utf-8", errors="replace"),
    )


def parse_args(argv: list[str]) -> argparse.Namespace:
    if any(arg in {"-h", "--help"} for arg in argv):
        sys.stdout.write(USAGE_TEXT)
        raise SystemExit(0)

    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("target", nargs="?")
    parser.add_argument("--ref", default="origin/main")
    parser.add_argument("--packages", default="")
    parser.add_argument("--release", default="")
    parser.add_argument("--instance", default="")
    parser.add_argument("--leave-disabled", action="store_true")
    parser.add_argument("--activate", action="store_true")
    parser.add_argument("--presentation-only", action="store_true")
    parser.add_argument("--qualification", default="")
    parser.add_argument("--dry-run", action="store_true")

    # Preserve exact CLI error messages expected by callers.
    args, unknown = parser.parse_known_args(argv)
    if unknown:
        first = unknown[0]
        if first.startswith("-"):
            die(f"unknown option: {first}")
        die("only one ssh target is allowed")

    if not args.target:
        die("ssh target is required")
    if args.target.startswith("-"):
        die("ssh target cannot begin with '-'")
    if not re.fullmatch(r"^[A-Za-z0-9._@%:+-]+$", args.target):
        die("ssh target contains unsupported characters")
    if args.ref.startswith("-"):
        die("source ref cannot begin with '-'")
    if args.packages and args.release:
        die("--packages and --release are mutually exclusive")
    if not args.packages and not args.release:
        die("--packages or --release is required (legacy source-overlay deployment is retired)")
    if sum(bool(flag) for flag in (args.activate, args.leave_disabled, args.presentation_only)) > 1:
        die("--activate, --leave-disabled and --presentation-only are mutually exclusive")
    if args.presentation_only and not args.instance:
        die("--presentation-only requires --instance")
    if args.qualification and not args.activate:
        die("--qualification is only valid with --activate")
    return args


def main(argv: list[str] | None = None) -> int:
    started_ms = now_ms()
    try:
        args = parse_args(sys.argv[1:] if argv is None else argv)

        qualification_path: Path | None = None
        if args.qualification:
            candidate = Path(args.qualification)
            if not candidate.is_file():
                die(f"qualification receipt is unavailable: {args.qualification}")
            qualification_path = candidate.resolve()

        instance_dir: Path | None = None
        if args.instance:
            instance_dir = Path(args.instance).resolve()
            summary = validate_instance_bundle(instance_dir)
            print(f"deploy-openwrt: deployment bundle {summary}", file=sys.stderr)

        script_dir = Path(__file__).resolve().parent
        repo_dir = Path(git_output(script_dir.parent, "rev-parse", "--show-toplevel").strip())
        source_commit, source_tree, product_version = resolve_source_identity(repo_dir, args.ref)

        packages_dir = (
            download_release_packages(repo_dir, args.release)
            if args.release
            else Path(args.packages)
        )
        release = verify_package_release(packages_dir, source_commit, source_tree)
        print(
            f"deploy-openwrt: release package format={release.package_format} "
            f"arch={release.package_arch} build_target={release.build_target_arch or 'legacy'}",
            file=sys.stderr,
        )

        qualification = resolve_qualification(
            activate=args.activate,
            explicit_path=qualification_path,
            script_dir=script_dir,
            source_commit=source_commit,
            source_tree=source_tree,
            release=release,
        )

        with tempfile.TemporaryDirectory(prefix="opl-netfleet-deploy.") as tmp_root:
            work_dir = Path(tmp_root)
            bundle_dir = work_dir / "bundle"
            bundle_dir.mkdir(parents=True, exist_ok=True)
            build_bundle_directory(
                bundle_dir=bundle_dir,
                repo_dir=repo_dir,
                source_commit=source_commit,
                source_tree=source_tree,
                product_version=product_version,
                release=release,
                instance_dir=instance_dir,
                qualification=qualification,
            )
            archive_path = build_bundle_archive(bundle_dir, work_dir / "bundle.tar")

            if args.dry_run:
                mode = (
                    "leave_disabled"
                    if args.leave_disabled
                    else "activate"
                    if args.activate
                    else "presentation_only"
                    if args.presentation_only
                    else "stage"
                )
                prepare_elapsed_ms = now_ms() - started_ms
                print(f"deploy-openwrt: prepare_elapsed_ms={prepare_elapsed_ms}", file=sys.stderr)
                receipt = {
                    "ok": True,
                    "action": "bundle",
                    "target": args.target,
                    "product_version": product_version,
                    "source_commit": source_commit,
                    "source_tree": source_tree,
                    "policy_schema": release.policy_schema,
                    "file_count": release.file_count,
                    "instance": instance_dir is not None,
                    "mode": mode,
                    "release_mode": "package",
                    "release_format": release.package_format,
                    "activation_qualified": qualification.qualified,
                    "qualification_source": qualification.source,
                    "prepare_elapsed_ms": prepare_elapsed_ms,
                }
                sys.stdout.write(json.dumps(receipt, separators=(",", ":")) + "\n")
                return 0

            remote_flags = [
                "--leave-disabled"
                if args.leave_disabled
                else "--preserve-state"
                if args.activate
                else "--presentation-only"
                if args.presentation_only
                else "--stage-only"
            ]
            if instance_dir is not None:
                remote_flags.append("--instance")

            bundle_ready_ms = now_ms()
            ssh_override = os.environ.get("OPL_NETFLEET_SSH_BIN")
            if ssh_override:
                rc, stdout_text, stderr_text = deploy_with_ssh_bin(
                    ssh_bin=ssh_override,
                    target=args.target,
                    bundle_archive=archive_path,
                    remote_flags=remote_flags,
                )
            else:
                rc, stdout_text, stderr_text = deploy_with_pyinfra(
                    target=args.target,
                    bundle_archive=archive_path,
                    remote_flags=remote_flags,
                )
            finished_ms = now_ms()
            if stdout_text:
                sys.stdout.write(stdout_text)
            if stderr_text:
                sys.stderr.write(stderr_text)
            print(
                f"deploy-openwrt: prepare_elapsed_ms={bundle_ready_ms - started_ms} "
                f"transfer_and_target_elapsed_ms={finished_ms - bundle_ready_ms} "
                f"total_elapsed_ms={finished_ms - started_ms}",
                file=sys.stderr,
            )
            return rc
    except DeployError as exc:
        print(f"deploy-openwrt: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
