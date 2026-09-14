#!/usr/bin/env python3
"""Qualify an engine update or an exact optional-package composition on a qualified base."""
import argparse
import json
import re
from pathlib import Path
import shutil
import subprocess
import tempfile
from base import ROOT, sha, validate

COMPOSITION_SCHEMA = 'opl-netfleet-https-composition.v1'
COMPOSITION_QUALIFICATION = 'opl-netfleet-https-composition-qualification.v1'
COMPOSITION_CHECKS = (
    'full_feed_bootstrap', 'full_feed_install_inactive', 'full_feed_repeat_preserves_configuration',
    'uninstall_reinstall', 'dual_stack_probe_faults', 'native_dependency_closure', 'user_disable',
    'real_gateway_h2', 'simultaneous_stall_fail_open', 'base_pid_unchanged',
    'base_configuration_unchanged', 'streaming_upload_and_sse', 'resource_pressure',
    'kernel_tcp_reset_delivery',
)


def artifact(directory, name):
    value = json.loads((directory / name).read_text())
    file = value['artifact']
    package='opl-netfleet-https-compat' if name=='compat-manifest.json' else 'opl-netfleet-plugin-device-identity'
    if not re.fullmatch(re.escape(package)+r'-[0-9]+\.[0-9]+\.[0-9]+(-r[0-9]+)?\.apk',file) or sha(directory / file) != value['sha256']:
        raise ValueError('optional artifact identity mismatch')
    return value


def identity_matches_base(identity, base, repo=ROOT):
    commit = identity['source_commit']
    tree = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', commit+'^{tree}'], text=True).strip()
    if tree != identity['source_tree']:
        raise ValueError('identity source tree mismatch')
    changed = subprocess.check_output(['git', '-C', str(repo), 'diff', '--name-only',
        commit, base['source_commit'], '--', 'plugins/device-identity'], text=True)
    if changed.strip():
        raise ValueError('identity source differs from the fixed base')


def source_tree(commit, repo=ROOT):
    if not isinstance(commit, str) or not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise ValueError('invalid optional source commit')
    return subprocess.check_output(['git', '-C', str(repo), 'rev-parse', commit+'^{tree}'], text=True).strip()


def composition_request(packages, base_qualification, candidate, retained=None):
    """Keep each artifact's build identity; the test source belongs to the new base."""
    manifest = json.loads((packages / 'manifest.json').read_text())
    base = validate(packages, base_qualification, manifest['source_commit'], retained=retained)
    current = artifact(candidate, 'compat-manifest.json')
    identity = artifact(candidate, 'device-identity-manifest.json')
    for row in (current, identity):
        if source_tree(row['source_commit']) != row['source_tree']:
            raise ValueError('optional artifact source tree mismatch')
    identity_matches_base(identity, base)
    if current.get('architecture') != manifest['build_target_arch']:
        raise ValueError('optional engine architecture differs from the qualified base')
    native = current.get('native_runtime', {})
    native_path = candidate / 'native-runtime.json'
    if (native.get('name') != native_path.name or not native_path.is_file() or native_path.is_symlink()
            or native.get('sha256') != sha(native_path)):
        raise ValueError('composition requires the exact native runtime receipt')
    runtime = json.loads(native_path.read_text())
    if (runtime.get('ok') is not True or {
            (row.get('artifact'), row.get('sha256')) for row in runtime.get('packages', [])} != {
            (row['artifact'], row['sha256']) for row in (current, identity)}):
        raise ValueError('composition native runtime receipt does not cover both APKs')
    names = ('compat-public-key.pem', 'compat-packages.adb', current['artifact'], identity['artifact'])
    for name in names:
        if (candidate / name).is_symlink() or not (candidate / name).is_file():
            raise ValueError('composition input must contain regular signed assets')
    return {'schema': COMPOSITION_SCHEMA, 'base': base, 'engine': current, 'identity': identity,
            'feed_sha256': {name: sha(candidate / name) for name in names}}


