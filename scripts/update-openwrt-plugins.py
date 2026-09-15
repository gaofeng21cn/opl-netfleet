#!/usr/bin/env python3
"""Update a plugin from its signed Feed through the installed components owner."""
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
import time
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


def changed_selection(selected: list[dict], installed: dict, version) -> tuple[list[dict], list[str]]:
    changed, unchanged = [], []
    for item in selected:
        name = item['package']
        if name not in installed:
            raise ValueError(f'plugin is not installed: {name}')
        if installed[name] == version(item):
            unchanged.append(name)
        else:
            changed.append(item)
    return changed, unchanged


def feed_update(args, ssh: list[str]) -> dict:
    """Consume the installed components owner; APK owns archive and dependency selection."""
    started = time.monotonic()
    timings = {}
    snapshot = json.loads(run(ssh + ['ucode /usr/libexec/opl-netfleet/main.uc components-get']))
    timings['version_read_ms'] = round((time.monotonic() - started) * 1000)
    if snapshot.get('ok') is not True:
        raise ValueError('cannot read installed components owner')
    rows = {row['name']: row for row in snapshot['result']['plugin_packages']}
    if len(args.plugin) != 1 or args.plugin[0] not in rows:
        raise ValueError('select one installed plugin or declared runtime package from components-get')
    row = rows[args.plugin[0]]
    if not row.get('installed_version'):
        raise ValueError('plugin is not installed')
    if not row.get('available_version'):
        raise ValueError('check the signed Feed from components before updating')
    base = {'target': args.target, 'packages': [row['name']]}
    if row['installed_version'] == row['available_version']:
        return {**base, 'state': 'no_change', 'device_mutation': False,
                'timings': {**timings, 'total_ms': round((time.monotonic() - started) * 1000)}}
    request = {'name': row['name'], 'action': 'update', 'version': row['available_version'],
               'before_version': row['installed_version'], 'confirm': False}
    stage_started = time.monotonic()
    preview = json.loads(run(ssh + ['/usr/libexec/rpcd/opl-netfleet call components_plugin_plan'],
                             input=json.dumps({'request': request}).encode()))
    timings['plan_ms'] = round((time.monotonic() - stage_started) * 1000)
    if preview.get('ok') is not True:
        raise ValueError(preview.get('error', 'plugin plan unavailable'))
    request.update(confirm=True, plan=preview['result'])
    if args.dry_run:
        return {**base, 'state': 'preview', 'device_mutation': False, 'plan': preview['result'],
                'timings': {**timings, 'total_ms': round((time.monotonic() - started) * 1000)}}
    stage_started = time.monotonic()
    files = {'run.sh': (ROOT / 'scripts/update-openwrt-plugins-remote.sh').read_bytes(),
             'observe.uc': (ROOT / 'scripts/observe-openwrt.uc').read_bytes(),
             'feed-request.json': json.dumps({'request': request}).encode()}
    # The device normally retains/fetches old signed archives itself. An operator
    # may supply the exact previous archives when their Feed has advanced.
    if args.rollback_dir:
        versions = {item['name']: item.get('installed_version') for item in rows.values()}
        for name in preview['result']['names']:
            before = versions.get(name)
            if not before:
                continue
            archive = args.rollback_dir / f'{name}-{before}.apk'
            if archive.exists():
                files[f'old/{archive.name}'] = archive.read_bytes()
    files['SHA256SUMS'] = ''.join(f'{sha(data)}  {name}\n' for name, data in files.items()).encode()
    stage = f'/tmp/opl-netfleet-install-{uuid.uuid4().hex}'
    receipt = {**base, 'stage': stage, 'state': 'prepared', 'plan': preview['result']}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(receipt, indent=2) + '\n')
    timings['prepare_ms'] = round((time.monotonic() - stage_started) * 1000)
    stage_started = time.monotonic()
    with tempfile.TemporaryFile() as archive:
        with tarfile.open(fileobj=archive, mode='w') as tar:
            info = tarfile.TarInfo('old'); info.type = tarfile.DIRTYPE; info.mode = 0o700
            tar.addfile(info)
            for name, data in files.items():
                info = tarfile.TarInfo(name); info.size = len(data); info.mode = 0o600
                tar.addfile(info, io.BytesIO(data))
        archive.seek(0)
        subprocess.run(ssh + [f'umask 077; mkdir {shlex.quote(stage)} && tar -xf - -C {shlex.quote(stage)}'], stdin=archive, check=True)
    timings['transfer_ms'] = round((time.monotonic() - stage_started) * 1000)
    stage_started = time.monotonic()
    # Never resubmit after an ambiguous dispatch. The request and start.json are
    # retained remotely; the journal survives client/browser disconnection.
    result = subprocess.run(ssh + [shlex.join(['sh', f'{stage}/run.sh', stage, str(args.observe_seconds)])],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    timings['transaction_and_observe_ms'] = round((time.monotonic() - stage_started) * 1000)
    values = []
    for line in result.stdout.decode(errors='replace').splitlines():
        try: values.append(json.loads(line))
        except ValueError: pass
    return {**receipt, 'state': 'accepted' if result.returncode == 0 else 'needs_reconcile',
            'exit_code': result.returncode, 'results': values,
            'timings': {**timings, 'total_ms': round((time.monotonic() - started) * 1000)}}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('target', help='exact SSH target authorized for this update')
    parser.add_argument('--ref', default='origin/main')
    parser.add_argument('--packages', type=Path, help='qualified local archives for default-product bootstrap only; omit for normal Feed updates')
    parser.add_argument('--rollback-dir', type=Path)
    parser.add_argument('--qualification', type=Path)
    parser.add_argument('--plugin', action='append', required=True, help='one plugin/runtime package; repeat only for offline bootstrap')
    parser.add_argument('--output', required=True, type=Path, help='private local receipt, outside Git')
    # Independent plugin updates need only a short health confirmation; the
    # durable target journal remains authoritative for slower transactions.
    parser.add_argument('--observe-seconds', type=int, default=10)
    parser.add_argument('--ssh-option', action='append', default=[], help='SSH -o option, e.g. ControlPath=...')
    parser.add_argument('--dry-run', action='store_true', help='Feed: preview target plan only; local bootstrap: verify inputs without contacting target')
    args = parser.parse_args()
    started = time.monotonic()
    timings = {}
    os.umask(0o077)
    if args.target.startswith('-') or not 10 <= args.observe_seconds <= 1800:
        parser.error('invalid target or observation duration (10..1800 seconds)')
    canonical = Path(run(['git', '-C', str(ROOT), 'rev-parse', '--path-format=absolute', '--git-common-dir'], text=True).strip()).parent
    if any(args.output.resolve().is_relative_to(root) for root in (ROOT, canonical)):
        raise ValueError('operation receipts must remain outside the repository')
    if args.packages is None:
        ssh = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15']
        for option in args.ssh_option:
            ssh += ['-o', option]
        ssh += [args.target]
        receipt = feed_update(args, ssh)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(receipt, indent=2) + '\n')
        print(json.dumps(receipt))
        if receipt['state'] == 'needs_reconcile':
            raise SystemExit('read the retained transaction before retrying')
        return
    if args.qualification is None or args.rollback_dir is None:
        parser.error('local bootstrap archives require --qualification and --rollback-dir')
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
    timings['validation_ms'] = round((time.monotonic() - started) * 1000)
    phase = time.monotonic()
    ssh = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15']
    for option in args.ssh_option:
        ssh += ['-o', option]
    ssh += [args.target]
    # This read is advisory. The transaction checks each version again under
    # its mutation lock before invoking any lifecycle hooks.
    installed = {row['name']: row['version'] for row in json.loads(run(ssh + [
        "apk --no-network query --from installed --format json --fields name,version 'opl-netfleet*' 'luci-app-netfleet'"
    ]))}
    timings['installed_read_ms'] = round((time.monotonic() - phase) * 1000)
    selected, unchanged = changed_selection(selected, installed, verifier.artifact_version)
    plan.update(packages=[row['package'] for row in selected], unchanged=unchanged)
    if not selected:
        receipt = {**plan, 'state': 'no_change', 'device_mutation': False,
                   'timings': {**timings, 'total_ms': round((time.monotonic() - started) * 1000)}}
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(receipt, indent=2) + '\n')
        print(json.dumps(receipt))
        return
    # Local archive installation is the default-product bootstrap route. Optional
    # plugins use the installed components-plugin Feed owner and its solver plan.
    components = json.loads(run(ssh + ['ucode /usr/libexec/opl-netfleet/main.uc components-get']))
    if components.get('ok') is not True:
        raise ValueError('cannot confirm target product package ownership')
    managed = {row['name'] for row in components['result']['product']['packages']}
    outside = [row['package'] for row in selected if row['package'] not in managed]
    if outside:
        raise ValueError('optional plugins require the components-plugin Feed update entry: ' + ', '.join(outside))
    phase = time.monotonic()
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
    for name in ['manifest.json', 'lib/control.uc', 'lib/packages.uc', 'recover.uc']:
        files[f'components/{name}'] = source(commit, f'openwrt/files/usr/libexec/opl-netfleet/plugins/components/{name}')
    files['run.sh'] = source(commit, 'scripts/update-openwrt-plugins-remote.sh')
    files['observe.uc'] = source(commit, 'scripts/observe-openwrt.uc')
    files['SHA256SUMS'] = ''.join(f'{sha(data)}  {name}\n' for name, data in files.items()).encode()
    stage = f'/tmp/opl-netfleet-install-{uuid.uuid4().hex}'
    args.output.parent.mkdir(parents=True, exist_ok=True)
    # Retain the precise target-local reconcile path before any external writes.
    args.output.write_text(json.dumps({**plan, 'stage': stage, 'state': 'prepared'}, indent=2) + '\n')
    timings['prepare_ms'] = round((time.monotonic() - phase) * 1000)
    phase = time.monotonic()
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
    timings['transfer_ms'] = round((time.monotonic() - phase) * 1000)
    phase = time.monotonic()
    # No automatic rerun: even an SSH error may mean the durable worker started.
    command = shlex.join(['sh', f'{stage}/run.sh', stage, str(args.observe_seconds)])
    result = subprocess.run(ssh + [command], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    lines = result.stdout.decode(errors='replace').splitlines()
    values = []
    for line in lines:
        try: values.append(json.loads(line))
        except ValueError: pass
    timings['transaction_and_observation_ms'] = round((time.monotonic() - phase) * 1000)
    timings['total_ms'] = round((time.monotonic() - started) * 1000)
    receipt = {**plan, 'stage': stage, 'timings': timings, 'exit_code': result.returncode,
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
