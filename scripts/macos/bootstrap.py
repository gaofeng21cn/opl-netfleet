#!/usr/bin/env python3
"""Build a pinned, relocatable macOS runtime without sudo or package-manager writes."""
import argparse
import fcntl
import gzip
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile

HERE = Path(__file__).resolve().parent
LOCK = json.loads((HERE / "dependencies.json").read_text())


def run(*args, env=None):
    subprocess.run([str(a) for a in args], check=True, env=env, stdout=sys.stderr)


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def download(entry, sources):
    target = sources / entry["filename"]
    if target.exists() and sha256(target) != entry["sha256"]:
        raise RuntimeError(f"Cached dependency checksum mismatch: {target}")
    if not target.exists():
        temporary = target.with_name(target.name + ".download")
        run("curl", "--fail", "--location", "--retry", "2", "--silent", "--show-error",
            entry["url"], "--output", temporary)
        if sha256(temporary) != entry["sha256"]:
            temporary.unlink()
            raise RuntimeError(f"Downloaded dependency checksum mismatch: {entry['filename']}")
        temporary.replace(target)
    return target


def extract(archive, destination):
    # Dependencies are pinned trusted upstream archives; still reject path escapes.
    with tarfile.open(archive) as bundle:
        for member in bundle.getmembers():
            resolved = (destination / member.name).resolve()
            if not resolved.is_relative_to(destination.resolve()):
                raise RuntimeError(f"Unsafe archive path: {member.name}")
            if member.issym() or member.islnk():
                if not (resolved.parent / member.linkname).resolve().is_relative_to(destination.resolve()):
                    raise RuntimeError(f"Unsafe archive link: {member.name}")
        bundle.extractall(destination, filter="data") if hasattr(tarfile, "data_filter") else bundle.extractall(destination)


