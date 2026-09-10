#!/usr/bin/env python3
"""Build the pinned shared-contract UCode runtime on Linux (no system writes)."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import sys
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def prepare(cache):
    if sys.version_info < (3, 12):
        raise RuntimeError('Python 3.12 or newer is required for safe archive extraction')
    if platform.system() != 'Linux':
        raise RuntimeError('Linux only; macOS uses scripts/macos/bootstrap.py')
    # One upstream source identity for both platforms; Darwin alone applies its patch.
    entry = json.loads((ROOT / 'scripts/macos/dependencies.json').read_text())['ucode']
    destination = cache / entry['version']
    runtime = destination / 'runtime'
    destination.mkdir(parents=True, exist_ok=True)
    if not (runtime / 'bin/ucode').exists():
        archive = destination / entry['filename']
        if not archive.exists():
            with urllib.request.urlopen(entry['url'], timeout=60) as response:
                archive.write_bytes(response.read())
        if hashlib.sha256(archive.read_bytes()).hexdigest() != entry['sha256']:
            raise RuntimeError('Pinned UCode archive checksum mismatch')
        with tarfile.open(archive) as bundle:
            bundle.extractall(destination, filter='data')
        source = destination / ('ucode-' + entry['version'])
        disabled = ('UBUS', 'UCI', 'ULOOP', 'RTNL', 'NL80211', 'FFI', 'DIGEST', 'SERIAL', 'ZLIB')
        commands = [
            ['cmake', '-S', str(source), '-B', str(destination / 'build'), '-DCMAKE_BUILD_TYPE=Release',
             f'-DCMAKE_INSTALL_PREFIX={runtime}', '-DCMAKE_INSTALL_LIBDIR=lib',
             '-DCMAKE_INSTALL_RPATH=$ORIGIN/../lib',
             *[f'-D{name}_SUPPORT=OFF' for name in disabled]],
            ['cmake', '--build', str(destination / 'build'), '--parallel', '2'],
            ['cmake', '--install', str(destination / 'build')],
        ]
        for command in commands:
            subprocess.run(command, check=True, stdout=sys.stderr)
    subprocess.run([str(runtime / 'bin/ucode'), '-L', str(runtime / 'lib/ucode/*.so'), '-e',
                    'import * as fs from "fs"; import * as socket from "socket"; assert(type(fs.open) == "function");'], check=True)
    return runtime


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache', type=Path, default=Path.home() / '.cache/opl-netfleet/ucode-linux')
    print(prepare(parser.parse_args().cache.resolve()))
