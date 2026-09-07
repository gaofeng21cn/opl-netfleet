#!/usr/bin/env python3
"""Scaffold and package NetFleet device plugins using the OpenWrt SDK."""

import argparse
import json
import re
import shutil
import stat
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXAMPLE = ROOT / "examples/plugins/device-info"
FIELDS = {"schema", "id", "label", "version", "api_version", "package",
          "dependencies", "backends", "permissions", "actions"}
RESERVED = {"https-compat", "zashboard"}
LIFECYCLE = {"get", "load", "unload", "reload"}


def valid_id(value):
    return (isinstance(value, str) and len(value) <= 48 and value not in RESERVED
            and re.fullmatch(r"[a-z][a-z0-9]*(-[a-z0-9]+)*", value) is not None)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def validate(source):
    if source.is_symlink() or not source.is_dir():
        raise ValueError("plugin source must be a regular directory")
    files = []
    for path in sorted(source.rglob("*")):
        relative = path.relative_to(source)
        info = path.lstat()
        if any(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", part) is None
               for part in relative.parts):
            raise ValueError(f"unsupported payload path: {relative}")
        if not (stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode)):
            raise ValueError(f"payload must not contain links or special files: {relative}")
        if info.st_mode & 0o022:
            raise ValueError(f"payload must not be writable by group or others: {relative}")
        if relative.parts[0] not in {"manifest.json", "control", "LICENSE", "resources"}:
            raise ValueError(f"put additional payload under resources/: {relative}")
        if stat.S_ISREG(info.st_mode):
            files.append(relative)
    manifest_path, control = source / "manifest.json", source / "control"
    if not manifest_path.is_file() or manifest_path.stat().st_size > 16384:
        raise ValueError("manifest.json must be a regular file of at most 16384 bytes")
    if (not control.is_file() or not control.stat().st_mode & 0o111
            or control.stat().st_size > 1048576):
        raise ValueError("control must be executable and at most 1048576 bytes")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"), object_pairs_hook=unique_object)
    if not isinstance(manifest, dict) or set(manifest) != FIELDS:
        raise ValueError("manifest must contain exactly the API v1 fields")
    if manifest["schema"] != "opl-netfleet-plugin.v1" or not valid_id(manifest["id"]):
        raise ValueError("invalid plugin schema or id")
    if type(manifest["api_version"]) is not int or manifest["api_version"] != 1:
        raise ValueError("this SDK supports api_version 1")
    if (not isinstance(manifest["label"], str) or not 1 <= len(manifest["label"]) <= 120
            or any(ord(char) < 32 for char in manifest["label"])):
        raise ValueError("label must contain 1 to 120 printable characters")
    if (not isinstance(manifest["version"], str)
            or re.fullmatch(r"[0-9][A-Za-z0-9.+~-]{0,63}", manifest["version"]) is None):
        raise ValueError("invalid package version")
    if manifest["package"] != f"opl-netfleet-plugin-{manifest['id']}":
        raise ValueError("package must be opl-netfleet-plugin-<id>")
    for key in ("dependencies", "backends", "permissions"):
        if not isinstance(manifest[key], list) or any(not isinstance(value, str) for value in manifest[key]):
            raise ValueError(f"{key} must be an array of strings")
        if len(set(manifest[key])) != len(manifest[key]):
            raise ValueError(f"{key} must not contain duplicates")
    if any(re.fullmatch(r"[a-z][a-z0-9+-]*", name) is None for name in manifest["dependencies"]):
        raise ValueError("invalid dependency package name")
    if not manifest["backends"] or set(manifest["backends"]) - {"native-mihomo", "nikki-mihomo"}:
        raise ValueError("unsupported backend")
    if set(manifest["permissions"]) - {"diagnostics", "network", "resources"}:
        raise ValueError("unsupported permission")
    actions = manifest["actions"]
    if not isinstance(actions, dict) or any(
            not valid_id(name) or name in LIFECYCLE or access not in ("read", "write")
            for name, access in actions.items()):
        raise ValueError("invalid custom action or access; lifecycle actions are implicit")
    return manifest, files


def create_directory(destination, populate):
    if destination.exists() or destination.is_symlink():
        raise ValueError(f"destination already exists: {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=f".{destination.name}.", dir=destination.parent))
    try:
        populate(temporary)
        temporary.chmod(0o755)
        if destination.exists() or destination.is_symlink():
            raise ValueError(f"destination already exists: {destination}")
        temporary.rename(destination)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)