def prepare(cache):
    if platform.system() != "Darwin" or platform.machine() not in ("arm64", "x86_64"):
        raise RuntimeError("Build on native arm64 or x86_64 macOS")
    arch = platform.machine()
    sources = cache / "sources"
    sources.mkdir(parents=True, exist_ok=True)
    # The lock identity isolates builds across dependency updates and architectures.
    identity = sha256(HERE / "dependencies.json")[:16] + "-" + sha256(HERE / "patches/ucode-darwin.patch")[:8] + "-macos13-" + arch
    root = cache / "builds" / identity
    runtime = root / "runtime"
    with (sources / ".bootstrap.lock").open("w") as gate:
        fcntl.flock(gate, fcntl.LOCK_EX)
        if (runtime / "dependency-receipt.json").exists():
            return runtime
        root.mkdir(parents=True, exist_ok=True)
        for program in ("cmake", "pkg-config", "clang", "curl"):
            if not shutil.which(program):
                raise RuntimeError(f"Required build tool missing: {program}")
        archives = {name: download(LOCK[name], sources) for name in ("ucode", "json-c")}
        for archive in archives.values():
            extract(archive, sources)
        json_source = sources / "json-c-json-c-0.18-20240915"
        uc_source = sources / ("ucode-" + LOCK["ucode"]["version"])
        run("patch", "--batch", "-p1", "-d", uc_source, "-i", HERE / "patches/ucode-darwin.patch")
        run("cmake", "-S", json_source, "-B", root / "json-c", "-DCMAKE_POLICY_VERSION_MINIMUM=3.5",
            "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_OSX_DEPLOYMENT_TARGET=13.0", f"-DCMAKE_INSTALL_PREFIX={runtime}",
            "-DBUILD_SHARED_LIBS=OFF", "-DBUILD_TESTING=OFF", "-DDISABLE_EXTRA_LIBS=ON")
        run("cmake", "--build", root / "json-c", "--parallel", "4")
        run("cmake", "--install", root / "json-c")
        env = dict(os.environ, PKG_CONFIG_LIBDIR=str(runtime / "lib/pkgconfig"), PKG_CONFIG_PATH="")
        disabled = ("UBUS", "UCI", "ULOOP", "RTNL", "NL80211", "FFI", "DIGEST", "SERIAL", "ZLIB")
        run("cmake", "-S", uc_source, "-B", root / "ucode", "-DCMAKE_BUILD_TYPE=Release",
            f"-DCMAKE_INSTALL_PREFIX={runtime}", "-DCMAKE_OSX_DEPLOYMENT_TARGET=13.0", "-DLIB_SEARCH_PATH=./*.so:./*.uc",
            *[f"-D{name}_SUPPORT=OFF" for name in disabled], env=env)
        run("cmake", "--build", root / "ucode", "--parallel", "4")
        run("cmake", "--install", root / "ucode")
        binaries = runtime / "bin"
        node_archive = download(LOCK["node"][arch], sources)
        extract(node_archive, sources)
        node_source = sources / node_archive.name.removesuffix(".tar.gz")
        shutil.copy2(node_source / "bin/node", binaries / "node")
        with gzip.open(download(LOCK["mihomo"][arch], sources), "rb") as zipped:
            (binaries / "mihomo").write_bytes(zipped.read())
        shutil.copy2(download(LOCK["yq"][arch], sources), binaries / "yq")
        (binaries / "sha256sum").write_text('#!/bin/sh\nexec /usr/bin/shasum -a 256 "$@"\n')
        for name in ("node", "mihomo", "yq", "sha256sum"):
            (binaries / name).chmod(0o755)
        licenses = runtime / "licenses"
        licenses.mkdir(exist_ok=True)
        for name, source in (("ucode", uc_source / "LICENSE"), ("json-c", json_source / "COPYING"),
                             ("node", node_source / "LICENSE")):
            shutil.copy2(source, licenses / (name + "-LICENSE"))
        for name in ("mihomo", "yq"):
            shutil.copy2(download(LOCK[name + "-license"], sources), licenses / (name + "-LICENSE"))
        shutil.copy2(HERE / "dependencies.json", runtime / "dependencies.json")
        verify(runtime)
        receipt = {"architecture": arch, "dependency_lock_sha256": sha256(HERE / "dependencies.json"),
                   "versions": {k: v["version"] for k, v in LOCK.items() if isinstance(v, dict) and "version" in v},
                   "ucode_darwin_patch_sha256": sha256(HERE / "patches/ucode-darwin.patch"),
                   "network_settings_changed": False}
        (runtime / "dependency-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return runtime


def verify(runtime):
    for file in sorted(runtime.rglob("*")):
        if not file.is_file() or file.is_symlink():
            continue
        kind = subprocess.check_output(["file", "-b", str(file)], text=True)
        if "Mach-O" not in kind:
            continue
        linked = subprocess.check_output(["otool", "-L", str(file)], text=True)
        for line in linked.splitlines()[1:]:
            dependency = line.strip().split(" (", 1)[0]
            if not dependency.startswith(("@rpath/", "@loader_path/", "@executable_path/", "/usr/lib/", "/System/Library/")):
                raise RuntimeError(f"Non-portable dynamic dependency in {file}: {dependency}")
    run(runtime / "bin/ucode", "-L", str(runtime / "lib/ucode/*.so"), "-e",
        'import { readfile } from "fs"; import * as socket from "socket"; assert(readfile("/dev/null") == ""); print("ucode fs/socket OK\\n");')
    run(runtime / "bin/ucode", "-L", str(runtime / "lib/ucode/*.so"), "-e",
        'import * as fs from "fs"; for (let command in ["printf shell-ok", ["printf", "shell-ok"]]) { let p = fs.popen(command); assert(p != null); assert(p.read("all") == "shell-ok"); assert(p.close() == 0); } print("ucode popen shell/argv OK\\n");')
    run(runtime / "bin/node", "--version")
    run(runtime / "bin/mihomo", "-v")
    run(runtime / "bin/yq", "--version")
    result = subprocess.check_output([str(runtime / "bin/yq"), "-M", "-p", "yaml", "-o", "json"], input="a: 1\n", text=True)
    if json.loads(result) != {"a": 1}:
        raise RuntimeError("yq read-only YAML to JSON conversion failed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", type=Path, default=Path.home() / ".cache/opl-netfleet/macos")
    args = parser.parse_args()
    print(prepare(args.cache.resolve()))
