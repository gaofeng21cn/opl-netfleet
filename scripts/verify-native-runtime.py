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
UCODE_STRING = re.compile(r"'(?:\\.|[^'\\])*'|\"(?:\\.|[^\"\\])*\"|`(?:\\.|[^`\\])*`")


def runtime_caller(line, ucode=False):
    if line.lstrip().startswith(('#', '//')) and not line.startswith('#!'):
        return False
    # Identifiers such as `nodes.map(node => node.name)` are not executables.
    if ucode and not line.startswith('#!'):
        return any(RUNTIME.search(value[1:-1]) for value in UCODE_STRING.findall(line))
    return bool(RUNTIME.search(line))


def inspect_payload(root, compiled=None):
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
        bytecode = data.split(b'\n', 1)[1] if data.startswith(b'#!') and b'\n' in data else data
        if data.startswith(b'\x7fELF'):
            if b'libpython' in data:
                raise ValueError(f'Python-linked binary: {relative}')
        elif bytecode.startswith(b'\x1bucb'):
            if (compiled or {}).get(str(relative)) != hashlib.sha256(data).hexdigest():
                raise ValueError(f'unverified compiled runtime: {relative}')
        elif path.suffix == '.uc' or data.startswith(b'#!'):
            for line in data.decode('utf-8').splitlines():
                if runtime_caller(line, ucode=path.suffix == '.uc'):
                    raise ValueError(f'non-native runtime caller: {relative}')
        checked += 1
    return checked


def verified_bytecode(source_root, manifest):
    # Inspect the complete source payload, including static imports, then bind
    # each SDK output to the exact source and installed byte identities.
    inspect_payload(source_root)
    result = {}
    for entry in manifest:
        relative = Path('usr/libexec/opl-netfleet/plugins') / entry['plugin'] / entry['module']
        source = source_root / relative
        if not source.resolve().is_relative_to(source_root.resolve()) or source.is_symlink():
            raise ValueError('unsafe compiled source path')
        if hashlib.sha256(source.read_bytes()).hexdigest() != entry['source_sha256']:
            raise ValueError(f'compiled source mismatch: {relative}')
        result[str(relative)] = entry['compiled_sha256']
    return result


def inspect_apk(apk, archive, compiled=None):
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
        if any(runtime_caller(line) for line in script.splitlines()):
            raise ValueError('package lifecycle invokes a non-native runtime')
    with tempfile.TemporaryDirectory(prefix='netfleet-native-payload-') as temporary:
        run('--allow-untrusted', 'extract', '--destination', temporary, archive)
        files = inspect_payload(Path(temporary), compiled)
    return {'package': name, 'artifact': archive.name, 'sha256': hashlib.sha256(archive.read_bytes()).hexdigest(), 'files_checked': files, 'dependencies': depends}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apk', type=Path, required=True)
    parser.add_argument('--source-root', type=Path)
    parser.add_argument('--bytecode-manifest', type=Path)
    parser.add_argument('packages', type=Path, nargs='+')
    args = parser.parse_args()
    if bool(args.source_root) != bool(args.bytecode_manifest):
        parser.error('source root and bytecode manifest must be supplied together')
    compiled = verified_bytecode(args.source_root, json.loads(args.bytecode_manifest.read_text())) if args.source_root else None
    print(json.dumps({'ok': True, 'packages': [inspect_apk(args.apk, path, compiled) for path in args.packages]}))


if __name__ == '__main__':
    main()
