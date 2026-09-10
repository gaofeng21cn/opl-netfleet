#!/usr/bin/env python3
"""Materialize the shared, locked policy resources for a macOS build or local run."""
import argparse
import fcntl
import json
from pathlib import Path
import shutil
import tempfile
from bootstrap import HERE, download

REPO = HERE.parents[1]


def prepare_builtin(output, cache):
    source = REPO / 'openwrt/files/etc/opl-netfleet'
    lock = json.loads((source / 'rulesets.lock.json').read_text())
    if lock['schema'] != 'opl-netfleet-ruleset-lock.v1':
        raise RuntimeError('Unknown ruleset lock')
    cache.mkdir(parents=True, exist_ok=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    with (cache / 'assets.lock').open('a') as lease:
        fcntl.flock(lease, fcntl.LOCK_EX)
        with tempfile.TemporaryDirectory(prefix='.builtin-', dir=output.parent) as temporary:
            staged = Path(temporary)
            shutil.copytree(source / 'policy-sources', staged / 'policy-sources')
            shutil.copy2(source / 'rulesets.lock.json', staged / 'rulesets.lock.json')
            (staged / 'rulesets').mkdir()
            for rule in lock['rulesets']:
                asset = download({**rule, 'filename': rule['sha256'] + '.mrs'}, cache)
                if asset.stat().st_size != rule['size_bytes']:
                    raise RuntimeError(f"Ruleset size mismatch: {rule['id']}")
                shutil.copy2(asset, staged / 'rulesets' / (rule['id'] + '.mrs'))
            # No caller uses the development output while its build is in progress.
            shutil.copytree(staged, output, dirs_exist_ok=True)
    return output


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=REPO / '.build/macos/builtin')
    parser.add_argument('--cache', type=Path, default=Path.home() / '.cache/opl-netfleet/macos/rulesets')
    args = parser.parse_args()
    print(prepare_builtin(args.output.resolve(), args.cache.resolve()))
