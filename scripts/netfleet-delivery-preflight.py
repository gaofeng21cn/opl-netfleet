#!/usr/bin/env python3
"""Run cheap, deterministic checks before a long NetFleet qualification."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import subprocess


ROOT = Path(__file__).resolve().parents[1]
HEX40 = re.compile(r"^[0-9a-f]{40}$")
FORBIDDEN_FIXTURE_NAMES = (
    re.compile(r"^\._.*"),
    re.compile(r"^\.DS_Store$"),
    re.compile(r"^(?:__pycache__|\.git|\.pytest_cache)$"),
    re.compile(r".*(?:~|\.sw[po]|\.tmp|\.part)$"),
)


def git(*args: str) -> str:
    return subprocess.check_output(["git", "-C", str(ROOT), *args], text=True).strip()


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def resolve_identity(ref: str) -> tuple[str, str]:
    if ref.startswith("-"):
        raise ValueError("source ref cannot begin with '-'")
    commit = git("rev-parse", "--verify", f"{ref}^{{commit}}")
    tree = git("rev-parse", f"{commit}^{{tree}}")
    if not HEX40.fullmatch(commit) or not HEX40.fullmatch(tree):
        raise ValueError("source identity must use full lowercase Git object IDs")
    return commit, tree


def dirty_paths() -> list[str]:
    return [line for line in git("status", "--porcelain=v1", "--untracked-files=all").splitlines() if line]


def is_test_only_path(path: str) -> bool:
    return (
        path == "scripts/openwrt-vm.sh"
        or path == "scripts/openwrt-apk.py"
        or path == "scripts/netfleet-package-build.sh"
        or path == "scripts/https-compat/qualify.py"
        or path == "scripts/https-compat/canary-rollback.sh"
        or path == "scripts/update-openwrt-plugins.py"
        or path.startswith("scripts/openwrt-vm/")
        or path.startswith("tests/")
        or path.startswith("desktop/tests/")
        or path.startswith("docs/")
    )


def check_test_ref(source_commit: str, test_ref: str) -> dict[str, object]:
    test_commit, test_tree = resolve_identity(test_ref)
    changed = git("diff", "--name-only", source_commit, test_commit, "--", ".").splitlines()
    disallowed = [path for path in changed if not is_test_only_path(path)]
    if disallowed:
        raise ValueError("test ref changes production inputs: " + ", ".join(disallowed))
    return {"source_commit": test_commit, "source_tree": test_tree, "changed_paths": changed}


def verify_candidate(candidate: Path, source_commit: str, source_tree: str) -> dict:
    if candidate.is_symlink() or not candidate.is_dir():
        raise ValueError(f"candidate directory is unavailable: {candidate}")
    verifier_path = ROOT / "scripts/verify-netfleet-release.py"
    spec = importlib.util.spec_from_file_location("netfleet_release_verifier", verifier_path)
    if spec is None or spec.loader is None:
        raise ValueError("release verifier is unavailable")
    verifier = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(verifier)
    verifier.verify(candidate, source_commit, source_tree)
    manifest = json.loads((candidate / "manifest.json").read_text())
    return {
        "manifest_sha256": sha256(candidate / "manifest.json"),
        "package_version": manifest.get("package_version"),
        "artifact_count": len(manifest.get("artifacts", [])),
    }


def sha256_tree(directory: Path, files: list[str]) -> str:
    digest = hashlib.sha256()
    for relative in files:
        path = directory / relative
        digest.update(relative.encode())
        digest.update(b"\0")
        digest.update(hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest()


def fixture_inventory(directory: Path) -> dict[str, object]:
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError(f"fixture directory is unavailable: {directory}")
    files: list[str] = []
    total_bytes = 0
    for path in sorted(directory.rglob("*")):
        name = path.name
        if any(pattern.fullmatch(name) for pattern in FORBIDDEN_FIXTURE_NAMES):
            raise ValueError(f"fixture contains a temporary or editor file: {path.relative_to(directory)}")
        if path.is_symlink():
            raise ValueError(f"fixture contains a symlink: {path.relative_to(directory)}")
        if path.is_file():
            relative = path.relative_to(directory).as_posix()
            files.append(relative)
            total_bytes += path.stat().st_size
            if path.suffix == ".json":
                try:
                    json.loads(path.read_text())
                except (OSError, json.JSONDecodeError) as error:
                    raise ValueError(f"fixture JSON is unreadable: {relative}: {error}") from error
    if not files:
        raise ValueError("fixture directory is empty")
    return {"files": len(files), "bytes": total_bytes, "sha256": sha256_tree(directory, files)}


def source_contract(source_commit: str) -> dict[str, object]:
    def show(path: str) -> str:
        return git("show", f"{source_commit}:{path}")

    platform_manifest = json.loads(show("openwrt/files/usr/libexec/opl-netfleet/plugins/platform/manifest.json"))
    components_manifest = json.loads(show("openwrt/files/usr/libexec/opl-netfleet/plugins/components/manifest.json"))
    control = show("openwrt/files/usr/libexec/opl-netfleet/plugins/components/lib/control.uc")
    paths = platform_manifest.get("services", {}).get("platform.paths", {})
    requires = components_manifest.get("services", {}).get("components.control", {}).get("requires", {})
    if paths.get("version") != 1 or requires.get("platform.paths") != 1:
        raise ValueError("components owner is not bound to the platform.paths provider")
    if re.search(r"const\s+paths\s*=\s*private_paths\s*\(", control):
        raise ValueError("components owner shadows the platform path provider")
    return {"platform_paths_provider": True, "components_path_dependency": True, "path_shadowing": False}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ref", default="HEAD")
    parser.add_argument("--test-ref")
    parser.add_argument("--candidate", type=Path)
    parser.add_argument("--fixture", action="append", type=Path, default=[])
    parser.add_argument("--require-clean", action="store_true")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    source_commit, source_tree = resolve_identity(args.ref)
    dirty = dirty_paths()
    if args.require_clean and dirty:
        raise ValueError("worktree is dirty; freeze the source before long qualification")
    test_identity = check_test_ref(source_commit, args.test_ref) if args.test_ref else None
    result: dict[str, object] = {
        "schema": "opl-netfleet-delivery-preflight.v1",
        "source_commit": source_commit,
        "source_tree": source_tree,
        "worktree_clean": not dirty,
        "source_contract": source_contract(source_commit),
    }
    if dirty:
        result["dirty_paths"] = dirty
    if test_identity:
        result["test_source"] = test_identity
    if args.candidate:
        result["candidate"] = verify_candidate(args.candidate.resolve(), source_commit, source_tree)
    if args.fixture:
        result["fixtures"] = {str(path.resolve()): fixture_inventory(path.resolve()) for path in args.fixture}
    encoded = json.dumps(result, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n"
    if args.output:
        output = args.output.resolve()
        if output.is_relative_to(ROOT):
            raise ValueError("preflight receipt must remain outside the repository")
        output.parent.mkdir(parents=True, exist_ok=True)
        temporary = output.with_name(output.name + ".tmp")
        temporary.write_text(encoded)
        temporary.replace(output)
    print(encoded, end="")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
        raise SystemExit(str(error)) from error
