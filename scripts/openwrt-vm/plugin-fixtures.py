#!/usr/bin/env python3
"""Build signed APK lifecycle fixtures from the real external plugin examples."""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
SDK_SPEC = importlib.util.spec_from_file_location("netfleet_plugin_sdk", ROOT / "scripts/netfleet-plugin.py")
SDK = importlib.util.module_from_spec(SDK_SPEC)
SDK_SPEC.loader.exec_module(SDK)
HOOKS = {"preinst": "pre-install", "postinst": "post-install",
         "prerm": "pre-deinstall", "postrm": "post-deinstall"}


def stage_plugin(example, destination, version):
    destination.mkdir()
    source = destination / "source"
    shutil.copytree(example, source)
    manifest = json.loads((source / "manifest.json").read_text())
    manifest["version"] = version
    (source / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    if version == "0.1.1" and (source / "resources/style.css").is_file():
        with (source / "resources/style.css").open("a") as stylesheet:
            stylesheet.write("\n/* Signed APK upgrade fixture. */\n")
    package = destination / "package"
    generated = SDK.package_source(source, package, "Apache-2.0", 1)
    make_root = destination / "make"
    (make_root / "include").mkdir(parents=True)
    (make_root / "rules.mk").touch()
    (make_root / "include/package.mk").touch()
    payload = destination / "payload"
    harness = destination / "install.mk"
    declarations = {"definition": f"Package/{manifest['package']}",
                    **{phase: f"Package/{manifest['package']}/{phase}" for phase in HOOKS}}
    harness.write_text(
        "INSTALL_DIR:=mkdir -p\nCP:=cp -R\n" +
        "".join(f"$(info __BEGIN_{name}__)\n$(info $({variable}))\n$(info __END_{name}__)\n"
                for name, variable in declarations.items()) +
        "all:\n\t$(call Package/" + manifest["package"] + "/install," + str(payload) + ")\n")
    completed = subprocess.run([
        "make", "--no-print-directory", "-f", str(package / "Makefile"), "-f", str(harness),
        f"TOPDIR={make_root}", f"INCLUDE_DIR={make_root / 'include'}", "all",
    ], cwd=package, capture_output=True, text=True, check=True)
    extracted = {name: completed.stdout.split(f"__BEGIN_{name}__\n", 1)[1].split(f"__END_{name}__", 1)[0]
                 for name in declarations}
    scripts = {}
    for phase, kind in HOOKS.items():
        path = destination / kind
        path.write_text(extracted[phase])
        subprocess.run(["sh", "-n", str(path)], check=True)
        scripts[kind] = path
    for phase, kind in (("preinst", "pre-upgrade"), ("postinst", "post-upgrade")):
        path = destination / kind
        path.write_text("#!/bin/sh\nexport PKG_UPGRADE=1\n" +
                        "\n".join(line for line in extracted[phase].splitlines() if not line.startswith("#!")) + "\n")
        subprocess.run(["sh", "-n", str(path)], check=True)
        scripts[kind] = path
    dependencies = re.search(r"DEPENDS:=(.*)", extracted["definition"]).group(1).split()
    return {"id": manifest["id"], "package": manifest["package"], "version": version,
            "revision": generated["revision"], "payload": payload, "scripts": scripts,
            "dependencies": [value.removeprefix("+") for value in dependencies]}


def build(output, sdk):
    apk = sdk / "staging_dir/host/bin/apk"
    if platform.system() != "Linux" or platform.machine() not in ("x86_64", "AMD64") or os.geteuid() != 0:
        raise SystemExit("Run this fixture builder as root in the existing linux/amd64 SDK builder container")
    if not apk.is_file():
        raise SystemExit("SDK host apk is unavailable")
    if output.exists():
        raise SystemExit("Fixture output already exists")
    output.mkdir(mode=0o700, parents=True)
    receipt = {"schema_version": 1, "plugins": {}}
    with tempfile.TemporaryDirectory(prefix="netfleet-plugin-fixtures-") as temporary:
        scratch = Path(temporary)
        private_key = scratch / "key.pem"
        public_key = output / "plugin-fixture.pem"
        subprocess.run(["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256",
                        "-out", str(private_key)], check=True, capture_output=True)
        subprocess.run(["openssl", "pkey", "-in", str(private_key), "-pubout", "-out", str(public_key)],
                       check=True, capture_output=True)

        def pack(name, version, payload, dependencies=(), scripts=None, provides=()):
            target = output / f"{name}-{version}.apk"
            command = [str(apk), "mkpkg", "--files", str(payload), "--sign-key", str(private_key),
                       "--output", str(target)]
            info = {"name": name, "version": version, "arch": "noarch", "license": "Apache-2.0",
                    "description": "Disposable NetFleet plugin qualification fixture"}
            if dependencies:
                info["depends"] = " ".join(dependencies)
            if provides:
                info["provides"] = " ".join(provides)
            for key, value in info.items():
                command.extend(("--info", f"{key}:{value}"))
            for kind, path in (scripts or {}).items():
                command.extend(("--script", f"{kind}:{path}"))
            subprocess.run(command, check=True, capture_output=True, text=True)
            subprocess.run([str(apk), "verify", "--keys-dir", str(output), str(target)],
                           check=True, capture_output=True, text=True)
            return {"name": target.name, "sha256": hashlib.sha256(target.read_bytes()).hexdigest()}

        host = scratch / "host"
        host.mkdir()
        receipt["host"] = pack("netfleet-plugin-vm-host", "1.0.0-r1", host,
                               provides=("netfleet-plugin-api-v1=1", "opl-netfleet-kernel=0.8.0"))
        for identity in ("device-info", "workspace-note"):
            receipt["plugins"][identity] = {}
            for version in ("0.1.0", "0.1.1"):
                staged = stage_plugin(ROOT / "examples/plugins" / identity, scratch / f"{identity}-{version}", version)
                artifact = pack(staged["package"], f"{version}-r1", staged["payload"],
                                staged["dependencies"], staged["scripts"])
                receipt["plugins"][identity][version] = {**artifact, "revision": staged["revision"]}
    (output / "fixture.json").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    return receipt


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--sdk", type=Path, default=os.environ.get("NETFLEET_SDK"))
    args = parser.parse_args()
    if args.sdk is None:
        parser.error("--sdk or NETFLEET_SDK is required")
    build(args.output.resolve(), args.sdk.resolve())
