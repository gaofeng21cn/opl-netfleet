#!/usr/bin/env python3
"""Build disposable signed APK revisions without altering the release candidate."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tempfile


def sdk_path():
    configured = os.environ.get("NETFLEET_SDK")
    if configured:
        return Path(configured).resolve()
    cache = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))
    tools = sorted((cache / "opl-netfleet/sdk").glob("*/openwrt-sdk-*/staging_dir/host/bin/apk"))
    if len(tools) != 1:
        raise SystemExit("Set NETFLEET_SDK to build disposable component-update fixtures")
    return tools[0].parents[3]


def fixture_versions(version):
    """Exercise numeric upgrades from an old -r1 install, retaining third-party revisions."""
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(?:-r(\d+))?", version)
    if match is None:
        raise ValueError("invalid component fixture version")
    major, minor, patch = map(int, match.group(1, 2, 3))
    if match[4] is not None:
        base, release = version.rsplit("-r", 1)
        revision = int(release)
        if revision < 1:
            raise ValueError("old-format fixture requires release >= 1")
        return f"{base}-r{revision - 1}", f"{base}-r{revision + 1}", f"{base}-r{revision + 2}"
    if patch < 1:
        # Numeric candidates with no patch yet still have an older prerelease.
        prior = f"{version}_rc1"
    else:
        prior = f"{major}.{minor}.{patch - 1}-r1"
    return prior, f"{major}.{minor}.{patch + 1}", f"{major}.{minor}.{patch + 2}"


def build(candidate, output, baseline=None):
    sdk = sdk_path()
    apk = sdk / "staging_dir/host/bin/apk"
    if not apk.is_file():
        raise SystemExit("SDK host apk is unavailable")
    output.mkdir(mode=0o700)
    manifest = json.loads((candidate / "manifest.json").read_text())
    version = manifest["package_version"]
    if manifest.get("package_release") is not None:
        version += "-r" + manifest["package_release"]
    old_version, bad_version, _ = fixture_versions(version)
    with tempfile.TemporaryDirectory(prefix="netfleet-component-build-") as temporary:
        scratch = Path(temporary)

        def run(*args):
            command = [str(apk), *map(str, args)]
            if platform.system() != "Linux" or platform.machine() not in ("x86_64", "AMD64") or os.geteuid() != 0:
                command = ["docker", "run", "--rm", "--user", "0:0", "--platform", "linux/amd64",
                           "-v", f"{sdk}:/sdk:ro", "-v", f"{candidate}:/candidate:ro",
                           "-v", f"{output}:/fixtures", "-v", f"{scratch}:/scratch",
                           os.environ.get("NETFLEET_VM_APK_IMAGE", "opl-netfleet-openwrt-sdk-builder:latest"),
                           "/sdk/staging_dir/host/bin/apk", *map(str, args)]
                for index, value in enumerate(command):
                    if index < command.index("/sdk/staging_dir/host/bin/apk") + 1:
                        continue
                    for local, mounted in ((output, "/fixtures"), (candidate, "/candidate"), (scratch, "/scratch")):
                        if value.startswith(str(local) + "/"):
                            command[index] = mounted + value[len(str(local)):]
                            break
                    if ":" in command[index]:
                        kind, path = command[index].split(":", 1)
                        if path.startswith(str(scratch) + "/"):
                            command[index] = kind + ":/scratch" + path[len(str(scratch)):]
            return subprocess.run(command, check=True, text=True, capture_output=True).stdout

        private_key = scratch / "key.pem"
        public_key = output / "component-fixture.pem"
        subprocess.run(["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256",
                        "-out", str(private_key)], check=True, capture_output=True)
        subprocess.run(["openssl", "pkey", "-in", str(private_key), "-pubout", "-out", str(public_key)],
                       check=True, capture_output=True)
        incompatible_root = scratch / "incompatible-compatibility"
        incompatible_root.mkdir()
        run("mkpkg", "--files", incompatible_root, "--sign-key", private_key,
            "--output", output / "incompatible-compatibility.apk",
            "--info", "name:opl-netfleet-https-compat", "--info", "version:0.1.7-r1",
            "--info", "arch:noarch", "--info", "description:Dependency rejection fixture",
            "--info", "license:MIT", "--info", "depends:opl-netfleet")
        for kind in ("good", "bad", "bad-core", "bad-hook", "interrupted"):
            (output / kind).mkdir()
            for archive in candidate.glob("*.apk"):
                shutil.copy2(archive, output / kind / archive.name)
        (output / "old").mkdir()
        (output / "independent").mkdir()
        core_versions = {}
        package_versions = {}
        product_packages = None
        legacy = None
        artifacts = {item["package"]: item["name"] for item in manifest["artifacts"] + manifest["dependency_artifacts"]}
        for name, filename in artifacts.items():
            archive = candidate / filename
            metadata = json.loads(run("adbdump", "--format", "json", archive))
            package_version = metadata["info"]["version"]
            prior, following, independent_version = fixture_versions(package_version)
            package_versions[name] = {"current": package_version, "old": prior, "bad": following}
            if name == "mihomo-meta":
                core_versions = {"core_version": package_version, "core_old_version": prior, "core_bad_version": following}
            root = scratch / name
            root.mkdir()
            run("--allow-untrusted", "extract", "--destination", root, archive)
            if name == "opl-netfleet":
                system = json.loads((root / "usr/share/opl-netfleet/system.json").read_text())
                product_packages = sorted({"opl-netfleet", "luci-app-netfleet", *system["product_packages"]})
            script_args = []
            for kind, content in metadata.get("scripts", {}).items():
                script = scratch / f"{name}.{kind}"
                script.write_text(content)
                script_args.extend(("--script", f"{kind}:{script}"))

            def package(target_version, feed):
                arguments = ["mkpkg", "--files", root, "--sign-key", private_key,
                             "--output", output / feed / f"{name}-{target_version}.apk"]
                for key, value in metadata["info"].items():
                    if key in ("hashes", "installed-size", "file-size"):
                        continue
                    if key == "version":
                        value = target_version
                    arguments.extend(("--info", f"{key}:{' '.join(value) if isinstance(value, list) else value}"))
                arguments.extend(script_args)
                for trigger in metadata.get("triggers", []):
                    arguments.extend(("--trigger", trigger))
                run(*arguments)

            package(prior, "good")
            shutil.copy2(output / "good" / f"{name}-{prior}.apk", output / "old")
            if name == "opl-netfleet-plugin-dashboard":
                package_versions[name]["independent"] = independent_version
                package(independent_version, "independent")
            if name == "opl-netfleet-plugin-configuration":
                # A real APK lifecycle failure, independent of a broken core binary.
                original_scripts = list(script_args)
                failed_hook = scratch / "failed-pre-upgrade"
                failed_hook.write_text("#!/bin/sh\nexit 1\n")
                script_args = [f"pre-upgrade:{failed_hook}" if value.startswith("pre-upgrade:") else value
                               for value in script_args]
                package(following, "bad-hook")
                pause_hook = scratch / "pause-pre-upgrade"
                pause_hook.write_text("#!/bin/sh\ntouch /tmp/netfleet-update-paused\nwhile :; do sleep 1; done\n")
                script_args = [f"pre-upgrade:{pause_hook}" if value.startswith("pre-upgrade:") else value
                               for value in original_scripts]
                package(following, "interrupted")
                script_args = original_scripts
            if name == "opl-netfleet-plugin-mihomo":
                init = root / "etc/init.d/opl-netfleet-core"
                source = init.read_text()
                if source.count("start_service() {\n") != 1:
                    raise SystemExit("Cannot locate native core start fixture point")
                init.write_text(source.replace("start_service() {\n", "start_service() {\n\treturn 1\n", 1))
            elif name == "mihomo-meta":
                # Deliberately incompatible candidate; the installed/r0 core bytes stay real.
                core = root / "usr/libexec/mihomo"
                core.write_text("#!/bin/sh\nexit 1\n")
                core.chmod(0o755)
            package(following, "bad-core" if name == "mihomo-meta" else "bad")
        for kind in ("old", "good", "bad", "bad-core", "bad-hook", "interrupted", "independent"):
            run("--allow-untrusted", "mkndx", "--output", output / kind / "packages.adb",
                "--sign", private_key, *sorted((output / kind).glob("*.apk")))
        if baseline is not None:
            legacy_dir = output / "legacy"
            legacy_dir.mkdir()
            shutil.copy2(baseline / "baseline.pem", legacy_dir / "baseline.pem")
            legacy = {"artifacts": [], "system_dependencies": []}
            for archive in sorted(baseline.glob("*.apk")):
                target = legacy_dir / archive.name
                shutil.copy2(archive, target)
                run("verify", "--keys-dir", legacy_dir, target)
                metadata = json.loads(run("adbdump", "--format", "json", target))
                name = metadata["info"]["name"]
                if name not in ("opl-netfleet", "luci-app-netfleet", "opl-netfleet-https-compat"):
                    raise SystemExit("Legacy fixture contains an unsupported package")
                if name == "opl-netfleet-https-compat":
                    legacy["system_dependencies"] = [
                        dependency for dependency in metadata["info"].get("depends", [])
                        if dependency != "opl-netfleet"
                    ]
                legacy["artifacts"].append({"name": target.name, "package": name,
                                            "version": metadata["info"]["version"],
                                            "sha256": hashlib.sha256(target.read_bytes()).hexdigest()})
                if name == "opl-netfleet":
                    legacy_root = scratch / "legacy"
                    legacy_root.mkdir()
                    run("--allow-untrusted", "extract", "--destination", legacy_root, target)
                    legacy["build"] = json.loads((legacy_root / "usr/share/opl-netfleet/build.json").read_text())
            if not {"opl-netfleet", "luci-app-netfleet"}.issubset(item["package"] for item in legacy["artifacts"]):
                raise SystemExit("Legacy fixture requires the monolith and LuCI APKs")
            legacy["key_sha256"] = hashlib.sha256((legacy_dir / "baseline.pem").read_bytes()).hexdigest()
    (output / "fixture.json").write_text(json.dumps({
        "schema_version": 1, "version": version, "old_version": old_version, "bad_version": bad_version,
        "source_commit": manifest["source_commit"], "source_tree": manifest["source_tree"],
        "product_packages": product_packages,
        "package_versions": package_versions,
        "legacy": legacy,
        **core_versions,
    }, sort_keys=True) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("candidate", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--baseline", type=Path)
    arguments = parser.parse_args()
    build(arguments.candidate.resolve(), arguments.output.resolve(),
          arguments.baseline.resolve() if arguments.baseline is not None else None)