def composition_evidence(request, proof):
    """Accept only the guest's completed tests of the same declared composition."""
    if not isinstance(request, dict) or request.get('schema') != COMPOSITION_SCHEMA:
        raise ValueError('invalid composition request schema')
    lane = proof.get('lanes', {}).get('compatibility', {})
    checks = lane.get('checks', {})
    base = request['base']
    if (proof.get('diagnostic_passed') is not True
            or proof.get('source_commit') != base['source_commit']
            or proof.get('source_tree') != base['source_tree'] or proof.get('base') != base
            or lane.get('source_commit') != base['source_commit']
            or lane.get('source_tree') != base['source_tree'] or lane.get('ok') is not True
            or lane.get('composition') != request
            or not isinstance(checks, dict) or not checks or not all(value is True for value in checks.values())
            or not all(checks.get(name) is True for name in COMPOSITION_CHECKS)):
        raise ValueError('missing exact composition install, runtime or failure evidence')
    if base.get('retained') and checks.get('retained_base_packages') is not True:
        raise ValueError('missing retained base package evidence')
    return checks


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--packages', required=True, type=Path)
    p.add_argument('--base-qualification', required=True, type=Path)
    p.add_argument('--candidate', required=True, type=Path)
    p.add_argument('--previous', type=Path)
    p.add_argument('--composition', action='store_true',
                   help='qualify unchanged optional APKs against the exact new qualified base')
    p.add_argument('--output', required=True, type=Path)
    p.add_argument('--benchmark', action='store_true')
    p.add_argument('--retained-base', type=Path, help='exact signed plugins retained by the target')
    p.add_argument('--validate-only', action='store_true')
    a = p.parse_args()
    current = artifact(a.candidate, 'compat-manifest.json')
    identity = artifact(a.candidate, 'device-identity-manifest.json')
    if a.composition:
        if a.previous or a.benchmark:
            p.error('--composition does not compare or update engine versions; omit --previous and --benchmark')
        request = composition_request(a.packages, a.base_qualification, a.candidate, a.retained_base)
        base = request['base']
        execution_commit, tree = base['source_commit'], base['source_tree']
        result = {'schema': COMPOSITION_QUALIFICATION, 'composition_qualified': False,
                  'source_commit': execution_commit, 'source_tree': tree, 'composition': request}
    else:
        if a.previous is None:
            p.error('engine update qualification requires --previous; use --composition for unchanged APKs')
        previous = artifact(a.previous, 'compat-manifest.json')
        old_identity = artifact(a.previous, 'device-identity-manifest.json')
        base = validate(a.packages, a.base_qualification, current['source_commit'], retained=a.retained_base)
        execution_commit, tree = current['source_commit'], source_tree(current['source_commit'])
        if current['source_tree'] != tree or identity != old_identity:
            raise ValueError('engine source mismatch or unexpected identity plugin update')
        identity_matches_base(identity, base)
        result = {'schema':'opl-netfleet-https-plugin-qualification.v1', 'plugin_qualified':False,
                  'source_commit':execution_commit, 'source_tree':tree,
                  'base':base, 'engine':current, 'previous_engine':previous,
                  'identity':identity, 'packages':['opl-netfleet-https-compat']}
    if a.validate_only:
        print(json.dumps(result)); return
    output = a.output.resolve()
    canonical = Path(subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', '--path-format=absolute', '--git-common-dir'], text=True).strip()).parent
    if output.is_relative_to(ROOT) or output.is_relative_to(canonical):
        raise ValueError('receipts must remain outside repositories')
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='https-plugin-qualification-') as directory:
        stage = Path(directory)
        for file in a.candidate.iterdir():
            if not file.is_file() or file.is_symlink(): raise ValueError('candidate must contain regular files')
            shutil.copyfile(file, stage/file.name)
        if a.composition:
            (stage/'composition.json').write_text(json.dumps(request, sort_keys=True) + '\n')
        else:
            (stage/'rollback').mkdir()
            shutil.copyfile(a.previous/previous['artifact'],stage/'rollback'/previous['artifact'])
            (stage/'upgrade.json').write_text(json.dumps({
                'old':{'file':'rollback/'+previous['artifact'],'sha256':previous['sha256']},
                'new':{'file':current['artifact'],'sha256':current['sha256']}}))
        if a.retained_base is not None:
            shutil.copytree(a.retained_base, stage/'retained-base')
        diagnostic = output.with_suffix('.diagnostic.json')
        command = ['bash',str(ROOT/'scripts/openwrt-vm.sh'),'--ref',execution_commit,
                   '--packages',str(a.packages.resolve()),'--base-qualification',str(a.base_qualification.resolve()),
                   '--diagnostic','compatibility','--compat-package',str(stage),'--output',str(diagnostic)]
        if a.benchmark: command.append('--benchmark')
        subprocess.run(command,check=True)
        proof=json.loads(diagnostic.read_text())
        checks=proof.get('lanes',{}).get('compatibility',{}).get('checks',{})
        if a.composition:
            checks = composition_evidence(request, proof)
        elif (proof.get('diagnostic_passed') is not True or proof.get('source_commit')!=execution_commit
              or proof.get('source_tree')!=tree or proof.get('base')!=base
              or checks.get('engine_package_cycle') is not True or checks.get('dual_stack_probe_faults') is not True):
            raise ValueError('missing plugin update or failure evidence')
        if a.retained_base is not None and checks.get('retained_base_packages') is not True:
            raise ValueError('missing retained base package evidence')
        qualification_flag = 'composition_qualified' if a.composition else 'plugin_qualified'
        result.update({qualification_flag: True, 'checks': checks, 'diagnostic_sha256': sha(diagnostic),
                       'benchmark': proof['lanes']['compatibility'].get('benchmark')})
        temporary=output.with_suffix('.tmp');temporary.write_text(json.dumps(result,indent=2)+'\n');temporary.replace(output)
        print(json.dumps({qualification_flag:True,'receipt':str(output)}))


if __name__ == '__main__': main()
