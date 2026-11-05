#!/usr/bin/env python3
"""Project a signed APK repository into the package map consumed by owut/ASU."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import subprocess


def metadata(index: dict, architecture: str) -> dict:
    if not re.fullmatch(r'[a-z0-9_+-]+', architecture):
        raise ValueError('invalid feed architecture')
    packages = {}
    for row in index['packages']:
        name, version = row['name'], row['version']
        if (not re.fullmatch(r'[a-z0-9][a-z0-9+_.-]*', name)
                or not isinstance(version, str) or not version
                or row.get('arch') not in (architecture, 'noarch')
                or name in packages):
            raise ValueError('ambiguous or incompatible feed package identity')
        packages[name] = version
    if not packages:
        raise ValueError('empty feed')
    return {'version': 2, 'architecture': architecture, 'packages': dict(sorted(packages.items()))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apk', required=True)
    parser.add_argument('--index', type=Path, required=True)
    parser.add_argument('--architecture', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    index = json.loads(subprocess.check_output(
        [args.apk, 'adbdump', '--format', 'json', str(args.index)], text=True))
    result = metadata(index, args.architecture)
    temporary = args.output.with_suffix(args.output.suffix + '.tmp')
    temporary.write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    temporary.replace(args.output)


if __name__ == '__main__':
    main()
