#!/usr/bin/env python3
"""Synchronize checked-in plugin sources into the OpenWrt payload projection."""
import argparse
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "plugins"
TARGET = ROOT / "openwrt/files/usr/libexec/opl-netfleet/plugins"

def ids(path):
    return {p.name for p in path.iterdir() if p.is_dir() and not p.is_symlink()}

def check():
    # Process plugins are packaged separately; the OpenWrt service projection
    # contains only service plugins.
    service_ids = ids(SOURCE) - {"device-identity"}
    if service_ids != ids(TARGET):
        raise SystemExit("plugin source and payload sets differ")
    for identity in sorted(service_ids):
        left, right = SOURCE / identity, TARGET / identity
        for path in sorted(left.rglob("*")):
            if path.is_file():
                other = right / path.relative_to(left)
                if not other.is_file() or path.read_bytes() != other.read_bytes():
                    raise SystemExit(f"plugin source and payload differ: {identity}/{path.relative_to(left)}")
        for path in sorted(right.rglob("*")):
            if path.is_file() and not (left / path.relative_to(right)).is_file():
                raise SystemExit(f"plugin payload has unmanaged file: {identity}/{path.relative_to(right)}")

def sync():
    TARGET.mkdir(parents=True, exist_ok=True)
    for identity in sorted(ids(SOURCE) - {"device-identity"}):
        destination = TARGET / identity
        if destination.exists(): shutil.rmtree(destination)
        shutil.copytree(SOURCE / identity, destination)
    check()

parser = argparse.ArgumentParser()
parser.add_argument("command", choices=("check", "sync"))
args = parser.parse_args()
(sync if args.command == "sync" else check)()
