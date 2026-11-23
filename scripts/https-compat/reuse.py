#!/usr/bin/env python3
"""Retrieve unchanged optional packages with their original signed identities."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
from base import ROOT, sha


def prepare(source, output, apk):
    lock = json.loads(source.read_text())
    engine, identity = lock['engine'], lock['identity']
    for row, paths in ((engine, ['openwrt/https-compat/Makefile', 'openwrt/https-compat/src',
                               'openwrt/https-compat/patches', 'openwrt/https-compat/files/etc',
                               'openwrt/https-compat/files/usr/libexec/opl-netfleet-compat/extension.json',
                               'openwrt/https-compat/files/usr/libexec/opl-netfleet-compat/*.uc',
                               'openwrt/native/atomic-replace.c']),
                       (identity, ['plugins/device-identity'])):
        tree = subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse',
                                       row['source_commit'] + '^{tree}'], text=True).strip()
        if tree != row['source_tree']:
            raise ValueError('optional source tree mismatch')
        changed = subprocess.check_output(['git', '-C', str(ROOT), 'diff', '--name-only',
                                           row['source_commit'], 'HEAD', '--', *paths], text=True)
        if changed.strip():
            raise ValueError('optional source changed; build and pin a new signed package: ' + changed.strip())
    if output.exists() and any(output.iterdir()):
        raise ValueError('optional output must be empty')
    output.mkdir(parents=True, exist_ok=True)
    files = {**lock['files'], **{row['artifact']: row['sha256'] for row in (engine, identity)}}
    for name, digest in files.items():
        if Path(name).name != name:
            raise ValueError('invalid optional artifact filename')
        destination = output / name
        subprocess.run(['curl', '-q', '-fsSL', '--retry', '3', '--connect-timeout', '15', '--max-time', '180',
                        '--output', str(destination), lock['base_url'] + '/' + name], check=True)
        if sha(destination) != digest:
            raise ValueError('optional asset digest mismatch: ' + name)
    subprocess.run([str(apk), 'verify', '--keys-dir', str(output),
                    *[str(output / name) for name in files if not name.endswith('.pem')]], check=True)
    native = subprocess.check_output([sys.executable, str(ROOT / 'scripts/verify-native-runtime.py'),
                                     '--apk', str(apk), *[str(output / row['artifact']) for row in (engine, identity)]])
    (output / 'native-runtime.json').write_bytes(native)
    if sha(output / 'native-runtime.json') != engine['native_runtime']['sha256']:
        raise ValueError('optional native runtime evidence changed')
    for name, row in (('compat-manifest.json', engine), ('device-identity-manifest.json', identity)):
        (output / name).write_text(json.dumps(row, sort_keys=True) + '\n')
    return {'ok': True, 'artifacts': [row['artifact'] for row in (engine, identity)]}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=Path(__file__).with_name('release-source.json'))
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--apk', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(prepare(args.source, args.output, args.apk), sort_keys=True))
