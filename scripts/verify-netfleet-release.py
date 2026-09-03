#!/usr/bin/env python3
"""Verify a NetFleet package release directory and optional public readback."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys


HEX40 = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
PACKAGE_NAMES = {"opl-netfleet", "luci-app-netfleet"}


def fail(message: str) -> None:
    raise ValueError(message)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def regular_files(directory: Path) -> dict[str, Path]:
    if not directory.is_dir():
        fail(f"release directory is unavailable: {directory}")
    files: dict[str, Path] = {}
    for path in directory.iterdir():
        if not path.is_file():
            fail(f"release directory contains a non-file entry: {path.name}")
        files[path.name] = path
    return files


def require_digest(value: object, label: str) -> str:
    if not isinstance(value, str) or not HEX64.fullmatch(value):
        fail(f"{label} is not a SHA-256 digest")
    return value


def verify(directory: Path, source_commit: str, source_tree: str) -> dict[str, object]:
    if not HEX40.fullmatch(source_commit) or not HEX40.fullmatch(source_tree):
        fail("expected source identity must use full lowercase Git object IDs")

    files = regular_files(directory)
    manifest_path = files.get("manifest.json")
    if manifest_path is None:
        fail("release is missing manifest.json")
    try:
        manifest = json.loads(manifest_path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        fail(f"release manifest is unreadable: {error}")
    if not isinstance(manifest, dict) or manifest.get("schema") != "opl-netfleet-package-manifest.v2":
        fail("release manifest schema is unsupported")
    if manifest.get("source_commit") != source_commit or manifest.get("source_tree") != source_tree:
        fail("release manifest source identity does not match the checked-out source")

    package_format = manifest.get("package_format")
    if package_format not in {"apk", "ipk"}:
        fail("release package format is unsupported")
    if not isinstance(manifest.get("package_arch"), str) or not manifest["package_arch"]:
        fail("release package architecture is missing")
    require_digest(manifest.get("runtime_payload_sha256"), "runtime payload identity")

    artifacts = manifest.get("artifacts")
    if not isinstance(artifacts, list) or len(artifacts) != 2:
        fail("release must contain exactly two package artifacts")
    seen: set[str] = set()
    artifact_files: dict[str, str] = {}
    for item in artifacts:
        if not isinstance(item, dict):
            fail("release artifact entry is invalid")
        package = item.get("package")
        name = item.get("name")
        if package not in PACKAGE_NAMES or package in seen:
            fail("release artifact package identity is invalid")
        if not isinstance(name, str) or Path(name).name != name or not name.endswith(f".{package_format}"):
            fail("release artifact filename is invalid")
        path = files.get(name)
        if path is None:
            fail(f"release artifact is missing: {name}")
        if item.get("size") != path.stat().st_size or require_digest(item.get("sha256"), name) != digest(path):
            fail(f"release artifact bytes do not match manifest: {name}")
        seen.add(package)
        artifact_files[package] = name
    if seen != PACKAGE_NAMES or manifest.get("artifact_files") != artifact_files:
        fail("release artifact mapping is invalid")

    files_manifest = manifest.get("files_manifest")
    if not isinstance(files_manifest, dict) or files_manifest.get("name") != "FILES.sha256":
        fail("release files manifest identity is invalid")
    files_manifest_path = files.get("FILES.sha256")
    if files_manifest_path is None or require_digest(files_manifest.get("sha256"), "FILES.sha256") != digest(files_manifest_path):
        fail("release files manifest bytes do not match manifest")

    public_key = manifest.get("apk_public_key")
    if package_format == "apk":
        if not isinstance(public_key, dict) or public_key.get("name") != "opl-netfleet-apk.pem":
            fail("signed APK release is missing its public key")
        key_path = files.get("opl-netfleet-apk.pem")
        if key_path is None or require_digest(public_key.get("sha256"), "APK public key") != digest(key_path):
            fail("APK public key bytes do not match manifest")
    elif public_key is not None:
        fail("IPK release must not declare an APK public key")

    feed_index = manifest.get("feed_index")
    if package_format == "apk" and feed_index is not None:
        if not isinstance(feed_index, dict) or feed_index.get("name") != "packages.adb":
            fail("APK release feed index identity is invalid")
        index_path = files.get("packages.adb")
        if index_path is None or require_digest(feed_index.get("sha256"), "packages.adb") != digest(index_path):
            fail("packages.adb bytes do not match manifest")
    elif package_format == "apk" and manifest.get("package_version") not in {"0.2.0", "0.3.0", "0.3.1", "0.3.2", "0.3.3", "0.4.0"}:
        fail("APK release is missing packages.adb feed index")
    elif package_format != "apk" and feed_index is not None:
        fail("IPK release must not declare an APK feed index")

    expected_names = {"manifest.json", "FILES.sha256", *artifact_files.values()}
    if package_format == "apk":
        expected_names.add("opl-netfleet-apk.pem")
        if feed_index is not None:
            expected_names.add("packages.adb")
    if set(files) != expected_names:
        fail("release file set does not match the manifest")

    return {
        "ok": True,
        "source_commit": source_commit,
        "source_tree": source_tree,
        "package_format": package_format,
        "package_arch": manifest["package_arch"],
        "file_count": len(files),
    }


def compare_readback(directory: Path, expected_directory: Path) -> None:
    actual = regular_files(directory)
    expected = regular_files(expected_directory)
    if set(actual) != set(expected):
        fail("public release file set differs from the built package set")
    for name in sorted(expected):
        if digest(actual[name]) != digest(expected[name]):
            fail(f"public release bytes differ from the built package set: {name}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", required=True, type=Path)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--source-tree", required=True)
    parser.add_argument("--expected-directory", type=Path)
    args = parser.parse_args()
    try:
        result = verify(args.directory, args.source_commit, args.source_tree)
        if args.expected_directory is not None:
            compare_readback(args.directory, args.expected_directory)
            result["matches_expected_directory"] = True
    except (OSError, ValueError) as error:
        print(f"verify-netfleet-release: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
