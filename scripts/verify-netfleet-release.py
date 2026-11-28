#!/usr/bin/env python3
"""Verify a NetFleet package release directory and optional public readback."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sys


HEX40 = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
PACKAGE_NAMES = {"opl-netfleet", "opl-netfleet-kernel", "luci-app-netfleet"}
BUNDLE_PACKAGE_NAMES = {"opl-netfleet", "luci-app-netfleet"}
PLUGIN_PACKAGE = re.compile(r"^opl-netfleet-plugin-[a-z][a-z0-9-]*$")
LEGACY_PACKAGE_VERSIONS = {"0.2.0", "0.3.0", "0.3.1", "0.3.2", "0.3.3", "0.4.0"}
BOOTSTRAP_MINIMUM_VERSION = (0, 4, 5)


def fail(message: str) -> None:
    raise ValueError(message)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def regular_files(directory: Path) -> dict[str, Path]:
    if not directory.is_dir():
        fail(f"release directory is unavailable: {directory}")
    files: dict[str, Path] = {}
    for path in directory.iterdir():
        if path.is_symlink() or not path.is_file():
            fail(f"release directory contains a non-file entry: {path.name}")
        files[path.name] = path
    return files


def require_digest(value: object, label: str) -> str:
    if not isinstance(value, str) or not HEX64.fullmatch(value):
        fail(f"{label} is not a SHA-256 digest")
    return value


def version_tuple(value: object) -> tuple[int, int, int]:
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", value):
        fail("release package version is invalid")
    return tuple(int(part) for part in value.split("."))  # type: ignore[return-value]


def artifact_version(item: dict) -> str:
    """Return the exact install identity, including revisions of retained old packages."""
    version = item.get("version")
    version_tuple(version)
    release = item.get("release")
    if release is None:
        return version
    if not isinstance(release, str) or re.fullmatch(r"[0-9]+", release) is None:
        fail("release artifact revision is invalid")
    return f"{version}-r{release}"


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

    package_version = manifest.get("package_version")
    parsed_version = version_tuple(package_version)
    package_format = manifest.get("package_format")
    if package_format not in {"apk", "ipk"}:
        fail("release package format is unsupported")
    package_arch = manifest.get("package_arch")
    if not isinstance(package_arch, str) or not package_arch:
        fail("release package architecture is missing")
    build_target_arch = manifest.get("build_target_arch")
    if build_target_arch is None and manifest.get("package_version") not in LEGACY_PACKAGE_VERSIONS:
        fail("release build target architecture is missing")
    if build_target_arch is not None and (
        not isinstance(build_target_arch, str) or not build_target_arch
    ):
        fail("release build target architecture is invalid")
    if (
        package_format == "apk"
        and manifest.get("package_version") not in LEGACY_PACKAGE_VERSIONS
        and package_arch != "noarch"
    ):
        fail("release APK architecture must be noarch")
    require_digest(manifest.get("runtime_payload_sha256"), "runtime payload identity")

    is_release_bundle = manifest.get("delivery_model") == "release-bundle"
    required_packages = BUNDLE_PACKAGE_NAMES if is_release_bundle else PACKAGE_NAMES

    artifacts = manifest.get("artifacts")
    if not isinstance(artifacts, list) or not artifacts:
        fail("release package artifacts are missing")
    seen: set[str] = set()
    artifact_files: dict[str, str] = {}
    for item in artifacts:
        if not isinstance(item, dict):
            fail("release artifact entry is invalid")
        package = item.get("package")
        name = item.get("name")
        valid_pkg = (
            package in BUNDLE_PACKAGE_NAMES
            if is_release_bundle
            else (package in PACKAGE_NAMES or PLUGIN_PACKAGE.fullmatch(package))
        )
        if not isinstance(package, str) or not valid_pkg or package in seen:
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
    if not required_packages.issubset(seen) or manifest.get("artifact_files") != artifact_files:
        fail("release artifact mapping is invalid")

    dependencies = manifest.get("dependency_artifacts", [])
    if not isinstance(dependencies, list) or len(dependencies) > 1:
        fail("release dependency set is invalid")
    dependency_names: set[str] = set()
    for item in dependencies:
        if not isinstance(item, dict) or item.get("package") != "mihomo-meta":
            fail("release dependency package identity is invalid")
        name = item.get("name")
        if (not isinstance(name, str) or Path(name).name != name
                or not name.endswith(f".{package_format}") or name in artifact_files.values()):
            fail("release dependency filename is invalid")
        path = files.get(name)
        if path is None or item.get("size") != path.stat().st_size or require_digest(item.get("sha256"), name) != digest(path):
            fail("release dependency bytes do not match manifest")
        upstream = item.get("upstream")
        if (item.get("package_arch") != build_target_arch or not isinstance(upstream, dict)
                or upstream.get("architecture") != build_target_arch
                or upstream.get("version") != item.get("version")):
            fail("release dependency architecture or version is invalid")
        version_tuple(item.get("version"))
        require_digest(upstream.get("sha256"), "upstream core asset")
        upstream_commit = upstream.get("source_commit", "")
        if not isinstance(upstream_commit, str) or not HEX40.fullmatch(upstream_commit):
            fail("release dependency source commit is invalid")
        if upstream.get("source_url") != f"https://github.com/MetaCubeX/mihomo/tree/{upstream_commit}":
            fail("release dependency corresponding source is missing")
        if (upstream.get("license") != "GPL-3.0-or-later"
                or not str(upstream.get("url", "")).startswith("https://github.com/MetaCubeX/mihomo/releases/download/")
                or not str(upstream.get("packaging_reference", "")).startswith("https://github.com/nikkinikki-org/OpenWrt-nikki/blob/")):
            fail("release dependency provenance is invalid")
        dependency_names.add(name)

    files_manifest = manifest.get("files_manifest")
    if files_manifest is not None or not (is_release_bundle and package_format == "ipk"):
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
    elif package_format == "apk" and manifest.get("package_version") not in LEGACY_PACKAGE_VERSIONS:
        fail("APK release is missing packages.adb feed index")
    elif package_format != "apk" and feed_index is not None:
        fail("IPK release must not declare an APK feed index")

    feed_metadata = manifest.get('feed_metadata')
    if package_format == 'apk' and parsed_version >= (0, 9, 17) and feed_metadata is None:
        fail('APK release is missing ASU feed metadata')
    if feed_metadata is not None:
        path = files.get('index.json')
        if (package_format != 'apk' or not isinstance(feed_metadata, dict)
                or feed_metadata.get('name') != 'index.json' or path is None
                or require_digest(feed_metadata.get('sha256'), 'index.json') != digest(path)):
            fail('ASU feed metadata identity is invalid')
        expected = {item['package']: artifact_version(item) for item in artifacts}
        expected.update({item['package']: item['name'][len(item['package']) + 1:-4] for item in dependencies})
        value = json.loads(path.read_text())
        if value != {'version': 2, 'architecture': build_target_arch, 'packages': expected}:
            fail('ASU feed metadata differs from the declared packages')

    feed_bootstrap = manifest.get("feed_bootstrap")
    if package_format == "apk" and parsed_version >= BOOTSTRAP_MINIMUM_VERSION:
        if not isinstance(feed_bootstrap, dict) or feed_bootstrap.get("name") != "install-netfleet.sh":
            fail("release is missing its feed bootstrap")
        bootstrap_path = files.get("install-netfleet.sh")
        if bootstrap_path is None or require_digest(feed_bootstrap.get("sha256"), "install-netfleet.sh") != digest(bootstrap_path):
            fail("feed bootstrap bytes do not match manifest")
        if not bootstrap_path.read_bytes().startswith(b"#!/bin/sh\n"):
            fail("feed bootstrap is not an OpenWrt shell script")
    elif feed_bootstrap is not None:
        fail("legacy release must not declare a feed bootstrap")

    native_runtime = manifest.get("native_runtime")
    if native_runtime is not None:
        if package_format != "apk" or not isinstance(native_runtime, dict) or native_runtime.get("name") != "native-runtime.json":
            fail("native runtime receipt identity is invalid")
        receipt_path = files.get("native-runtime.json")
        if receipt_path is None or require_digest(native_runtime.get("sha256"), "native runtime receipt") != digest(receipt_path):
            fail("native runtime receipt bytes do not match manifest")
        receipt = json.loads(receipt_path.read_text())
        if not isinstance(receipt, dict) or receipt.get("ok") is not True or not isinstance(receipt.get("packages"), list):
            fail("native runtime receipt is invalid")
        entries = receipt["packages"]
        if len(entries) != len(artifacts):
            fail("native runtime receipt does not cover the release")
        expected = {item["package"]: (item["name"], item["sha256"]) for item in artifacts}
        checked: set[str] = set()
        for item in entries:
            if not isinstance(item, dict):
                fail("native runtime receipt package is invalid")
            package = item.get("package")
            if not isinstance(package, str) or package in checked or package not in expected:
                fail("native runtime receipt package identity is invalid")
            if (item.get("artifact"), item.get("sha256")) != expected[package]:
                fail("native runtime receipt package bytes differ from release")
            checked.add(package)

    expected_names = {"manifest.json", *artifact_files.values(), *dependency_names}
    if files_manifest is not None:
        expected_names.add("FILES.sha256")
    if native_runtime is not None:
        expected_names.add("native-runtime.json")
    if package_format == "apk":
        expected_names.add("opl-netfleet-apk.pem")
        if feed_index is not None:
            expected_names.add("packages.adb")
    if feed_bootstrap is not None:
        expected_names.add("install-netfleet.sh")
    if feed_metadata is not None:
        expected_names.add('index.json')
    usign = None
    if is_release_bundle:
        usign_spec = importlib.util.spec_from_file_location(
            "netfleet_usign", Path(__file__).resolve().parent / "netfleet_usign.py"
        )
        usign = importlib.util.module_from_spec(usign_spec)
        usign_spec.loader.exec_module(usign)
        release_bundle = manifest.get("release_bundle")
        if not isinstance(release_bundle, dict):
            fail("release bundle metadata is missing")
        archive_name = release_bundle.get("archive")
        mf_name = release_bundle.get("manifest")
        sig_name = release_bundle.get("manifest_sig")
        bpub_name = release_bundle.get("public_key")
        if (not isinstance(archive_name, str) or Path(archive_name).name != archive_name
                or not archive_name.endswith(".tar.gz")
                or mf_name != "release-manifest.json" or sig_name != "release-manifest.json.sig"
                or bpub_name != "opl-netfleet-bundle.pub"):
            fail("release bundle artifact names are invalid")
        for key in (archive_name, mf_name, sig_name, bpub_name):
            if key not in files:
                fail(f"release bundle file is missing: {key}")
        if (release_bundle.get("archive_size") != files[archive_name].stat().st_size
                or require_digest(release_bundle.get("archive_sha256"), archive_name) != digest(files[archive_name])
                or require_digest(release_bundle.get("manifest_sha256"), mf_name) != digest(files[mf_name])
                or require_digest(release_bundle.get("manifest_sig_sha256"), sig_name) != digest(files[sig_name])):
            fail("release bundle file digests do not match manifest")
        if not usign.verify_file(files[bpub_name], files[mf_name], files[sig_name]):
            fail("release bundle signature verification failed")
        rmf = json.loads(files[mf_name].read_text())
        if (rmf.get("schema") != "opl-netfleet-release-bundle.v1"
                or rmf.get("version") != package_version
                or rmf.get("archive") != archive_name
                or rmf.get("archive_sha256") != release_bundle.get("archive_sha256")
                or rmf.get("archive_size") != release_bundle.get("archive_size")
                or rmf.get("source_commit") != source_commit
                or rmf.get("source_tree") != source_tree):
            fail("release manifest metadata does not match release")
        expected_names.update({archive_name, mf_name, sig_name, bpub_name})
    opkg_index = manifest.get("opkg_index")
    if opkg_index is not None:
        if not is_release_bundle or not isinstance(opkg_index, dict) or usign is None:
            fail("opkg index metadata is invalid")
        usign_pub = manifest.get("usign_public_key")
        if not isinstance(usign_pub, dict) or usign_pub.get("name") != "opl-netfleet-usign.pub":
            fail("opkg release is missing usign public key")
        pub_file = files.get("opl-netfleet-usign.pub")
        if pub_file is None or require_digest(usign_pub.get("sha256"), "opl-netfleet-usign.pub") != digest(pub_file):
            fail("usign public key bytes do not match manifest")
        expected_names.add("opl-netfleet-usign.pub")
        for key, expected_name in (("packages", "Packages"), ("packages_gz", "Packages.gz"), ("packages_sig", "Packages.sig")):
            ref = opkg_index.get(key)
            if not isinstance(ref, dict) or ref.get("name") != expected_name or expected_name not in files:
                fail(f"opkg index entry is missing: {expected_name}")
            if ref.get("size") != files[expected_name].stat().st_size or require_digest(ref.get("sha256"), expected_name) != digest(files[expected_name]):
                fail(f"opkg index bytes do not match manifest: {expected_name}")
            expected_names.add(expected_name)
        if not usign.verify_file(pub_file, files["Packages"], files["Packages.sig"]):
            fail("opkg index signature verification failed")
        ipk_artifacts = manifest.get("ipk_artifacts")
        if ipk_artifacts is not None:
            if not isinstance(ipk_artifacts, list):
                fail("ipk artifacts list is invalid")
            ipk_files_map: dict[str, str] = {}
            ipk_seen: set[str] = set()
            for item in ipk_artifacts:
                pkg = item.get("package")
                name = item.get("name")
                if not isinstance(pkg, str) or pkg not in BUNDLE_PACKAGE_NAMES or pkg in ipk_seen:
                    fail("ipk artifact package identity is invalid")
                if not isinstance(name, str) or Path(name).name != name or not name.endswith(".ipk") or name not in files:
                    fail("ipk artifact file is missing")
                if item.get("size") != files[name].stat().st_size or require_digest(item.get("sha256"), name) != digest(files[name]):
                    fail(f"ipk artifact bytes do not match manifest: {name}")
                ipk_seen.add(pkg)
                ipk_files_map[pkg] = name
                expected_names.add(name)
            if not BUNDLE_PACKAGE_NAMES.issubset(ipk_seen) or manifest.get("ipk_artifact_files") != ipk_files_map:
                fail("ipk artifact mapping is invalid")
        for item in manifest.get("ipk_dependency_artifacts", []):
            name = item.get("name")
            if not isinstance(name, str) or Path(name).name != name or not name.endswith(".ipk") or name not in files:
                fail("ipk dependency artifact is missing")
            if item.get("size") != files[name].stat().st_size or require_digest(item.get("sha256"), name) != digest(files[name]):
                fail("ipk dependency artifact bytes do not match manifest")
            expected_names.add(name)
    if set(files) != expected_names:
        fail("release file set does not match the manifest")

    return {
        "ok": True,
        "source_commit": source_commit,
        "source_tree": source_tree,
        "package_format": package_format,
        "package_arch": package_arch,
        "build_target_arch": build_target_arch,
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
