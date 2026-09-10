#!/usr/bin/env python3
"""Inspect installed official package bytes, not build/test source or third-party plugins."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

RUNTIME = re.compile(r"(?:^|[/\s'\"])(?:python(?:[0-9.]+)?|pypy(?:[0-9.]+)?|node(?:js)?)(?=$|[/\s'\"])")
FORBIDDEN_DEP = re.compile(r"^(?:python[0-9]*(?:-|$)|pypy|node(?:-|$)|libpython)")


def inspect_payload(root):
    checked = 0
    for path in sorted(root.rglob('*')):
        if not path.is_file() and not path.is_symlink():
            continue
        relative = path.relative_to(root)
        if relative.parts[0] not in {'etc', 'usr', 'bin', 'sbin', 'lib'}:
            continue
        if path.suffix in {'.py', '.pyc', '.pyo'} or re.fullmatch(r'python[0-9.]*|pypy[0-9.]*|node', path.name):
            raise ValueError(f'non-native installed runtime: {relative}')
        if path.is_symlink():
            if RUNTIME.search(str(path.readlink())):
                raise ValueError(f'non-native executable link: {relative}')
            continue
        data = path.read_bytes()
        if data.startswith(b'\x7fELF'):
            if b'libpython' in data:
                raise ValueError(f'Python-linked binary: {relative}')
        elif path.suffix == '.uc' or data.startswith(b'#!'):
            for line in data.decode('utf-8').splitlines():
                if line.lstrip().startswith(('#', '//')) and not line.startswith('#!'):
                    continue
                if RUNTIME.search(line):
                    raise ValueError(f'non-native runtime caller: {relative}')
        checked += 1
    return checked


def inspect_apk(apk, archive):
    def run(*args):
        return subprocess.run([str(apk), *map(str, args)], check=True, capture_output=True, text=True).stdout
    metadata = json.loads(run('adbdump', '--format', 'json', archive))
    name = metadata['info']['name']
    if name != 'opl-netfleet' and not name.startswith('opl-netfleet-') and name != 'luci-app-netfleet':
        raise ValueError('native official-package gate cannot redefine third-party Plugin API policy')
    depends = metadata['info'].get('depends', [])
    for dependency in depends:
        if FORBIDDEN_DEP.match(re.split(r'[<>=~]', dependency)[0]):
            raise ValueError(f'non-native package dependency: {dependency}')
    for script in metadata.get('scripts', {}).values():
        if any(RUNTIME.search(line) for line in script.splitlines() if not line.lstrip().startswith('#')):
            raise ValueError('package lifecycle invokes a non-native runtime')
    with tempfile.TemporaryDirectory(prefix='netfleet-native-payload-') as temporary:
        run('--allow-untrusted', 'extract', '--destination', temporary, archive)
        files = inspect_payload(Path(temporary))
    return {'package': name, 'artifact': archive.name, 'sha256': hashlib.sha256(archive.read_bytes()).hexdigest(), 'files_checked': files, 'dependencies': depends}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apk', type=Path, required=True)
    parser.add_argument('packages', type=Path, nargs='+')
    args = parser.parse_args()
    print(json.dumps({'ok': True, 'packages': [inspect_apk(args.apk, path) for path in args.packages]}))


if __name__ == '__main__':
    main()
