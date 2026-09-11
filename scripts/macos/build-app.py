#!/usr/bin/env python3
"""Build the local macOS MVP app. No privileged installation or network takeover."""
import argparse
import json
import importlib.util
import platform
import plistlib
from pathlib import Path
import shutil
import sys
import subprocess
import tempfile

from bootstrap import HERE, prepare, run, sha256, verify

REPO = HERE.parents[1]
spec = importlib.util.spec_from_file_location("builtin_assets", HERE / "builtin-assets.py")
builtin_assets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builtin_assets)


def build_icon(staging, resources):
    """Convert the canonical logo to macOS representations without redrawing it."""
    logo = REPO / "assets/branding/opl-netfleet-logo.png"
    branding = resources / "assets/branding"
    branding.mkdir(parents=True)
    shutil.copy2(logo, branding / logo.name)
    iconset = staging / "NetFleet.iconset"
    iconset.mkdir()
    renderer = staging / "render-icon"
    run("swiftc", "-O", "-framework", "AppKit", HERE / "render-icon.swift", "-o", renderer)
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            suffix = "@2x" if scale == 2 else ""
            run(renderer, logo, iconset / f"icon_{size}x{size}{suffix}.png", str(size * scale))
    run("iconutil", "-c", "icns", iconset, "-o", resources / "NetFleet.icns")


def build_desktop_ui():
    """Build the shared React UI with the dedicated production desktop entry."""
    bun = shutil.which("bun")
    if not bun:
        raise RuntimeError("Required build tool missing: bun")
    ui = REPO / "ui"
    for args in (("install", "--frozen-lockfile"), ("run", "typecheck"), ("run", "build:desktop")):
        subprocess.run([bun, *args], cwd=ui, check=True, stdout=sys.stderr)
    output = ui / "dist-desktop"
    if not (output / "desktop.html").is_file():
        raise RuntimeError("Desktop production build did not produce desktop.html")
    return output


def source_identity(repo):
    def git(*args):
        return subprocess.check_output(["git", "-C", str(repo), *args], text=True).strip()
    return {"source_commit": git("rev-parse", "HEAD^{commit}"),
            "source_tree": git("rev-parse", "HEAD^{tree}"),
            "working_tree_dirty": bool(git("status", "--porcelain", "--untracked-files=all"))}


def build_identity(repo, require_clean=False, signing_identity=None):
    if signing_identity and not require_clean:
        raise RuntimeError("Developer ID distribution requires --require-clean-source")
    identity = source_identity(repo)
    if require_clean and identity["working_tree_dirty"]:
        raise RuntimeError("Local delivery requires committed, clean source; use a development build for uncommitted changes")
    info = plistlib.loads((repo / "desktop/app/Info.plist").read_bytes())
    return {"schema": "opl-netfleet-macos-build.v1", "platform": "macos",
            "package_version": info["CFBundleShortVersionString"],
            "package_release": info["CFBundleVersion"], "build_target_arch": platform.machine(),
            "channel": "distribution" if signing_identity else ("local" if require_clean else "development"), **identity}


def verify_source_unchanged(repo, identity):
    current = source_identity(repo)
    if current != {key: identity[key] for key in current}:
        raise RuntimeError("Source identity changed during build; previous app preserved")


