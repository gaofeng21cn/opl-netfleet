#!/usr/bin/env python3
"""Build a deterministic, reviewable catalog for checked-in service plugins."""
import argparse
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "plugins"

def catalog(root):
    rows = []
    for path in sorted(root.iterdir()):
        manifest_path = path / "manifest.json"
        if not path.is_dir() or not manifest_path.is_file():
            continue
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        if manifest.get("schema") != "opl-netfleet-service-plugin.v1":
            continue
        rows.append({
            "id": manifest["id"], "label": manifest["label"],
            "version": manifest["version"], "package": manifest["package"],
            "api_version": manifest["api_version"],
            "services": sorted(manifest.get("services", {})),
            "package_dependencies": sorted(manifest.get("package_dependencies", [])),
            "optional": manifest["id"] == "https-compat",
        })
    if not rows:
        raise ValueError("no service plugins found")
    return {"schema": "opl-netfleet-plugin-catalog.v1", "plugins": rows}

parser = argparse.ArgumentParser()
parser.add_argument("command", choices=("check", "write"))
parser.add_argument("--output", type=Path, default=ROOT / "docs/development/plugin-catalog.json")
args = parser.parse_args()
value = json.dumps(catalog(SOURCE), ensure_ascii=False, indent=2, sort_keys=True) + "\n"
if args.command == "check":
    if not args.output.is_file() or args.output.read_text(encoding="utf-8") != value:
        raise SystemExit("plugin catalog is stale; run plugin-catalog.py write")
else:
    args.output.write_text(value, encoding="utf-8")
