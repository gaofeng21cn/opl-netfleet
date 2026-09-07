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
SERVICE_EXAMPLE = ROOT / "examples/plugins/host-info"
COMMON_FIELDS = {"schema", "id", "label", "version", "api_version", "package"}
PROCESS_FIELDS = COMMON_FIELDS | {"dependencies", "backends", "permissions", "actions"}
SERVICE_FIELDS = COMMON_FIELDS | {"services", "commands"}
LIFECYCLE = {"get", "load", "unload", "reload"}


def valid_id(value):
    return (isinstance(value, str) and len(value) <= 48
            and re.fullmatch(r"[a-z][a-z0-9]*(-[a-z0-9]+)*", value) is not None)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def validate_identity(manifest):
    if not valid_id(manifest["id"]):
        raise ValueError("invalid plugin id")
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


def validate_package_names(value, field):
    if (not isinstance(value, list) or any(not isinstance(name, str) for name in value)
            or len(set(value)) != len(value)):
        raise ValueError(f"{field} must be an array of unique package names")
    if any(re.fullmatch(r"[a-z][a-z0-9+-]*", name) is None for name in value):
        raise ValueError(f"invalid package name in {field}")


def validate_process(manifest):
    for key in ("dependencies", "backends", "permissions"):
        if not isinstance(manifest[key], list) or any(not isinstance(value, str) for value in manifest[key]):
            raise ValueError(f"{key} must be an array of strings")
        if len(set(manifest[key])) != len(manifest[key]):
            raise ValueError(f"{key} must not contain duplicates")
    validate_package_names(manifest["dependencies"], "dependencies")
    if not manifest["backends"] or set(manifest["backends"]) - {"native-mihomo", "nikki-mihomo"}:
        raise ValueError("unsupported backend")
    if set(manifest["permissions"]) - {"diagnostics", "network", "resources"}:
        raise ValueError("unsupported permission")
    actions = manifest["actions"]
    if not isinstance(actions, dict) or any(
            not valid_id(name) or name in LIFECYCLE or access not in ("read", "write")
            for name, access in actions.items()):
        raise ValueError("invalid custom action or access; lifecycle actions are implicit")


def valid_service(value):
    return (isinstance(value, str) and len(value) <= 128
            and re.fullmatch(r"[a-z][a-z0-9-]*(\.[a-z][a-z0-9-]*)+", value) is not None)


