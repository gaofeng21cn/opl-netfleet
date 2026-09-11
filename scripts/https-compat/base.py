#!/usr/bin/env python3
"""Validate an unchanged, qualified OpenWrt base for HTTPS-only qualification."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
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
             'usr/libexec/opl-netfleet-plugin-package', 'etc/init.d/opl-netfleet-core']
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


def validate(packages, receipt, commit, repo=ROOT):
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
    return {'source_commit': base_commit, 'source_tree': base_tree,
            'manifest_sha256': sha(packages / 'manifest.json'), 'qualification_sha256': sha(receipt),
            'runtime_sha256': runtime_files(packages)}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--packages', required=True, type=Path)
    parser.add_argument('--qualification', required=True, type=Path)
    parser.add_argument('--ref', required=True)
    args = parser.parse_args()
    print(json.dumps(validate(args.packages, args.qualification, args.ref)))
