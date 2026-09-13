#!/usr/bin/env python3
"""Install an exact, qualified plugin set through the device components owner."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tarfile
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]


def run(args: list[str], **kwargs) -> bytes:
    return subprocess.check_output(args, **kwargs)


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def source(commit: str, path: str) -> bytes:
    return run(['git', '-C', str(ROOT), 'show', f'{commit}:{path}'])


def qualified(receipt: dict, commit: str, tree: str, manifest: bytes) -> None:
    checks = receipt.get('checks', {})
    required = ['boot', 'ssh', 'var_symlink', 'ubus', 'deploy_failure_rollback', 'post_failure_management']
    if (receipt.get('schema') not in ['opl-netfleet-openwrt-vm-qualification.v1', 'opl-netfleet-openwrt-vm-qualification.v2']
            or receipt.get('qualified') is not True or receipt.get('source_commit') != commit
            or receipt.get('source_tree') != tree or not isinstance(checks, dict)
            or not all(checks.get(key) is True for key in required)):
        raise ValueError('candidate lacks qualification for its exact source commit/tree')
    if receipt['schema'].endswith('.v2') and (receipt.get('package_qualified') is not True
            or receipt.get('package', {}).get('manifest_sha256') != sha(manifest)):
        raise ValueError('qualification does not bind this package manifest')


def package_selection(manifest: dict, names: list[str]) -> list[dict]:
    artifacts = {row['package']: row for row in manifest['artifacts']}
    if not names or len(set(names)) != len(names):
        raise ValueError('an explicit, non-duplicate plugin set is required')
    result = []
    for name in names:
        if (name != 'luci-app-netfleet' and not re.fullmatch(r'opl-netfleet-plugin-[a-z][a-z0-9-]*', name)) or name not in artifacts:
            raise ValueError(f'not a product plugin artifact: {name}')
        result.append(artifacts[name])
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('target', help='exact SSH target authorized for this update')
    parser.add_argument('--ref', default='origin/main')
    parser.add_argument('--packages', required=True, type=Path)
    parser.add_argument('--rollback-dir', required=True, type=Path)
    parser.add_argument('--qualification', required=True, type=Path)
    parser.add_argument('--plugin', action='append', required=True, help='exact package name; repeat for each plugin')
    parser.add_argument('--output', required=True, type=Path, help='private local receipt, outside Git')
    parser.add_argument('--observe-seconds', type=int, default=120)
    parser.add_argument('--ssh-option', action='append', default=[], help='SSH -o option, e.g. ControlPath=...')
    parser.add_argument('--dry-run', action='store_true', help='verify source, packages and qualification without contacting target')
    args = parser.parse_args()
    os.umask(0o077)
    if args.target.startswith('-') or not 10 <= args.observe_seconds <= 1800:
        parser.error('invalid target or observation duration (10..1800 seconds)')
    commit = run(['git', '-C', str(ROOT), 'rev-parse', f'{args.ref}^{{commit}}'], text=True).strip()
    tree = run(['git', '-C', str(ROOT), 'rev-parse', f'{commit}^{{tree}}'], text=True).strip()
    manifest_bytes = (args.packages / 'manifest.json').read_bytes()
    manifest = json.loads(manifest_bytes)
    # Reuse the release owner for complete artifact-set and source validation.
    spec = importlib.util.spec_from_file_location('release_verifier', ROOT / 'scripts/verify-netfleet-release.py')
    verifier = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(verifier)
    verifier.verify(args.packages, commit, tree)
    qualified(json.loads(args.qualification.read_bytes()), commit, tree, manifest_bytes)
    if manifest['package_format'] != 'apk':
        raise ValueError('the components transaction requires APK')
    selected = package_selection(manifest, args.plugin)
    for parent in (ROOT, Path(run(['git', '-C', str(ROOT), 'rev-parse', '--path-format=absolute', '--git-common-dir'], text=True).strip()).parent):
        if args.output.resolve().is_relative_to(parent):
            raise ValueError('operation receipts must remain outside the repository')
    plan = {'source_commit': commit, 'source_tree': tree, 'packages': args.plugin,
            'observation_seconds': args.observe_seconds}
    if args.dry_run:
        print(json.dumps({'ok': True, 'dry_run': True, **plan}))
        return
    ssh = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15']
    for option in args.ssh_option:
        ssh += ['-o', option]
    ssh += [args.target]
    # This read is advisory. The transaction checks each version again under
    # its mutation lock before invoking any lifecycle hooks.
    installed = {row['name']: row['version'] for row in json.loads(run(ssh + [
        "apk --no-network query --from installed --format json --fields name,version 'opl-netfleet*' 'luci-app-netfleet'"
    ]))}
    files: dict[str, bytes] = {}
    packages = []
    for item in selected:
        name = item['package']
        version = verifier.artifact_version(item)
        before = installed.get(name)
        if before is None:
            raise ValueError(f'plugin is not installed: {name}')
        old_name = f'{name}-{before}.apk'
        old = (args.rollback_dir / old_name).read_bytes()
        new = (args.packages / item['name']).read_bytes()
        files[f'old/{old_name}'] = old
        files[f'new/{name}-{version}.apk'] = new
        packages.append({'name': name, 'version': version, 'before_version': before,
                         'sha256': sha(new), 'before_sha256': sha(old)})
    files['request.json'] = json.dumps({'schema': 'opl-netfleet-plugin-install.v1', 'packages': packages}).encode()
    for name in ['manifest.json', 'lib/control.uc']:
        files[f'components/{name}'] = source(commit, f'openwrt/files/usr/libexec/opl-netfleet/plugins/components/{name}')
    files['run.sh'] = source(commit, 'scripts/update-openwrt-plugins-remote.sh')
    files['observe.uc'] = source(commit, 'scripts/observe-openwrt.uc')
    files['SHA256SUMS'] = ''.join(f'{sha(data)}  {name}\n' for name, data in files.items()).encode()
    stage = f'/tmp/opl-netfleet-install-{uuid.uuid4().hex}'
    args.output.parent.mkdir(parents=True, exist_ok=True)
    # Retain the precise target-local reconcile path before any external writes.
    args.output.write_text(json.dumps({**plan, 'stage': stage, 'state': 'prepared'}, indent=2) + '\n')
    with tempfile.TemporaryFile() as archive:
        with tarfile.open(fileobj=archive, mode='w') as tar:
            directories = sorted({str(Path(name).parent) for name in files if str(Path(name).parent) != '.'} | {'old', 'new', 'components'})
            for directory in directories:
                info = tarfile.TarInfo(directory); info.type = tarfile.DIRTYPE; info.mode = 0o700
                tar.addfile(info)
            for name, data in files.items():
                info = tarfile.TarInfo(name); info.size = len(data); info.mode = 0o600
                tar.addfile(info, io.BytesIO(data))
        archive.seek(0)
        subprocess.run(ssh + [f'umask 077; mkdir {shlex.quote(stage)} && tar -xf - -C {shlex.quote(stage)}'], stdin=archive, check=True)
    # No automatic rerun: even an SSH error may mean the durable worker started.
    command = shlex.join(['sh', f'{stage}/run.sh', stage, str(args.observe_seconds)])
    result = subprocess.run(ssh + [command], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    lines = result.stdout.decode(errors='replace').splitlines()
    values = []
    for line in lines:
        try: values.append(json.loads(line))
        except ValueError: pass
    receipt = {**plan, 'stage': stage, 'exit_code': result.returncode,
               'state': 'accepted' if result.returncode == 0 else 'needs_reconcile', 'results': values}
    args.output.write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt))
    if result.returncode:
        raise SystemExit('update or acceptance did not complete; read the retained transaction before retrying')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error)) from error
