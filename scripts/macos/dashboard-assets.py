#!/usr/bin/env python3
"""Materialize the pinned Zashboard panel for a macOS build or local run.

The device platform installs the same upstream asset through its own dashboard
plugin and keeps managing updates there. The desktop application must keep
working without the network and without a package manager, so the panel is
locked, verified and bundled at build time instead of downloaded at runtime.
"""
import argparse
import fcntl
import hashlib
import json
import shutil
import tempfile
import zipfile
from pathlib import Path

from bootstrap import HERE, download

REPO = HERE.parents[1]
LOCK = HERE / 'dashboard.json'
MAX_ENTRIES = 2048
MAX_EXTRACTED = 134217728


def entries(archive):
    """Return the validated `dist/` payload of a pinned panel archive."""
    with zipfile.ZipFile(archive) as opened:
        rows = opened.infolist()
        if not rows or len(rows) > MAX_ENTRIES:
            raise RuntimeError('Dashboard archive entry count is out of bounds')
        total = 0
        for row in rows:
            name = row.filename
            parts = name.split('/')
            if len(name) > 240 or not name.startswith('dist/') or '..' in parts or '.' in parts:
                raise RuntimeError(f'Dashboard archive entry is not a plain path: {name}')
            if row.is_dir():
                continue
            # Reject links and devices: the panel is served by a privileged core.
            if (row.external_attr >> 16) & 0o170000 not in (0, 0o100000):
                raise RuntimeError(f'Dashboard archive entry is not a regular file: {name}')
            total += row.file_size
        if not 0 < total <= MAX_EXTRACTED:
            raise RuntimeError('Dashboard archive size is out of bounds')
        if not opened.read('dist/index.html'):
            raise RuntimeError('Dashboard archive has an empty index.html')
        return rows


def prepare_dashboard(output, cache, licenses):
    lock = json.loads(LOCK.read_text())
    if lock['schema'] != 'opl-netfleet-macos-dashboard.v1':
        raise RuntimeError('Unknown dashboard lock')
    cache.mkdir(parents=True, exist_ok=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    with (cache / 'assets.lock').open('a') as lease:
        fcntl.flock(lease, fcntl.LOCK_EX)
        archive = download(lock, cache)
        if archive.stat().st_size != lock['size_bytes']:
            raise RuntimeError('Dashboard archive size mismatch')
        with tempfile.TemporaryDirectory(prefix='.dashboard-', dir=output.parent) as temporary:
            staged = Path(temporary) / 'dashboard'
            staged.mkdir()
            rows = entries(archive)
            with zipfile.ZipFile(archive) as opened:
                for row in rows:
                    if row.is_dir():
                        continue
                    target = staged / row.filename[len('dist/'):]
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(opened.read(row))
            index = staged / 'index.html'
            meta = {'schema': 'opl-netfleet-macos-dashboard-build.v1', 'version': lock['version'],
                    'asset': lock['asset'], 'sha256': lock['sha256'],
                    'index_sha256': hashlib.sha256(index.read_bytes()).hexdigest()}
            (Path(temporary) / 'dashboard-meta.json').write_text(json.dumps(meta, indent=2) + '\n')
            if output.exists():
                shutil.rmtree(output)
            staged.rename(output)
            shutil.copy2(Path(temporary) / 'dashboard-meta.json', output.parent / 'dashboard-meta.json')
    licenses.mkdir(parents=True, exist_ok=True)
    shutil.copy2(download(lock['license'], cache), licenses / 'zashboard-LICENSE')
    return output


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=REPO / '.build/macos/dashboard')
    parser.add_argument('--cache', type=Path, default=Path.home() / '.cache/opl-netfleet/macos/dashboard')
    parser.add_argument('--licenses', type=Path, default=REPO / '.build/macos/licenses')
    args = parser.parse_args()
    print(prepare_dashboard(args.output.resolve(), args.cache.resolve(), args.licenses.resolve()))
