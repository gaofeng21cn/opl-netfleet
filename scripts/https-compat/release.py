#!/usr/bin/env python3
"""Assemble the public optional feed from qualified signed artifacts, never receipts."""
import argparse
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

from base import ROOT, runtime_files, sha
from qualify import artifact, composition_evidence, COMPOSITION_QUALIFICATION


def prepare(packages, base_qualification, candidate, qualification, apk, output):
    spec = importlib.util.spec_from_file_location('release_verifier', ROOT / 'scripts/verify-netfleet-release.py')
    verifier = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(verifier)
    manifest = json.loads((packages / 'manifest.json').read_text())
    verifier.verify(packages, manifest['source_commit'], manifest['source_tree'])
    base_proof = json.loads(base_qualification.read_text())
    base_sha = sha(packages / 'manifest.json')
    if not (base_proof.get('schema') == 'opl-netfleet-openwrt-vm-qualification.v2'
            and base_proof.get('qualified') is True and base_proof.get('package_qualified') is True
            and base_proof.get('source_commit') == manifest['source_commit']
            and base_proof.get('source_tree') == manifest['source_tree']
            and base_proof.get('package', {}).get('manifest_sha256') == base_sha):
        raise ValueError('base qualification does not bind the release')
    engine = artifact(candidate, 'compat-manifest.json')
    identity = artifact(candidate, 'device-identity-manifest.json')
    proof = json.loads(qualification.read_text())
    checks = proof.get('checks', {})
    if proof.get('schema') == COMPOSITION_QUALIFICATION:
        request = proof.get('composition', {})
        expected_base = {'source_commit': manifest['source_commit'], 'source_tree': manifest['source_tree'],
                         'manifest_sha256': base_sha, 'qualification_sha256': sha(base_qualification),
                         'runtime_sha256': runtime_files(packages)}
        expected_feed = {name: sha(candidate / name) for name in
                         ('compat-public-key.pem', 'compat-packages.adb', engine['artifact'], identity['artifact'])}
        if (proof.get('composition_qualified') is not True
                or proof.get('source_commit') != manifest['source_commit']
                or proof.get('source_tree') != manifest['source_tree']
                or request.get('base') != expected_base
                or request.get('engine') != engine or request.get('identity') != identity
                or request.get('feed_sha256') != expected_feed):
            raise ValueError('optional composition does not bind the exact base and signed feed')
        diagnostic = qualification.with_suffix('.diagnostic.json')
        if sha(diagnostic) != proof.get('diagnostic_sha256'):
            raise ValueError('optional composition diagnostic evidence changed')
        actual_checks = composition_evidence(request, json.loads(diagnostic.read_text()))
        if actual_checks != checks:
            raise ValueError('optional composition checks differ from the guest evidence')
    elif not (proof.get('schema') == 'opl-netfleet-https-plugin-qualification.v1'
            and proof.get('plugin_qualified') is True
            and proof.get('source_commit') == engine['source_commit']
            and proof.get('source_tree') == engine['source_tree']
            and proof.get('engine') == engine and proof.get('identity') == identity
            and checks and all(value is True for value in checks.values())
            and all(checks.get(name) is True for name in (
                'engine_package_cycle', 'uninstall_reinstall', 'dual_stack_probe_faults',
                'native_dependency_closure', 'user_disable'))):
        raise ValueError('optional qualification does not bind the signed packages and lifecycle')
    # Reuse exact optional APKs across unrelated UI/product releases only when
    # every installed HTTPS caller remains byte-identical to the qualified base.
    if (proof.get('schema') != COMPOSITION_QUALIFICATION
            and proof.get('base', {}).get('runtime_sha256') != runtime_files(packages)):
        raise ValueError('HTTPS base callers changed; qualify this composition before publication')
    if engine.get('architecture') != manifest['build_target_arch']:
        raise ValueError('optional engine architecture differs from the base release')
    runtime = engine.get('native_runtime', {})
    if runtime.get('name') != 'native-runtime.json' or runtime.get('sha256') != sha(candidate / 'native-runtime.json'):
        raise ValueError('optional native runtime identity mismatch')
    native = json.loads((candidate / 'native-runtime.json').read_text())
    expected = {(row['artifact'], row['sha256']) for row in (engine, identity)}
    if native.get('ok') is not True or {
            (row.get('artifact'), row.get('sha256')) for row in native.get('packages', [])} != expected:
        raise ValueError('optional native runtime receipt does not cover the APKs')

    names = ['compat-public-key.pem', 'compat-packages.adb', engine['artifact'], identity['artifact']]
    for name in names:
        path = candidate / name
        if path.is_symlink() or not path.is_file():
            raise ValueError('optional public asset must be a regular file')
    key = (candidate / 'compat-public-key.pem').read_bytes()
    if b'PRIVATE KEY' in key or not key.startswith(b'-----BEGIN PUBLIC KEY-----'):
        raise ValueError('optional feed requires a public key')
    with tempfile.TemporaryDirectory(prefix='netfleet-optional-signatures-') as directory:
        trusted = Path(directory)
        shutil.copyfile(candidate / names[0], trusted / names[0])
        subprocess.run([str(apk), 'verify', '--keys-dir', str(trusted),
                        *[str(candidate / name) for name in names[1:]]], check=True)
        # Regenerate an unsigned index locally from the verified APKs and compare
        # metadata: a signed but stale index must not select different APK bytes.
        rebuilt = trusted / 'expected.adb'
        subprocess.run([str(apk), 'mkndx', '--keys-dir', str(trusted), '--output', str(rebuilt),
                        str(candidate / engine['artifact']), str(candidate / identity['artifact'])], check=True)
        def index_rows(path):
            result = json.loads(subprocess.check_output(
                [str(apk), 'adbdump', '--format', 'json', str(path)], text=True))
            return sorted(result['packages'], key=lambda row: row['name'])
        indexed = index_rows(candidate / 'compat-packages.adb')
        if indexed != index_rows(rebuilt):
            raise ValueError('optional signed index does not bind the exact APK bytes')
        found = {f"{row['name']}-{row['version']}.apk" for row in indexed}
        if found != {engine['artifact'], identity['artifact']}:
            raise ValueError('optional signed index does not contain the exact package set')

    if output.exists() and any(output.iterdir()):
        raise ValueError('public output must be empty')
    output.mkdir(parents=True, exist_ok=True)
    for path in packages.iterdir():
        shutil.copyfile(path, output / path.name)
    for name in names:
        shutil.copyfile(candidate / name, output / name)
    # Only publication metadata enters the release. Private VM/device receipts,
    # runtime inventories and local paths are deliberately not copied.
    public = {
        'schema': 'opl-netfleet-optional-feed.v1',
        'base_manifest_sha256': base_sha,
        'architecture': engine['architecture'],
        'artifacts': [{key: row[key] for key in ('artifact', 'sha256', 'source_commit', 'source_tree')}
                      for row in (engine, identity)],
        'files': {name: sha(output / name) for name in names},
    }
    (output / 'optional-packages.json').write_text(json.dumps(public, sort_keys=True, indent=2) + '\n')
    return verifier.verify(output, manifest['source_commit'], manifest['source_tree'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('packages', 'base-qualification', 'candidate', 'qualification', 'apk', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    try:
        result = prepare(args.packages, args.base_qualification, args.candidate,
                         args.qualification, args.apk, args.output)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'optional-release: {error}\n')
    print(json.dumps(result, sort_keys=True))


if __name__ == '__main__':
    main()
