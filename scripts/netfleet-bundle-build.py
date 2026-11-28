#!/usr/bin/env python3
"""Build a deterministic pure-source NetFleet Release Bundle and Ed25519 signature."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SEMVER_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
HEX40_RE = re.compile(r"^[0-9a-f]{40}$")
DEFAULT_SIGN_KEY = Path.home() / ".config/opl-netfleet/keys/netfleet-ed25519-private.pem"


def _semver_tuple(value: str) -> tuple[int, int, int]:
    return tuple(int(part) for part in value.split("."))


def _load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load module from {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def git_identity(repo: Path) -> tuple[str, str]:
    commit = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
    tree = subprocess.check_output(["git", "-C", str(repo), "rev-parse", f"{commit}^{{tree}}"], text=True).strip()
    return commit, tree


def _copy_regular(src: Path, dst: Path, mode: int) -> None:
    if src.is_symlink() or not src.is_file():
        raise ValueError(f"expected regular file: {src}")
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(src, dst)
    dst.chmod(mode)


def _copy_regular_tree(src_dir: Path, dst_dir: Path) -> None:
    if src_dir.is_symlink() or not src_dir.is_dir():
        raise ValueError(f"expected directory: {src_dir}")
    dst_dir.mkdir(parents=True, exist_ok=True)
    for item in sorted(src_dir.iterdir(), key=lambda p: p.name):
        if item.is_symlink():
            raise ValueError(f"symlink disallowed in release bundle source: {item}")
        target = dst_dir / item.name
        if item.is_dir():
            _copy_regular_tree(item, target)
        elif item.is_file():
            mode = 0o755 if (item.stat().st_mode & 0o111) else 0o644
            _copy_regular(item, target, mode)
        else:
            raise ValueError(f"unsupported file type in release bundle: {item}")


def _write_json(path: Path, value: object, mode: int = 0o644) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    path.chmod(mode)


def _deterministic_tar_gz(source_dir: Path, output_tar_gz: Path) -> bytes:
    """Create a reproducible root:root mtime=0 GNU tar.gz of regular files & dirs."""
    tar_buf = io.BytesIO()
    with tarfile.open(fileobj=tar_buf, mode="w", format=tarfile.GNU_FORMAT) as tf:
        entries: list[Path] = []

        def collect(current: Path) -> None:
            for item in sorted(current.iterdir(), key=lambda p: p.name):
                if item.is_symlink():
                    raise ValueError(f"unexpected symlink in release bundle payload: {item}")
                entries.append(item)
                if item.is_dir():
                    collect(item)

        collect(source_dir)
        for item in entries:
            rel = item.relative_to(source_dir).as_posix()
            info = tarfile.TarInfo(name=rel)
            st = item.lstat()
            info.uid = 0
            info.gid = 0
            info.uname = "root"
            info.gname = "root"
            info.mtime = 0
            if item.is_dir():
                info.type = tarfile.DIRTYPE
                info.mode = 0o755
                tf.addfile(info)
            elif item.is_file():
                info.type = tarfile.REGTYPE
                info.mode = 0o755 if (st.st_mode & 0o111) else 0o644
                data = item.read_bytes()
                info.size = len(data)
                tf.addfile(info, io.BytesIO(data))
            else:
                raise ValueError(f"unsupported entry in bundle: {item}")
    gz_buf = io.BytesIO()
    with gzip.GzipFile(fileobj=gz_buf, mode="wb", mtime=0, compresslevel=9) as gz:
        gz.write(tar_buf.getvalue())
    archive_bytes = gz_buf.getvalue()
    output_tar_gz.parent.mkdir(parents=True, exist_ok=True)
    output_tar_gz.write_bytes(archive_bytes)
    output_tar_gz.chmod(0o644)
    return archive_bytes


def stage_bundle_tree(
    repo: Path,
    stage_dir: Path,
    *,
    version: str,
    channel: str,
    source_commit: str,
    source_tree: str,
) -> tuple[dict[str, dict[str, object]], str, list[str]]:
    """Populate runtime/, share/, and www/ inside stage_dir without symlinks."""
    plugin_packages = _load_module("netfleet_plugin_packages", repo / "openwrt/plugin-packages.py")
    plugin_payload = _load_module("netfleet_plugin_payload", repo / "openwrt/plugin_payload.py")

    plugins, services, _ = plugin_packages.composition()
    if "scheduler.control" not in services:
        raise ValueError("default scheduler service is unavailable")
    default_ids = [pid for pid in sorted(plugins) if pid not in plugin_packages.OPTIONAL_PLUGINS]

    runtime_src = repo / "openwrt/files/usr/libexec/opl-netfleet"
    runtime_dst = stage_dir / "runtime"
    _copy_regular(runtime_src / "main.uc", runtime_dst / "main.uc", 0o755)
    _copy_regular(runtime_src / "supervisor.uc", runtime_dst / "supervisor.uc", 0o755)
    for directory in ("kernel", "adapters"):
        for uc_file in sorted((runtime_src / directory).glob("*.uc"), key=lambda p: p.name):
            _copy_regular(uc_file, runtime_dst / directory / uc_file.name, 0o644)

    with tempfile.TemporaryDirectory(prefix="netfleet-bundle-www-") as tmp_www:
        www_tmp = Path(tmp_www)
        for pid in default_ids:
            plugin_src = repo / "plugins" / pid
            _copy_regular_tree(plugin_src, runtime_dst / "plugins" / pid)
            plugin_payload.project_resources(plugin_src, www_tmp)
        projected = www_tmp / "luci-static/resources/netfleet/plugins"
        if projected.is_dir():
            _copy_regular_tree(projected, stage_dir / "www/plugins")

    share_dst = stage_dir / "share"
    system_data = {
        "schema": "opl-netfleet-system.v1",
        "bindings": {name: services[name][0] for name in sorted(services)},
        "enabled": {pid: pid not in plugin_packages.OPTIONAL_PLUGINS for pid in sorted(plugins)},
        "product_packages": ["opl-netfleet-kernel", *(plugins[pid]["package"] for pid in default_ids)],
        "scheduler": {"service": "scheduler.control", "method": "tick"},
        "environment": {"service": "platform.runtime", "method": "environment"},
    }
    _write_json(share_dst / "system.json", system_data, 0o644)
    _write_json(
        share_dst / "build.json",
        {
            "version": version,
            "channel": channel,
            "delivery": "release-bundle",
            "source_commit": source_commit,
            "source_tree": source_tree,
        },
        0o644,
    )
    _copy_regular_tree(repo / "openwrt/files/usr/share/opl-netfleet/nikki", share_dst / "nikki")
    _copy_regular(repo / "openwrt/files/etc/config/netfleet", share_dst / "netfleet.config", 0o644)
    _copy_regular(repo / "LICENSE", share_dst / "LICENSE.Apache-2.0", 0o644)

    etc_src = repo / "openwrt/files/etc/opl-netfleet"
    _copy_regular(etc_src / "policy.example.json", share_dst / "defaults/policy.example.json", 0o644)
    for pf in sorted((etc_src / "policy-sources").glob("*.json"), key=lambda p: p.name):
        _copy_regular(pf, share_dst / "defaults/policy-sources" / pf.name, 0o644)
    _copy_regular(etc_src / "rulesets.lock.json", share_dst / "defaults/rulesets.lock.json", 0o644)

    # Normalize directory permissions cleanly for root-owned read-only runtime + LuCI HTTP access.
    for path in sorted(stage_dir.rglob("*")):
        if path.is_dir():
            path.chmod(0o755)
    stage_dir.chmod(0o755)

    files_meta: dict[str, dict[str, object]] = {}
    payload_hasher = hashlib.sha256()
    for path in sorted(stage_dir.rglob("*")):
        if path.is_dir():
            continue
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"bundle payload contains non-regular entry: {path}")
        rel = path.relative_to(stage_dir).as_posix()
        data = path.read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        mode = f"{stat.S_IMODE(path.lstat().st_mode):04o}"
        files_meta[rel] = {"sha256": digest, "size": len(data), "mode": mode}
        payload_hasher.update(f"{digest}  {rel}\n".encode("ascii"))

    # Collect declared system dependencies from bundled plugins + shell core baseline.
    # Virtual per-plugin package names and optional external/bundled mihomo binary
    # aliases are excluded so thin shells work identically on apk and opkg hosts.
    deps = {
        "ucode", "ucode-mod-fs", "ucode-mod-uci", "ucode-mod-ubus", "ucode-mod-uloop",
        "ucode-mod-socket", "ucode-mod-digest", "yq", "curl", "ca-bundle", "flock",
        "coreutils-timeout", "unzip", "ip-full", "nftables-json", "kmod-nft-socket",
        "kmod-nft-tproxy", "usign",
    }
    for pid in default_ids:
        for dep in plugins[pid].get("package_dependencies", []):
            if dep == "opl-netfleet-kernel" or dep == "mihomo" or dep.startswith("opl-netfleet-plugin-"):
                continue
            deps.add(dep)
    return files_meta, payload_hasher.hexdigest(), sorted(deps)


def build_bundle(
    repo: Path,
    output_dir: Path,
    *,
    version: str | None = None,
    min_shell_version: str | None = None,
    channel: str = "stable",
    source_commit: str | None = None,
    source_tree: str | None = None,
    sign_key: Path | None = None,
    keep_expanded_dir: Path | None = None,
) -> dict[str, object]:
    repo = repo.resolve()
    output_dir = output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    usign = _load_module("netfleet_usign", repo / "scripts/netfleet_usign.py")

    product_meta = json.loads((repo / "product-version.json").read_text(encoding="utf-8"))
    if version is None:
        version = product_meta["version"]
    if not SEMVER_RE.fullmatch(version):
        raise ValueError(f"invalid release bundle version: {version}")
    if min_shell_version is None:
        configured_min = product_meta.get("min_shell_version")
        if configured_min is not None:
            if not isinstance(configured_min, str) or not SEMVER_RE.fullmatch(configured_min):
                raise ValueError(f"invalid min_shell_version in product-version.json: {configured_min}")
            min_shell_version = (
                configured_min if _semver_tuple(configured_min) <= _semver_tuple(version) else version
            )
        else:
            min_shell_version = version
    if not SEMVER_RE.fullmatch(min_shell_version):
        raise ValueError(f"invalid min_shell_version: {min_shell_version}")
    if source_commit is None or source_tree is None:
        detected_commit, detected_tree = git_identity(repo)
        source_commit = source_commit or detected_commit
        source_tree = source_tree or detected_tree
    if not HEX40_RE.fullmatch(source_commit) or not HEX40_RE.fullmatch(source_tree):
        raise ValueError("source_commit and source_tree must be 40-char lowercase SHA-1 hashes")

    resolved_key = Path(sign_key or os.environ.get("NETFLEET_BUNDLE_SIGN_KEY") or DEFAULT_SIGN_KEY)
    if not resolved_key.is_file():
        raise FileNotFoundError(
            f"Ed25519 bundle signing key not found at {resolved_key}; "
            "generate via scripts/netfleet_usign.py keygen --key <path>"
        )

    with tempfile.TemporaryDirectory(prefix="netfleet-bundle-stage-") as tmp:
        stage_dir = Path(tmp) / f"opl-netfleet-bundle-{version}"
        stage_dir.mkdir(mode=0o755)
        files_meta, payload_sha, sys_deps = stage_bundle_tree(
            repo, stage_dir,
            version=version, channel=channel,
            source_commit=source_commit, source_tree=source_tree,
        )
        archive_name = f"opl-netfleet-bundle-{version}.tar.gz"
        archive_path = output_dir / archive_name
        archive_bytes = _deterministic_tar_gz(stage_dir, archive_path)
        archive_sha = hashlib.sha256(archive_bytes).hexdigest()

        manifest = {
            "schema": "opl-netfleet-release-bundle.v1",
            "version": version,
            "min_shell_version": min_shell_version,
            "channel": channel,
            "source_commit": source_commit,
            "source_tree": source_tree,
            "archive": archive_name,
            "archive_sha256": archive_sha,
            "archive_size": len(archive_bytes),
            "runtime_payload_sha256": payload_sha,
            "system_dependencies": sys_deps,
            "files": files_meta,
        }
        manifest_path = output_dir / "release-manifest.json"
        _write_json(manifest_path, manifest, 0o644)
        sig_path = output_dir / "release-manifest.json.sig"
        usign.sign_file(resolved_key, manifest_path, sig_path)
        pub_path = output_dir / "opl-netfleet-bundle.pub"
        keyid = usign.write_usign_pubkey(resolved_key, pub_path)

        if keep_expanded_dir is not None:
            if keep_expanded_dir.exists():
                shutil.rmtree(keep_expanded_dir)
            _copy_regular_tree(stage_dir, keep_expanded_dir)
            _copy_regular(manifest_path, keep_expanded_dir / "release-manifest.json", 0o644)
            _copy_regular(sig_path, keep_expanded_dir / "release-manifest.json.sig", 0o644)

    return {
        "version": version,
        "min_shell_version": min_shell_version,
        "archive": archive_name,
        "archive_sha256": archive_sha,
        "archive_size": len(archive_bytes),
        "runtime_payload_sha256": payload_sha,
        "manifest_sha256": hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
        "manifest_sig_sha256": hashlib.sha256(sig_path.read_bytes()).hexdigest(),
        "usign_key_id": keyid,
        "pubkey": pub_path.name,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=ROOT)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--version")
    parser.add_argument("--min-shell-version")
    parser.add_argument("--channel", default="stable")
    parser.add_argument("--source-commit")
    parser.add_argument("--source-tree")
    parser.add_argument("--sign-key", type=Path)
    parser.add_argument("--expanded-dir", type=Path)
    args = parser.parse_args()
    summary = build_bundle(
        args.repo, args.output,
        version=args.version, min_shell_version=args.min_shell_version,
        channel=args.channel, source_commit=args.source_commit,
        source_tree=args.source_tree, sign_key=args.sign_key,
        keep_expanded_dir=args.expanded_dir,
    )
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
