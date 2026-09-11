#!/usr/bin/env python3
"""Qualify a signed HTTPS engine update on an unchanged, qualified base."""
import argparse
import json
import re
from pathlib import Path
import shutil
import subprocess
import tempfile
from base import ROOT, sha, validate


def artifact(directory, name):
    value = json.loads((directory / name).read_text())
    file = value['artifact']
    package='opl-netfleet-https-compat' if name=='compat-manifest.json' else 'opl-netfleet-plugin-device-identity'
    if not re.fullmatch(re.escape(package)+r'-[0-9]+\.[0-9]+\.[0-9]+-r[0-9]+\.apk',file) or sha(directory / file) != value['sha256']:
        raise ValueError('optional artifact identity mismatch')
    return value


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--packages', required=True, type=Path)
    p.add_argument('--base-qualification', required=True, type=Path)
    p.add_argument('--candidate', required=True, type=Path)
    p.add_argument('--previous', required=True, type=Path)
    p.add_argument('--output', required=True, type=Path)
    p.add_argument('--benchmark', action='store_true')
    p.add_argument('--validate-only', action='store_true')
    a = p.parse_args()
    current = artifact(a.candidate, 'compat-manifest.json')
    previous = artifact(a.previous, 'compat-manifest.json')
    identity = artifact(a.candidate, 'device-identity-manifest.json')
    old_identity = artifact(a.previous, 'device-identity-manifest.json')
    base = validate(a.packages, a.base_qualification, current['source_commit'])
    tree = subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', current['source_commit']+'^{tree}'], text=True).strip()
    if current['source_tree'] != tree or identity != old_identity:
        raise ValueError('engine source mismatch or unexpected identity plugin update')
    if identity['source_commit'] != base['source_commit'] or identity['source_tree'] != base['source_tree']:
        raise ValueError('identity plugin is not from the fixed base')
    result = {'schema':'opl-netfleet-https-plugin-qualification.v1', 'plugin_qualified':False,
              'source_commit':current['source_commit'], 'source_tree':tree,
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
        (stage/'rollback').mkdir()
        shutil.copyfile(a.previous/previous['artifact'],stage/'rollback'/previous['artifact'])
        (stage/'upgrade.json').write_text(json.dumps({
            'old':{'file':'rollback/'+previous['artifact'],'sha256':previous['sha256']},
            'new':{'file':current['artifact'],'sha256':current['sha256']}}))
        diagnostic = output.with_suffix('.diagnostic.json')
        command = ['bash',str(ROOT/'scripts/openwrt-vm.sh'),'--ref',current['source_commit'],
                   '--packages',str(a.packages.resolve()),'--base-qualification',str(a.base_qualification.resolve()),
                   '--diagnostic','compatibility','--compat-package',str(stage),'--output',str(diagnostic)]
        if a.benchmark: command.append('--benchmark')
        subprocess.run(command,check=True)
        proof=json.loads(diagnostic.read_text())
        checks=proof.get('lanes',{}).get('compatibility',{}).get('checks',{})
        if (proof.get('diagnostic_passed') is not True or proof.get('source_commit')!=current['source_commit']
            or proof.get('source_tree')!=tree or proof.get('base')!=base
            or checks.get('engine_package_cycle') is not True or checks.get('dual_stack_probe_faults') is not True):
            raise ValueError('missing plugin update or failure evidence')
        result.update(plugin_qualified=True,checks=checks,diagnostic_sha256=sha(diagnostic),
                      benchmark=proof['lanes']['compatibility'].get('benchmark'))
        temporary=output.with_suffix('.tmp');temporary.write_text(json.dumps(result,indent=2)+'\n');temporary.replace(output)
        print(json.dumps({'plugin_qualified':True,'receipt':str(output)}))


if __name__ == '__main__': main()
