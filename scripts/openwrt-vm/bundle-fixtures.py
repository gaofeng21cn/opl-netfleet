#!/usr/bin/env python3
"""Build signed Release Bundle fault-injection feeds for QEMU qualification."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import stat
import tarfile
import tempfile


def _load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load module from {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _bump_patch(version: str) -> str:
    major, minor, patch = (int(part) for part in version.split("."))
    return f"{major}.{minor}.{patch + 1}"


def _emit_variant(
    base_dir: Path,
    variant_dir: Path,
    *,
    orig_manifest: dict,
    next_version: str,
    min_shell_version: str,
    sign_key: Path,
    bundle_builder,
    usign,
    mutator=None,
    tamper_sig: bool = False,
) -> None:
    variant_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="netfleet-bfix-") as tmp:
        stage = Path(tmp) / "stage"
        shutil.copytree(base_dir, stage)

        build_path = stage / "share/build.json"
        build = json.loads(build_path.read_text(encoding="utf-8"))
        build["version"] = next_version
        build_path.write_text(json.dumps(build, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        build_path.chmod(0o644)

        if mutator is not None:
            mutator(stage)

        for path in sorted(stage.rglob("*")):
            if path.is_dir():
                path.chmod(0o755)
        stage.chmod(0o755)

        files_meta: dict[str, dict[str, object]] = {}
        for path in sorted(stage.rglob("*")):
            if path.is_dir():
                continue
            if path.is_symlink() or not path.is_file():
                raise ValueError(f"non-regular file in fixture bundle: {path}")
            rel = path.relative_to(stage).as_posix()
            data = path.read_bytes()
            mode = f"{stat.S_IMODE(path.lstat().st_mode):04o}"
            files_meta[rel] = {
                "sha256": hashlib.sha256(data).hexdigest(),
                "size": len(data),
                "mode": mode,
            }

        archive_name = f"opl-netfleet-bundle-{next_version}.tar.gz"
        archive_path = variant_dir / archive_name
        archive_bytes = bundle_builder._deterministic_tar_gz(stage, archive_path)
        manifest = {
            "schema": "opl-netfleet-release-bundle.v1",
            "version": next_version,
            "min_shell_version": min_shell_version,
            "channel": orig_manifest.get("channel", "stable"),
            "archive": archive_name,
            "archive_sha256": hashlib.sha256(archive_bytes).hexdigest(),
            "archive_size": len(archive_bytes),
            "source_commit": orig_manifest["source_commit"],
            "source_tree": orig_manifest["source_tree"],
            "system_dependencies": orig_manifest.get("system_dependencies", []),
            "files": files_meta,
        }
        mf_path = variant_dir / "release-manifest.json"
        mf_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        mf_path.chmod(0o644)
        sig_path = variant_dir / "release-manifest.json.sig"
        usign.sign_file(sign_key, mf_path, sig_path)
        if tamper_sig:
            lines = sig_path.read_text(encoding="utf-8").splitlines()
            body = lines[1]
            flipped = ("A" if body[0] != "A" else "B") + body[1:]
            sig_path.write_text(f"{lines[0]}\n{flipped}\n", encoding="utf-8")
            sig_path.chmod(0o644)


def build_fixtures(candidate_dir: Path, output_dir: Path, sign_key: Path) -> dict[str, object]:
    scripts_dir = Path(__file__).resolve().parents[1]
    bundle_builder = _load_module("netfleet_bundle_build", scripts_dir / "netfleet-bundle-build.py")
    usign = _load_module("netfleet_usign", scripts_dir / "netfleet_usign.py")

    orig_manifest = json.loads((candidate_dir / "release-manifest.json").read_text(encoding="utf-8"))
    orig_version = str(orig_manifest["version"])
    next_version = _bump_patch(orig_version)
    min_shell = str(orig_manifest.get("min_shell_version") or orig_version)
    orig_archive = candidate_dir / str(orig_manifest["archive"])

    if output_dir.exists():
        shutil.rmtree(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="netfleet-bundle-base-") as tmp:
        base_dir = Path(tmp) / "base"
        base_dir.mkdir(parents=True, exist_ok=True)
        with tarfile.open(orig_archive, "r:gz") as tf:
            for member in tf.getmembers():
                clean = member.name.lstrip("./")
                if not clean or member.islnk() or member.issym() or clean.startswith("/") or ".." in Path(clean).parts:
                    raise ValueError(f"unsafe bundle entry: {member.name}")
            tf.extractall(base_dir, filter="data")

        def mutate_prevalidate(stage: Path) -> None:
            target = stage / "runtime/plugins/status/lib/control.uc"
            target.write_text(target.read_text(encoding="utf-8") + "\n{{{ invalid_ucode_syntax\n", encoding="utf-8")

        def mutate_verify(stage: Path) -> None:
            target = stage / "runtime/plugins/status/lib/control.uc"
            src = target.read_text(encoding="utf-8")
            old = (
                "command_status = function(argv) {\n"
                "\tconst policy = load_policy();\n"
                "\tif (policy == null) fail(argv[0], \"policy_unreadable\", POLICY_PATH);\n"
                "\tconst evidence = load_evidence();\n"
                "\tstatus_action(policy, evidence);\n"
                "};"
            )
            new = (
                "command_status = function(argv) {\n"
                "\tfail(argv[0], \"injected_verify_failure\", null);\n"
                "};"
            )
            if old not in src:
                raise ValueError("cannot inject status verify fault in control.uc")
            target.write_text(src.replace(old, new, 1), encoding="utf-8")

        variants = {
            "good-upgrade": {"min_shell": min_shell, "mutator": None, "tamper": False},
            "bad-sig": {"min_shell": min_shell, "mutator": None, "tamper": True},
            "high-min-shell": {"min_shell": "99.0.0", "mutator": None, "tamper": False},
            "bad-prevalidate": {"min_shell": min_shell, "mutator": mutate_prevalidate, "tamper": False},
            "bad-verify": {"min_shell": min_shell, "mutator": mutate_verify, "tamper": False},
        }
        for name, cfg in variants.items():
            _emit_variant(
                base_dir,
                output_dir / name,
                orig_manifest=orig_manifest,
                next_version=next_version,
                min_shell_version=str(cfg["min_shell"]),
                sign_key=sign_key,
                bundle_builder=bundle_builder,
                usign=usign,
                mutator=cfg["mutator"],
                tamper_sig=bool(cfg["tamper"]),
            )

    meta = {
        "schema": "opl-netfleet-bundle-fixtures.v1",
        "orig_version": orig_version,
        "next_version": next_version,
        "source_commit": orig_manifest["source_commit"],
        "source_tree": orig_manifest["source_tree"],
        "variants": ["good-upgrade", "bad-sig", "high-min-shell", "bad-prevalidate", "bad-verify"],
    }
    meta_path = output_dir / "fixtures-meta.json"
    meta_path.write_text(json.dumps(meta, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    meta_path.chmod(0o644)
    return meta


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("candidate_dir", type=Path)
    parser.add_argument("output_dir", type=Path)
    parser.add_argument("--sign-key", type=Path, required=True)
    args = parser.parse_args()
    meta = build_fixtures(args.candidate_dir.resolve(), args.output_dir.resolve(), args.sign_key.resolve())
    print(json.dumps(meta))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
