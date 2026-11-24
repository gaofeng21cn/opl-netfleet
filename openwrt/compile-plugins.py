#!/usr/bin/env python3
"""Compile official service factories in the SDK's disposable payload copy."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def compile_plugins(root: Path, compiler: Path, libraries: Path, only=None, exclude=None):
    # Native bindings resolve on the target. Host-only builds need not provide
    # ubus/uci/digest, while local static imports use the SDK's fs/socket modules.
    flags = '-c,dynlink=fs,dynlink=socket,dynlink=uci,dynlink=ubus,dynlink=digest'
    only_set = set(only) if only else None
    exclude_set = set(exclude) if exclude else set()
    rows = []
    available_ids = set()
    for manifest_path in sorted(root.glob('*/manifest.json')):
        manifest = json.loads(manifest_path.read_text())
        plugin_id = manifest['id']
        available_ids.add(plugin_id)
        if only_set is not None and plugin_id not in only_set:
            continue
        if plugin_id in exclude_set:
            continue
        directory = manifest_path.parent.resolve()
        for relative in sorted({service['module'] for service in manifest.get('services', {}).values()}):
            path = directory / relative
            if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(directory):
                raise ValueError(f'unsafe service module: {plugin_id}/{relative}')
            before = path.stat().st_size
            source_digest = hashlib.sha256(path.read_bytes()).hexdigest()
            temporary = path.with_suffix('.bytecode-tmp')
            try:
                # SDK compiler and target interpreter are qualified together.
                # Strip build paths; installed packages cannot depend on build sources.
                subprocess.run([str(compiler), '-L', str(libraries / '*.so'), flags, '-s',
                                '-o', str(temporary), relative], cwd=directory,
                               check=True, timeout=30)
                if not temporary.is_file() or not 0 < temporary.stat().st_size <= 1048576:
                    raise ValueError(f'compiled module exceeds payload limit: {relative}')
                temporary.chmod(path.stat().st_mode & 0o777)
                temporary.replace(path)
                rows.append({'plugin': plugin_id, 'module': relative,
                             'source_bytes': before, 'compiled_bytes': path.stat().st_size,
                             'source_sha256': source_digest,
                             'compiled_sha256': hashlib.sha256(path.read_bytes()).hexdigest()})
            finally:
                temporary.unlink(missing_ok=True)
    if only_set is not None:
        unknown = sorted(only_set - available_ids)
        if unknown:
            raise ValueError(f'unknown plugin id(s) for --only: {", ".join(unknown)}')
    return rows


def _parse_id_list(raw):
    if not raw:
        return None
    items = [item.strip() for item in raw.split(',') if item.strip()]
    return items or None


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', required=True, type=Path)
    parser.add_argument('--compiler', required=True, type=Path)
    parser.add_argument('--libraries', required=True, type=Path)
    parser.add_argument('--only', default='', help='Comma-separated plugin IDs to compile')
    parser.add_argument('--exclude', default='', help='Comma-separated plugin IDs to skip')
    args = parser.parse_args()
    print(json.dumps(compile_plugins(
        args.root,
        args.compiler.resolve(),
        args.libraries.resolve(),
        only=_parse_id_list(args.only),
        exclude=_parse_id_list(args.exclude),
    )))
