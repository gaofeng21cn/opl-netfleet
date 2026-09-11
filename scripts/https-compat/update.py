#!/usr/bin/env python3
"""Install only a qualified HTTPS engine; retain a target-local rollback worker."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import shlex
import subprocess
import tarfile
import uuid
from base import ROOT, sha, validate
from qualify import artifact

REQUIRED = ['engine_package_cycle', 'dual_stack_probe_faults', 'native_dependency_closure',
            'real_gateway_h2', 'simultaneous_stall_fail_open', 'base_pid_unchanged',
            'base_configuration_unchanged', 'streaming_upload_and_sse']


def verify(packages, base_proof, candidate, previous, receipt):
    current = artifact(candidate, 'compat-manifest.json')
    old = artifact(previous, 'compat-manifest.json')
    identity = artifact(candidate, 'device-identity-manifest.json')
    base = validate(packages, base_proof, current['source_commit'])
    proof = json.loads(receipt.read_text())
    if (proof.get('schema') != 'opl-netfleet-https-plugin-qualification.v1'
            or proof.get('plugin_qualified') is not True or proof.get('base') != base
            or proof.get('engine') != current or proof.get('previous_engine') != old
            or proof.get('identity') != identity or proof.get('packages') != ['opl-netfleet-https-compat']
            or not all(proof.get('checks', {}).get(key) is True for key in REQUIRED)):
        raise ValueError('HTTPS engine qualification mismatch')
    diagnostic = receipt.with_suffix('.diagnostic.json')
    if sha(diagnostic) != proof.get('diagnostic_sha256'):
        raise ValueError('HTTPS diagnostic evidence changed')
    for name in ['update-remote.sh', 'update-guard.uc']:
        committed = subprocess.check_output(['git', '-C', str(ROOT), 'show',
            current['source_commit']+':scripts/https-compat/'+name])
        if (ROOT/'scripts/https-compat'/name).read_bytes() != committed:
            raise ValueError('installer differs from qualified source')
    return current, old


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('target')
    for name in ['packages', 'base-qualification', 'candidate', 'previous', 'qualification', 'output']:
        p.add_argument('--'+name, required=True, type=Path)
    p.add_argument('--ssh-option', action='append', default=[])
    p.add_argument('--dry-run', action='store_true')
    a=p.parse_args();os.umask(0o077)
    if a.target.startswith('-'): raise ValueError('invalid target')
    current, old = verify(a.packages, a.base_qualification, a.candidate, a.previous, a.qualification)
    canonical=Path(subprocess.check_output(['git','-C',str(ROOT),'rev-parse','--path-format=absolute','--git-common-dir'],text=True).strip()).parent
    if any(a.output.resolve().is_relative_to(root) for root in [ROOT,canonical]):
        raise ValueError('receipt must remain outside repositories')
    if a.dry_run:
        print(json.dumps({'ok':True,'dry_run':True,'engine':current}));return
    ssh=['ssh','-o','BatchMode=yes','-o','ConnectTimeout=10']
    for option in a.ssh_option:ssh+=['-o',option]
    ssh+=[a.target]
    stage='/tmp/netfleet-https-update-'+uuid.uuid4().hex
    files={current['artifact']:(a.candidate/current['artifact']).read_bytes(),
           old['artifact']:(a.previous/old['artifact']).read_bytes(),
           'request.json':json.dumps({'old':old['artifact'],'new':current['artifact']}).encode()}
    if current['artifact']==old['artifact']:raise ValueError('update requires distinct versions')
    for name in ['update-remote.sh','update-guard.uc']:files[name]=(ROOT/'scripts/https-compat'/name).read_bytes()
    files['SHA256SUMS']=''.join(hashlib.sha256(data).hexdigest()+'  '+name+'\n' for name,data in files.items()).encode()
    a.output.parent.mkdir(parents=True,exist_ok=True)
    evidence={'stage':stage,'target':a.target,'engine':current,'previous_engine':old,'state':'prepared'}
    a.output.write_text(json.dumps(evidence,indent=2)+'\n')
    with io.BytesIO() as stream:
        with tarfile.open(fileobj=stream,mode='w') as tar:
            for name,data in files.items():
                item=tarfile.TarInfo(name);item.size=len(data);item.mode=0o600;tar.addfile(item,io.BytesIO(data))
        subprocess.run(ssh+['umask 077; mkdir '+shlex.quote(stage)+' && tar -xf - -C '+shlex.quote(stage)],input=stream.getvalue(),check=True)
    # Dispatch once. SSH ambiguity always requires readback, never automatic retry.
    subprocess.run(ssh+[shlex.join(['sh',stage+'/update-remote.sh','start',stage])],check=True)
    evidence['state']='running';a.output.write_text(json.dumps(evidence,indent=2)+'\n')
    print(json.dumps(evidence))


if __name__=='__main__':main()
