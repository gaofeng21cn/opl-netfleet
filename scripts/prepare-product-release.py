#!/usr/bin/env python3
"""Align the product version without changing independent plugin versions."""
import json
from pathlib import Path
import re
import subprocess

root = Path(__file__).resolve().parents[1]
version = json.loads((root / 'product-version.json').read_text())['version']
assert re.fullmatch(r'(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)', version)
path = root / 'openwrt/Makefile'
text, count = re.subn(r'(?m)^PKG_VERSION:=.*$', 'PKG_VERSION:=' + version, path.read_text())
assert count == 1
path.write_text(text)
subprocess.run(['python3', 'scripts/sync-plugin-sources.py', 'sync'], cwd=root, check=True)
subprocess.run(['python3', 'scripts/plugin-catalog.py', 'write'], cwd=root, check=True)