def validate_method(value, fields):
    return (isinstance(value, dict) and set(value) == fields
            and valid_service(value.get("service")) and isinstance(value.get("method"), str)
            and re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*", value["method"]) is not None)


def validate_service(manifest, source):
    validate_package_names(manifest.get("package_dependencies", []), "package_dependencies")
    services, commands = manifest["services"], manifest["commands"]
    if not isinstance(services, dict) or not services:
        raise ValueError("services must declare at least one service")
    for name, service in services.items():
        if (not valid_service(name) or not isinstance(service, dict)
                or set(service) != {"version", "module", "requires"}
                or type(service["version"]) is not int or service["version"] < 1):
            raise ValueError(f"invalid service declaration: {name}")
        module = service["module"]
        if (not isinstance(module, str)
                or re.fullmatch(r"lib/[A-Za-z0-9_-]+(/[A-Za-z0-9_-]+)*\.uc", module) is None
                or not (source / module).is_file()):
            raise ValueError(f"service module must name an installed relative UCode file: {name}")
        requires = service["requires"]
        if not isinstance(requires, dict) or any(
                not valid_service(dependency) or type(major) is not int or major < 1
                for dependency, major in requires.items()):
            raise ValueError(f"invalid required service interface: {name}")
    if not isinstance(commands, dict) or any(
            not valid_id(name) or not validate_method(command, {"service", "method", "access"})
            or command["service"] not in services
            or command["access"] not in ("read", "write")
            for name, command in commands.items()):
        raise ValueError("invalid service command")
    if "lifecycle" in manifest:
        lifecycle = manifest["lifecycle"]
        if not isinstance(lifecycle, dict) or set(lifecycle) != {"drain", "resume"} or any(
                not validate_method(method, {"service", "method"}) or method["service"] not in services
                for method in lifecycle.values()):
            raise ValueError("lifecycle must declare local drain and resume methods")


def validate(source):
    if source.is_symlink() or not source.is_dir():
        raise ValueError("plugin source must be a regular directory")
    manifest_path = source / "manifest.json"
    if (manifest_path.is_symlink() or not manifest_path.is_file()
            or manifest_path.stat().st_size > 16384):
        raise ValueError("manifest.json must be a regular file of at most 16384 bytes")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"), object_pairs_hook=unique_object)
    if not isinstance(manifest, dict):
        raise ValueError("manifest must be an object")
    service_plugin = manifest.get("schema") == "opl-netfleet-service-plugin.v1"
    if service_plugin:
        if not SERVICE_FIELDS <= set(manifest) or set(manifest) - SERVICE_FIELDS - {"package_dependencies", "lifecycle"}:
            raise ValueError("manifest must contain the service API v1 fields")
    elif manifest.get("schema") != "opl-netfleet-plugin.v1" or set(manifest) != PROCESS_FIELDS:
        raise ValueError("manifest must contain the process API v1 fields")
    validate_identity(manifest)
    files = []
    for path in sorted(source.rglob("*")):
        relative = path.relative_to(source)
        info = path.lstat()
        if any(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", part) is None for part in relative.parts):
            raise ValueError(f"unsupported payload path: {relative}")
        if not (stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode)):
            raise ValueError(f"payload must not contain links or special files: {relative}")
        if info.st_mode & 0o022:
            raise ValueError(f"payload must not be writable by group or others: {relative}")
        if not service_plugin and relative.parts[0] not in {"manifest.json", "control", "LICENSE", "resources"}:
            raise ValueError(f"put additional payload under resources/: {relative}")
        if stat.S_ISREG(info.st_mode):
            if info.st_size > 1048576 or len(files) >= 512:
                raise ValueError("plugin payload exceeds the runtime file limits")
            files.append(relative)
    if service_plugin:
        validate_service(manifest, source)
    else:
        control = source / "control"
        if (not control.is_file() or not control.stat().st_mode & 0o111 or control.stat().st_size > 1048576):
            raise ValueError("control must be executable and at most 1048576 bytes")
        validate_process(manifest)
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


def scaffold(plugin_id, destination, label, kind="process"):
    if not valid_id(plugin_id) or kind not in ("process", "service"):
        raise ValueError("invalid plugin id or kind")
    example = SERVICE_EXAMPLE if kind == "service" else EXAMPLE
    manifest, files = validate(example)
    manifest.update(id=plugin_id, label=label or plugin_id,
                    package=f"opl-netfleet-plugin-{plugin_id}")
    if kind == "service":
        manifest["services"] = {
            name.replace("host-info.", f"{plugin_id}.", 1): {
                **service, "requires": {name.replace("host-info.", f"{plugin_id}.", 1): major
                                        for name, major in service["requires"].items()}}
            for name, service in manifest["services"].items()}
        manifest["commands"] = {plugin_id: {"service": f"{plugin_id}.summary", "method": "inspect", "access": "read"}}

    def populate(target):
        (target / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        for relative in files:
            if str(relative) in {"manifest.json", "LICENSE"}:
                continue
            output = target / relative
            output.parent.mkdir(parents=True, exist_ok=True)
            content = (example / relative).read_text(encoding="utf-8")
            content = content.replace('const ID = "device-info";', f'const ID = "{plugin_id}";')
            content = content.replace('context.use("host-info.reader")', f'context.use("{plugin_id}.reader")')
            output.write_text(content, encoding="utf-8")
            output.chmod(0o755 if (example / relative).stat().st_mode & 0o111 else 0o644)
        shutil.copyfile(ROOT / "LICENSE", target / "LICENSE")
        validate(target)

    create_directory(destination, populate)
    return {"id": plugin_id, "kind": kind, "source": str(destination),
            **({"services": manifest["services"], "commands": manifest["commands"]} if kind == "service"
               else {"actions": manifest["actions"]})}


def package_hook(plugin_id, phase):
    return f'''#!/bin/sh
[ -n "$${{IPKG_INSTROOT}}" ] && exit 0
[ "$$1" != upgrade ] || export PKG_UPGRADE=1
exec /usr/libexec/opl-netfleet-plugin-package {plugin_id} {phase}
'''


def makefile(manifest, license_id, release):
    if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.+-]*", license_id) is None:
        raise ValueError("--license must be one SPDX license identifier")
    if release < 1:
        raise ValueError("--release must be positive")
    plugin_id, package = manifest["id"], manifest["package"]
    requirements = ["opl-netfleet-kernel"]
    if manifest["schema"] == "opl-netfleet-service-plugin.v1":
        requirements.extend(manifest.get("package_dependencies", []))
    else:
        requirements.extend(["netfleet-plugin-api-v1", *manifest["dependencies"]])
    dependencies = " ".join("+" + name for name in dict.fromkeys(requirements))
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
{package_hook(plugin_id, "preinst")}endef

define Package/{package}/prerm
{package_hook(plugin_id, "prerm")}endef

define Package/{package}/postinst
{package_hook(plugin_id, "postinst")}endef

define Package/{package}/postrm
{package_hook(plugin_id, "postrm")}endef

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
    create.add_argument("--kind", choices=("process", "service"), default="process")
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
            result = scaffold(args.id, args.destination, args.label, args.kind)
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