def scaffold(plugin_id, destination, label):
    if not valid_id(plugin_id):
        raise ValueError("invalid or reserved plugin id")
    manifest, _ = validate(EXAMPLE)
    manifest.update(id=plugin_id, label=label or plugin_id,
                    package=f"opl-netfleet-plugin-{plugin_id}")

    def populate(target):
        (target / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        control = (EXAMPLE / "control").read_text(encoding="utf-8")
        (target / "control").write_text(control.replace('const ID = "device-info";', f'const ID = "{plugin_id}";'), encoding="utf-8")
        (target / "control").chmod(0o755)
        shutil.copyfile(ROOT / "LICENSE", target / "LICENSE")
        validate(target)

    create_directory(destination, populate)
    return {"id": plugin_id, "source": str(destination), "actions": manifest["actions"]}


DRAIN_HOOK = r'''#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
id=@ID@
main=/usr/libexec/opl-netfleet/main.uc
# Keep new calls out until the package manager has finished replacing files.
until ucode -e '
import * as fs from "fs";
const root = "/var/run/opl-netfleet-plugin-maintenance";
for (let path in [root, `${root}/${ARGV[0]}`]) {
    if (fs.lstat(path) == null && !fs.mkdir(path, 0700)) exit(1);
    const info = fs.lstat(path);
    if (info?.type != "directory" || info.uid != 0 || (info.mode & 022)) exit(1);
}
' "$id"; do
    printf '%s\n' "$id: waiting for a safe package maintenance directory" >&2
    sleep 2
done
umask 077
until work=$(mktemp -d /tmp/opl-netfleet-plugin-package.XXXXXX); do sleep 2; done
trap 'rm -rf "$work"' EXIT
drain() {
    ucode "$main" plugins-list >"$work/list.json" || return 1
    ucode -e '
import * as fs from "fs";
const list = json(fs.readfile(ARGV[0]));
const row = filter(list?.result?.plugins ?? [], item => item.id == ARGV[2])[0];
const revision = row == null ? "absent" : row.revision;
if (list?.ok != true || type(revision) != "string") exit(1);
printf("%J\n", { request: { id: ARGV[2], action: "unload", revision: revision, confirm: true, params: {} } });
' "$work/list.json" "$work/request.json" "$id" >"$work/request.json" || return 1
    ucode "$main" plugin-drain "$work/request.json" >"$work/call.json" || return 1
    ucode -e '
import * as fs from "fs";
const result = json(fs.readfile(ARGV[0]));
exit(result?.ok == true && result?.result?.loaded == false && result?.result?.state == "replacing" ? 0 : 1);
' "$work/call.json"
}
if ! drain; then
    printf '%s\n' "$id: waiting for unload/readback; old plugin files must remain available" >&2
    # APK may ignore a failing hook, so do not return until exit is confirmed.
    until drain; do sleep 2; done
fi
exit 0
'''


def makefile(manifest, license_id, release):
    if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.+-]*", license_id) is None:
        raise ValueError("--license must be one SPDX license identifier")
    if release < 1:
        raise ValueError("--release must be positive")
    plugin_id, package = manifest["id"], manifest["package"]
    dependencies = " ".join("+" + name for name in dict.fromkeys(
        ["opl-netfleet", "netfleet-plugin-api-v1", *manifest["dependencies"]]))
    hook = DRAIN_HOOK.replace("@ID@", plugin_id).replace("$", "$$")
    clear = f'''#!/bin/sh
[ -n "$${{IPKG_INSTROOT}}" ] && exit 0
rm -f /var/run/opl-netfleet-plugin-maintenance/{plugin_id}/replacing
rmdir /var/run/opl-netfleet-plugin-maintenance/{plugin_id} 2>/dev/null || true
exit 0
'''
    postrm = clear.replace('rm -f ', '[ "$${PKG_UPGRADE:-0}" = 1 ] && exit 0\n[ "$$1" = upgrade ] && exit 0\nrm -f ')
    return f'''include $(TOPDIR)/rules.mk

PKG_NAME:={package}
PKG_VERSION:={manifest["version"]}
PKG_RELEASE:={release}
PKG_LICENSE:={license_id}

include $(INCLUDE_DIR)/package.mk

define Package/{package}
  SECTION:=net
  CATEGORY:=Network
  TITLE:=NetFleet plugin: {plugin_id}
  DEPENDS:={dependencies}
  PKGARCH:=all
endef

define Package/{package}/description
  Independently installed NetFleet device plugin: {plugin_id}.
endef

define Build/Compile
endef

define Package/{package}/preinst
{hook}endef

define Package/{package}/prerm
{hook}endef

define Package/{package}/postinst
{clear}endef

define Package/{package}/postrm
{postrm}endef

define Package/{package}/install
\t$(INSTALL_DIR) $(1)/usr/libexec/opl-netfleet/plugins/{plugin_id}
\t$(CP) ./files/. $(1)/usr/libexec/opl-netfleet/plugins/{plugin_id}/
endef

$(eval $(call BuildPackage,{package}))
'''


def package_source(source, destination, license_id, release):
    manifest, files = validate(source)
    content = makefile(manifest, license_id, release)
    if source.resolve() == destination.resolve() or source.resolve() in destination.resolve().parents:
        raise ValueError("package output must be outside the plugin source")

    def populate(target):
        (target / "Makefile").write_text(content, encoding="utf-8")
        (target / "files").mkdir(mode=0o755)
        for relative in files:
            output = target / "files" / relative
            output.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source / relative, output)
            output.chmod(0o755 if (source / relative).stat().st_mode & 0o111 else 0o644)
        validate(target / "files")

    create_directory(destination, populate)
    return {"id": manifest["id"], "package": manifest["package"], "package_source": str(destination)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    create = commands.add_parser("scaffold", help="create a runnable UCode plugin project")
    create.add_argument("id")
    create.add_argument("destination", type=Path)
    create.add_argument("--label")
    check = commands.add_parser("validate", help="validate the manifest and installable payload")
    check.add_argument("source", type=Path)
    package = commands.add_parser("package-source", help="generate standard OpenWrt package source")
    package.add_argument("source", type=Path)
    package.add_argument("destination", type=Path)
    package.add_argument("--license", required=True, help="SPDX identifier matching your plugin license")
    package.add_argument("--release", type=int, default=1)
    args = parser.parse_args()
    try:
        if args.command == "scaffold":
            result = scaffold(args.id, args.destination, args.label)
        elif args.command == "validate":
            manifest, files = validate(args.source)
            result = {"id": manifest["id"], "api_version": manifest["api_version"], "files": [str(path) for path in files]}
        else:
            result = package_source(args.source, args.destination, args.license, args.release)
    except (ValueError, OSError) as error:
        print(json.dumps({"ok": False, "error": str(error)}), file=sys.stderr)
        return 1
    print(json.dumps({"ok": True, "result": result}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
