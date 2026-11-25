#!/usr/bin/env python3
"""Align the product version without changing independent plugin versions."""
import json
from pathlib import Path
import plistlib
import re
import subprocess

root = Path(__file__).resolve().parents[1]
version = json.loads((root / 'product-version.json').read_text())['version']
assert re.fullmatch(r'(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)', version)

makefile_path = root / 'openwrt/Makefile'
text, count = re.subn(r'(?m)^PKG_VERSION:=.*$', 'PKG_VERSION:=' + version, makefile_path.read_text())
assert count == 1
makefile_path.write_text(text)

plist_path = root / 'desktop/app/Info.plist'
plist_data = plistlib.loads(plist_path.read_bytes())
if plist_data.get('CFBundleShortVersionString') != version:
    plist_data['CFBundleShortVersionString'] = version
    current_build = int(str(plist_data.get('CFBundleVersion', '0')))
    plist_data['CFBundleVersion'] = str(current_build + 1)
    with plist_path.open('wb') as handle:
        plistlib.dump(plist_data, handle, sort_keys=False)

subprocess.run(['python3', 'scripts/plugin-catalog.py', 'write'], cwd=root, check=True)