def build(output, cache, require_clean=False, signing_identity=None):
    if output.suffix != ".app":
        raise RuntimeError("Output must have an .app extension")
    for relative in ("desktop/app/main.swift", "desktop/app/Info.plist", "desktop/helper/NetworkHelper.swift",
                     "desktop/runtime/server.mjs", "ui/desktop.html", "ui/vite.desktop.config.ts", "assets/branding/opl-netfleet-logo.png"):
        if not (REPO / relative).is_file():
            raise RuntimeError(f"Required desktop source missing: {relative}")
    identity = build_identity(REPO, require_clean, signing_identity)
    web = build_desktop_ui()
    runtime = prepare(cache)
    # A sibling staging directory preserves a previously built app on failure.
    output.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".netfleet-app-", dir=output.parent))
    app = staging / output.name
    contents = app / "Contents"
    resources = contents / "Resources"
    (contents / "MacOS").mkdir(parents=True)
    resources.mkdir()
    try:
        build_icon(staging, resources)
        for name in ("runtime", "ucode", "helper"):
            source = REPO / "desktop" / name
            if not source.is_dir():
                raise RuntimeError(f"Required desktop source missing: {source}")
            shutil.copytree(source, resources / "desktop" / name,
                            ignore=shutil.ignore_patterns("__pycache__", "*.pyc", "node_modules"))
        shutil.copytree(web, resources / "desktop/web")
        builtin_assets.prepare_builtin(resources / "builtin", cache / "rulesets")
        shutil.copytree(REPO / "openwrt/files/usr/libexec/opl-netfleet", resources / "shared")
        (resources / "runtime/bin").mkdir(parents=True)
        for name in ("ucode", "node", "mihomo", "yq", "sha256sum"):
            shutil.copy2(runtime / "bin" / name, resources / "runtime/bin" / name)
        shutil.copytree(runtime / "lib", resources / "runtime/lib", symlinks=True)
        # Build-only headers, archives and pkg-config metadata are not runtime dependencies.
        for pattern in ("*.a", "pkgconfig", "cmake"):
            for path in (resources / "runtime/lib").glob(pattern):
                shutil.rmtree(path) if path.is_dir() else path.unlink()
        shutil.copytree(runtime / "licenses", resources / "licenses")
        shutil.copy2(REPO / "LICENSE", resources / "licenses/OPL-NetFleet-LICENSE")
        upstream = json.loads((resources / "builtin/rulesets.lock.json").read_text())["upstream"]
        (resources / "licenses/meta-rules-dat-NOTICE").write_text(
            f"MetaCubeX/meta-rules-dat rulesets ({upstream['license']})\n"
            f"Source: https://github.com/{upstream['repository']}/tree/{upstream['commit']}\n"
            "GPL-3.0 license text is included in mihomo-LICENSE.\n")
        shutil.copy2(HERE / "patches/ucode-darwin.patch", resources / "licenses/ucode-darwin.patch")
        for name in ("dependencies.json", "dependency-receipt.json"):
            shutil.copy2(runtime / name, resources / name)
        shutil.copy2(REPO / "desktop/app/Info.plist", contents / "Info.plist")
        (resources / "build.json").write_text(json.dumps(identity, indent=2) + "\n")
        run("swiftc", "-O", "-target", platform.machine() + "-apple-macosx13.0", "-framework", "AppKit", "-framework", "WebKit",
            REPO / "desktop/app/main.swift", "-o", contents / "MacOS/OPL NetFleet")
        run("swiftc", "-O", "-target", platform.machine() + "-apple-macosx13.0", "-framework", "SystemConfiguration",
            REPO / "desktop/helper/NetworkHelper.swift", "-o",
            resources / "runtime/bin/netfleet-network-helper")
        verify(resources / "runtime")
        # Node's V8 JIT needs MAP_JIT under the hardened runtime. Other binaries
        # and the app retain the default entitlement set.
        node_entitlements = staging / "node-entitlements.plist"
        node_entitlements.write_bytes(plistlib.dumps({"com.apple.security.cs.allow-jit": True}))
        signing = ["--force", "--sign", signing_identity or "-"]
        if signing_identity:
            signing += ["--options", "runtime", "--timestamp"]
        for path in sorted(app.rglob("*")):
            if path.is_file() and not path.is_symlink():
                kind = subprocess.check_output(["file", "-b", str(path)], text=True)
                if "Mach-O" in kind:
                    extra = ["--entitlements", node_entitlements] if signing_identity and path == resources / "runtime/bin/node" else []
                    run("codesign", *signing, *extra, path)
        run("codesign", *signing, app)
        if signing_identity:
            details = subprocess.run(["codesign", "-dv", "--verbose=4", str(app)], capture_output=True, text=True, check=True).stderr
            if "Authority=Developer ID Application:" not in details or "runtime" not in details:
                raise RuntimeError("Distribution requires Developer ID Application and hardened runtime")
        run("codesign", "--verify", "--deep", "--strict", app)
        verify_source_unchanged(REPO, identity)
        receipt = {"app": str(output), **identity,
                   "dependency_lock_sha256": sha256(HERE / "dependencies.json"),
                   "brand_logo_sha256": sha256(REPO / "assets/branding/opl-netfleet-logo.png"),
                   "signing": "developer-id" if signing_identity else "ad-hoc", "notarized": False,
                   "network_settings_changed": False,
                   "checks": ["react_typecheck", "desktop_production_build", "native_ucode_fs_socket", "ucode_popen_shell_argv", "mihomo_version", "node_version",
                              "yq_readonly_conversion", "portable_dynamic_libraries", "codesign_strict"]}
        previous = output.with_name(output.name + ".previous")
        if previous.exists():
            shutil.rmtree(previous)
        if output.exists():
            output.rename(previous)
        app.rename(output)
        if previous.exists():
            shutil.rmtree(previous)
        (output.parent / "build-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        print(json.dumps(receipt, indent=2))
    finally:
        shutil.rmtree(staging)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=REPO / ".build/macos/OPL NetFleet.app")
    parser.add_argument("--cache", type=Path, default=Path.home() / ".cache/opl-netfleet/macos")
    parser.add_argument("--require-clean-source", action="store_true",
                        help="Build for local delivery; reject uncommitted source before building")
    parser.add_argument("--signing-identity", help="Developer ID Application identity for distribution (requires clean source)")
    args = parser.parse_args()
    build(args.output.resolve(), args.cache.resolve(), args.require_clean_source, args.signing_identity)
