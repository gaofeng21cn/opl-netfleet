#!/usr/bin/env python3
"""Bind exact native plugin APKs and build a signed probe-failure fixture."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

p = argparse.ArgumentParser()
p.add_argument('--old', required=True, type=Path)
p.add_argument('--new', required=True, type=Path)
p.add_argument('--output', required=True, type=Path)
a = p.parse_args()
sdk = Path(os.environ['NETFLEET_SDK']).resolve()
out = a.output.resolve()
out.mkdir(mode=0o700)
with tempfile.TemporaryDirectory(prefix='native-retained-fixture-') as directory:
    scratch = Path(directory)
    for kind, source in [('old', a.old), ('new', a.new)]:
        (out/kind).mkdir()
        shutil.copyfile(source, out/kind/source.name)
    def run(*args):
        cmd = ['docker', 'run', '--rm', '--pull=never', '--platform', 'linux/amd64',
               '-v', f'{sdk}:{sdk}:ro', '-v', f'{out}:{out}', '-v', f'{scratch}:{scratch}',
               'opl-netfleet-openwrt-sdk-builder:latest', str(sdk/'staging_dir/host/bin/apk'), *map(str,args)]
        return subprocess.check_output(cmd, text=True)
    key = scratch/'private.pem'
    subprocess.run(['openssl', 'genpkey', '-algorithm', 'EC', '-pkeyopt', 'ec_paramgen_curve:P-256', '-out', str(key)], check=True, capture_output=True)
    subprocess.run(['openssl', 'pkey', '-in', str(key), '-pubout', '-out', str(out/'public-key.pem')], check=True, capture_output=True)
    root = scratch/'payload'; root.mkdir()
    metadata = json.loads(run('adbdump', '--format', 'json', out/'new'/a.new.name))
    run('--allow-untrusted', 'extract', '--destination', root, out/'new'/a.new.name)
    version = metadata['info']['version']; parts = version.split('.'); parts[-1] = str(int(parts[-1])+1); bad_version = '.'.join(parts)
    plugin = root/'usr/libexec/opl-netfleet/plugins/mihomo'
    manifest = json.loads((plugin/'manifest.json').read_text()); manifest['version'] = bad_version
    (plugin/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    (plugin/'lib/probes.uc').write_text("return function(context) { return { command_probe: function(argv) { context.use('events.output').fail('probe','injected_probe_failure',{}); } }; };\n")
    (out/'bad').mkdir()
    bad = out/'bad'/f'opl-netfleet-plugin-mihomo-{bad_version}.apk'
    args = ['mkpkg', '--files', root, '--output', bad, '--sign-key', key]
    for name, value in metadata['info'].items():
        if name in ['hashes','installed-size','file-size']: continue
        if name == 'version': value = bad_version
        args += ['--info', f'{name}:{" ".join(value) if isinstance(value,list) else value}']
    for kind, content in metadata.get('scripts',{}).items():
        file=scratch/(kind+'.sh');file.write_text(content);args+=['--script',f'{kind}:{file}']
    run(*args)
    cycle={}
    for kind in ['old','new','bad']:
        file=next((out/kind).glob('*.apk')); m=json.loads(run('adbdump','--format','json',file))['info']
        cycle[kind]={'artifact':file.name,'version':m['version'],'sha256':hashlib.sha256(file.read_bytes()).hexdigest()}
    (out/'cycle.json').write_text(json.dumps(cycle,indent=2)+'\n')
print(json.dumps({'fixture':str(out),'old':cycle['old']['version'],'new':cycle['new']['version'],'bad':cycle['bad']['version']}))
