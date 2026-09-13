#!/usr/bin/env python3
"""Validate an unchanged, qualified OpenWrt base for HTTPS-only qualification."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
BASE_PATHS = ['openwrt/Makefile', 'openwrt/plugin_payload.py', 'openwrt/plugin-packages.py',
              'openwrt/files', 'openwrt/luci-app-netfleet', 'openwrt/mihomo-meta',
              'plugins/device-identity', 'openwrt/native']


def runtime_files(packages):
    """Pin the installed callers of HTTPS lifecycle and gateway admission."""
    root = 'usr/libexec/opl-netfleet/'
    prefixes = [root+p for p in ['kernel/', 'adapters/', 'plugins/mihomo/',
                'plugins/https-compat/', 'plugins/platform/', 'plugins/platform-storage/']]
    exact = [root+'main.uc', root+'plugins/models/lib/extensions.uc',
             'usr/libexec/opl-netfleet-plugin-package', 'etc/init.d/opl-netfleet-core', 'etc/init.d/opl-netfleet']
    result = {}
    for line in (Path(packages)/'FILES.sha256').read_text().splitlines():
        digest, path = line.split(None, 1)
        if path in exact or any(path.startswith(prefix) for prefix in prefixes):
            result['/'+path] = digest
    if not all('/'+path in result for path in exact) or not all(
            any(path.startswith('/'+prefix) for path in result) for prefix in prefixes):
        raise ValueError('qualified base caller inventory incomplete')
    return result


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def retained_runtime(directory, runtime):
    """Bind an explicit signed retained set; the guest verifies APK contents/signatures."""
    directory = Path(directory)
    manifest = json.loads((directory / 'retained-base.json').read_text())
    if manifest.get('schema') != 'opl-netfleet-retained-base.v1' or set(manifest) != {'schema', 'artifacts', 'keys'}:
        raise ValueError('invalid retained base schema')
    artifacts, keys = manifest.get('artifacts'), manifest.get('keys')
    if not isinstance(artifacts, list) or not 1 <= len(artifacts) <= 32 or not isinstance(keys, list) or not 1 <= len(keys) <= 8:
        raise ValueError('invalid retained base size')
    def file_identity(name, digest):
        if not isinstance(name, str) or not re.fullmatch(r'[a-zA-Z0-9_.-]+', name) or name in ['.', '..']:
            raise ValueError('invalid retained artifact path')
        path = directory / name
        if path.is_symlink() or not path.is_file() or sha(path) != digest:
            raise ValueError('retained artifact identity mismatch')
    names, files, projected = set(), {'retained-base.json'}, dict(runtime)
    for key in keys:
        file_identity(key['name'], key['sha256'])
        if not key['name'].endswith('.pem') or key['name'] in files or b'PRIVATE KEY' in (directory/key['name']).read_bytes():
            raise ValueError('retained key must be a unique public key')
        files.add(key['name'])
    for row in artifacts:
        name, version = row['package'], row['version']
        if not isinstance(name, str) or not re.fullmatch(r'opl-netfleet-plugin-[a-z][a-z0-9-]*', name) or name in names:
            raise ValueError('invalid retained plugin')
        plugin = name.removeprefix('opl-netfleet-plugin-')
        if plugin in ['mihomo', 'https-compat', 'device-identity']:
            raise ValueError('retained set cannot replace the gateway or HTTPS dependency under qualification')
        if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+-r[0-9]+', version) or row['artifact'] != f'{name}-{version}.apk':
            raise ValueError('invalid retained version')
        file_identity(row['artifact'], row['sha256'])
        prefix = '/usr/libexec/opl-netfleet/plugins/' + plugin + '/'
        inventory = row.get('files')
        if not isinstance(inventory, dict) or not 1 <= len(inventory) <= 512 or prefix+'manifest.json' not in inventory:
            raise ValueError('retained runtime inventory missing')
        for path, digest in inventory.items():
            shared = plugin == 'scheduler' and path == '/etc/init.d/opl-netfleet' and runtime.get(path) == digest
            local = path.startswith(prefix) and not any(part in ['.', '..', ''] for part in path[len(prefix):].split('/'))
            if not (local or shared) or not re.fullmatch(r'[0-9a-f]{64}', digest):
                raise ValueError('retained runtime escapes plugin owner')
        original = {path for path in projected if path.startswith(prefix)}
        if not original.issubset(inventory):
            raise ValueError('retained plugin removes a qualified caller')
        for path in original:
            del projected[path]
        projected.update(inventory)
        names.add(name); files.add(row['artifact'])
    if {path.name for path in directory.iterdir()} != files:
        raise ValueError('unexpected retained artifact')
    return projected, {**manifest, 'manifest_sha256': sha(directory/'retained-base.json')}


def validate(packages, receipt, commit, repo=ROOT, retained=None):
    packages, receipt = Path(packages), Path(receipt)
    manifest = json.loads((packages / 'manifest.json').read_text())
    proof = json.loads(receipt.read_text())
    base_commit, base_tree = manifest['source_commit'], manifest['source_tree']
    spec = importlib.util.spec_from_file_location('netfleet_release', repo / 'scripts/verify-netfleet-release.py')
    verifier = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(verifier)
    verifier.verify(packages, base_commit, base_tree)
    required = ['boot', 'ssh', 'var_symlink', 'ubus', 'deploy_failure_rollback', 'post_failure_management']
    if (proof.get('schema') != 'opl-netfleet-openwrt-vm-qualification.v2'
            or proof.get('qualified') is not True or proof.get('package_qualified') is not True
            or proof.get('source_commit') != base_commit or proof.get('source_tree') != base_tree
            or proof.get('package', {}).get('manifest_sha256') != sha(packages / 'manifest.json')
            or not all(proof.get('checks', {}).get(key) is True for key in required)):
        raise ValueError('base package qualification is missing or mismatched')
    actual_tree = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', f'{base_commit}^{{tree}}'], text=True).strip()
    if actual_tree != base_tree:
        raise ValueError('base Git tree mismatch')
    changed = subprocess.check_output(['git', '-C', str(repo), 'diff', '--name-only', base_commit, commit, '--', *BASE_PATHS], text=True)
    if changed.strip():
        raise ValueError('base runtime changed; full qualification required: ' + changed.strip())
    result = {'source_commit': base_commit, 'source_tree': base_tree,
            'manifest_sha256': sha(packages / 'manifest.json'), 'qualification_sha256': sha(receipt),
            'runtime_sha256': runtime_files(packages)}
    if retained is not None:
        result['runtime_sha256'], result['retained'] = retained_runtime(retained, result['runtime_sha256'])
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--packages', required=True, type=Path)
    parser.add_argument('--qualification', required=True, type=Path)
    parser.add_argument('--ref', required=True)
    parser.add_argument('--retained-base', type=Path)
    args = parser.parse_args()
    print(json.dumps(validate(args.packages, args.qualification, args.ref, retained=args.retained_base)))
