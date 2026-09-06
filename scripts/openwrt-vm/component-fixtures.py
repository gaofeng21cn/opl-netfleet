#!/usr/bin/env python3
"""Build disposable signed APK revisions without altering the release candidate."""

import argparse
import json
import os
from pathlib import Path
import platform
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


def build(candidate, output):
    sdk = sdk_path()
    apk = sdk / "staging_dir/host/bin/apk"
    if not apk.is_file():
        raise SystemExit("SDK host apk is unavailable")
    output.mkdir(mode=0o700)
    manifest = json.loads((candidate / "manifest.json").read_text())
    version = f"{manifest['package_version']}-r{manifest['package_release']}"
    revision = int(manifest["package_release"])
    if revision < 1:
        raise SystemExit("Component fixture requires package release >= 1")
    old_version = f"{manifest['package_version']}-r{revision - 1}"
    bad_version = f"{manifest['package_version']}-r{revision + 1}"
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
        for kind in ("good", "bad", "bad-core"):
            (output / kind).mkdir()
            for archive in candidate.glob("*.apk"):
                shutil.copy2(archive, output / kind / archive.name)
        core_versions = {}
        for name in ("opl-netfleet", "luci-app-netfleet", "mihomo-meta"):
            archive = next(candidate.glob(f"{name}-*.apk"))
            metadata = json.loads(run("adbdump", "--format", "json", archive))
            package_version = metadata["info"]["version"]
            base, release = package_version.rsplit("-r", 1)
            prior = f"{base}-r{int(release) - 1}"
            following = f"{base}-r{int(release) + 1}"
            if name == "mihomo-meta":
                core_versions = {"core_version": package_version, "core_old_version": prior, "core_bad_version": following}
            root = scratch / name
            root.mkdir()
            run("--allow-untrusted", "extract", "--destination", root, archive)
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
            if name == "opl-netfleet":
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
        for kind in ("good", "bad", "bad-core"):
            run("--allow-untrusted", "mkndx", "--output", output / kind / "packages.adb",
                "--sign", private_key, *sorted((output / kind).glob("*.apk")))
    (output / "fixture.json").write_text(json.dumps({
        "schema_version": 1, "version": version, "old_version": old_version, "bad_version": bad_version,
        "source_commit": manifest["source_commit"], "source_tree": manifest["source_tree"],
        **core_versions,
    }, sort_keys=True) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("candidate", type=Path)
    parser.add_argument("output", type=Path)
    arguments = parser.parse_args()
    build(arguments.candidate.resolve(), arguments.output.resolve())
