#!/usr/bin/env python3
"""Project the shipped service manifests into OpenWrt packages and bindings."""

import argparse
import json
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parent
PLUGIN_ROOT = ROOT / "files/usr/libexec/opl-netfleet/plugins"
ID = re.compile(r"[a-z][a-z0-9-]*")
VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")
PACKAGE = re.compile(r"[a-z0-9][a-z0-9+_.-]*")


def composition():
    plugins = {}
    services = {}
    for path in sorted(PLUGIN_ROOT.glob("*/manifest.json")):
        manifest = json.loads(path.read_text())
        identity = manifest.get("id")
        if (manifest.get("schema") != "opl-netfleet-service-plugin.v1"
                or not isinstance(identity, str) or not ID.fullmatch(identity)
                or identity != path.parent.name
                or manifest.get("package") != f"opl-netfleet-plugin-{identity}"
                or not VERSION.fullmatch(manifest.get("version", ""))):
            raise ValueError(f"invalid service package identity: {path}")
        plugins[identity] = manifest
        packages = manifest.get("package_dependencies", [])
        if not isinstance(packages, list) or any(not isinstance(name, str) or not PACKAGE.fullmatch(name) for name in packages):
            raise ValueError(f"invalid system package dependency: {identity}")
        for name, service in manifest["services"].items():
            if name in services:
                raise ValueError(f"default service has multiple providers: {name}")
            services[name] = (identity, service)
    if not plugins:
        raise ValueError("default composition has no service plugins")
    graph = {identity: set() for identity in plugins}
    for name, (identity, service) in services.items():
        for required, version in service.get("requires", {}).items():
            if required not in services or services[required][1]["version"] != version:
                raise ValueError(f"service dependency unavailable: {name} -> {required}@{version}")
            provider = services[required][0]
            if provider != identity:
                graph[identity].add(provider)
    visited = set()

    def visit(identity, active):
        if identity in active:
            raise ValueError(f"package dependency cycle: {' -> '.join((*active, identity))}")
        if identity in visited:
            return
        for required in sorted(graph[identity]):
            visit(required, (*active, identity))
        visited.add(identity)

    for identity in graph:
        visit(identity, ())
    return plugins, services, graph


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("ids", "dependencies", "version", "revision", "system"))
    parser.add_argument("plugin", nargs="?")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    plugins, services, graph = composition()
    if args.command == "ids":
        print(" ".join(plugins))
    elif args.command == "revision":
        from plugin_payload import payload_revision

        print(payload_revision(PLUGIN_ROOT / args.plugin))
    elif args.command in ("dependencies", "version"):
        manifest = plugins[args.plugin]
        if args.command == "version":
            print(manifest["version"])
            return
        dependencies = set(manifest.get("package_dependencies", []))
        if any(not isinstance(name, str) or not PACKAGE.fullmatch(name) for name in dependencies):
            raise ValueError(f"invalid system package dependency: {args.plugin}")
        dependencies.update(plugins[identity]["package"] for identity in graph[args.plugin])
        print(" ".join(f"+{name}" for name in sorted(dependencies)))
    else:
        if "scheduler.control" not in services:
            raise ValueError("default scheduler service is unavailable")
        data = json.dumps({
            "schema": "opl-netfleet-system.v1",
            "bindings": {name: services[name][0] for name in sorted(services)},
            "enabled": {identity: True for identity in plugins},
            "product_packages": ["opl-netfleet-kernel", *(plugins[identity]["package"] for identity in plugins)],
            "scheduler": {"service": "scheduler.control", "method": "tick"},
            "environment": {"service": "platform.runtime", "method": "environment"},
        }, indent=2, sort_keys=True) + "\n"
        if args.output:
            args.output.write_text(data)
        else:
            print(data, end="")


if __name__ == "__main__":
    main()
