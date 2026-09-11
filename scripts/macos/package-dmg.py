#!/usr/bin/env python3
"""Package a Developer ID signed, notarized app as a signed DMG candidate."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def package(app, output, signing_identity):
    if output.exists():
        raise RuntimeError('Output already exists; distribution artifacts are immutable')
    identity = json.loads((app / 'Contents/Resources/build.json').read_text())
    if identity.get('channel') != 'distribution' or identity.get('working_tree_dirty') is not False:
        raise RuntimeError('A clean distribution build is required')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if (info['CFBundleShortVersionString'], info['CFBundleVersion']) != (identity['package_version'], identity['package_release']):
        raise RuntimeError('Bundle version and source identity disagree')
    run('codesign', '--verify', '--deep', '--strict', app)
    details = subprocess.run(['codesign', '-dv', '--verbose=4', str(app)], capture_output=True, text=True, check=True).stderr
    if 'Authority=Developer ID Application:' not in details or 'runtime' not in details:
        raise RuntimeError('Developer ID and hardened runtime are required')
    run('xcrun', 'stapler', 'validate', app)
    run('spctl', '--assess', '--type', 'execute', '--verbose=2', app)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.netfleet-dmg-', dir=output.parent) as temp:
        root = Path(temp)
        content = root / 'content'
        content.mkdir()
        run('ditto', app, content / app.name)
        (content / 'Applications').symlink_to('/Applications')
        candidate = root / output.name
        run('hdiutil', 'create', '-volname', 'OPL NetFleet', '-srcfolder', content,
            '-format', 'UDZO', '-ov', candidate)
        run('codesign', '--sign', signing_identity, '--timestamp', candidate)
        run('codesign', '--verify', '--strict', candidate)
        run('hdiutil', 'verify', candidate)
        candidate.rename(output)
    receipt = {**identity, 'dmg': output.name, 'sha256': hashlib.sha256(output.read_bytes()).hexdigest(),
               'app_notarized': True, 'dmg_notarized': False, 'vm_qualified': False}
    output.with_suffix('.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--signing-identity', required=True)
    args = parser.parse_args()
    package(args.app.resolve(), args.output.resolve(), args.signing_identity)
