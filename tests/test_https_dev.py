"""Identity gates for engine-only development and deployment; never contact devices."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import subprocess
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
DIR=ROOT/'scripts/https-compat'
sys.path.insert(0,str(DIR))
import base
import qualify
import compare

class EngineArtifacts(unittest.TestCase):
    def test_composition_keeps_old_optional_bytes_and_runs_the_new_base_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.check_output(['git', '-C', str(root), *args], text=True).strip()
            git('init', '-q');git('config', 'user.name', 'Fixture');git('config', 'user.email', 'fixture@example.invalid')
            source = root / 'plugins/device-identity/control'
            source.parent.mkdir(parents=True);source.write_text('identity stays unchanged')
            (root / 'gateway').write_text('old base caller')
            git('add', '.');git('commit', '-qm', 'optional artifact sources')
            old_commit, old_tree = git('rev-parse', 'HEAD'), git('rev-parse', 'HEAD^{tree}')
            (root / 'gateway').write_text('new base caller')
            git('add', '.');git('commit', '-qm', 'new base qualification')
            fixed = {'source_commit':git('rev-parse', 'HEAD'), 'source_tree':git('rev-parse', 'HEAD^{tree}'),
                     'manifest_sha256':'a'*64,'qualification_sha256':'b'*64,'runtime_sha256':{'gateway':'c'*64}}
            packages = root / 'packages';packages.mkdir()
            (packages / 'manifest.json').write_text(json.dumps({**fixed,'build_target_arch':'aarch64_generic'}))
            candidate = root / 'candidate';candidate.mkdir()
            rows=[]
            for name, manifest_name in [('opl-netfleet-https-compat', 'compat-manifest.json'),
                                        ('opl-netfleet-plugin-device-identity', 'device-identity-manifest.json')]:
                path=candidate/(name+'-1.0.0.apk');path.write_bytes(name.encode())
                value={'artifact':path.name,'sha256':base.sha(path),'source_commit':old_commit,
                       'source_tree':old_tree,'architecture':'aarch64_generic'}
                (candidate / manifest_name).write_text(json.dumps(value));rows.append(value)
            native=candidate/'native-runtime.json'
            native.write_text(json.dumps({'ok':True,'packages':rows}))
            rows[0]['native_runtime']={'name':native.name,'sha256':base.sha(native)}
            (candidate/'compat-manifest.json').write_text(json.dumps(rows[0]))
            (candidate/'compat-public-key.pem').write_text('public key fixture')
            (candidate/'compat-packages.adb').write_text('signed index fixture')
            before={path.name:path.read_bytes() for path in candidate.iterdir()}
            read_tree=qualify.source_tree;check_identity=qualify.identity_matches_base
            with patch.object(qualify, 'validate', return_value=fixed) as validate, \
                 patch.object(qualify, 'source_tree', side_effect=lambda commit:read_tree(commit,root)), \
                 patch.object(qualify, 'identity_matches_base', side_effect=lambda identity,base:check_identity(identity,base,root)):
                request=qualify.composition_request(packages, root/'base-proof.json', candidate)
            validate.assert_called_once_with(packages,root/'base-proof.json',fixed['source_commit'],retained=None)
            self.assertNotEqual(request['base']['source_commit'],request['engine']['source_commit'])
            self.assertEqual(request['engine'],rows[0]);self.assertEqual(request['identity'],rows[1])
            self.assertEqual(before,{path.name:path.read_bytes() for path in candidate.iterdir()})

    def test_composition_requires_full_real_guest_checks_and_exact_both_identities(self):
        import copy
        request={'schema':qualify.COMPOSITION_SCHEMA,
                 'base':{'source_commit':'b'*40,'source_tree':'c'*40,'manifest_sha256':'d'*64},
                 'engine':{'source_commit':'a'*40,'sha256':'e'*64},'identity':{'sha256':'f'*64},
                 'feed_sha256':{'compat-packages.adb':'1'*64}}
        checks=dict.fromkeys(qualify.COMPOSITION_CHECKS,True)
        proof={'diagnostic_passed':True,'source_commit':'b'*40,'source_tree':'c'*40,'base':request['base'],
               'lanes':{'compatibility':{'ok':True,'source_commit':'b'*40,'source_tree':'c'*40,
                        'checks':checks,'composition':request}}}
        self.assertEqual(qualify.composition_evidence(request,proof),checks)
        for change in ['old-source','base','engine','index','missing-bootstrap','failed-check','not-passed']:
            altered=copy.deepcopy(proof)
            if change=='old-source':altered['source_commit']='a'*40
            if change=='base':altered['base']['manifest_sha256']='0'*64
            if change=='engine':altered['lanes']['compatibility']['composition']['engine']['sha256']='0'*64
            if change=='index':altered['lanes']['compatibility']['composition']['feed_sha256']['compat-packages.adb']='0'*64
            if change=='missing-bootstrap':del altered['lanes']['compatibility']['checks']['full_feed_bootstrap']
            if change=='failed-check':altered['lanes']['compatibility']['checks']['real_gateway_h2']=False
            if change=='not-passed':altered['diagnostic_passed']=False
            with self.subTest(change=change),self.assertRaises(ValueError):
                qualify.composition_evidence(request,altered)

    def test_composition_records_new_test_source_without_relabelling_packages(self):
        import copy
        base={'source_commit':'b'*40,'source_tree':'c'*40}
        tested={'source_commit':'d'*40,'source_tree':'e'*40}
        request={'schema':qualify.COMPOSITION_SCHEMA,'base':base,'test_source':tested}
        checks=dict.fromkeys(qualify.COMPOSITION_CHECKS,True)
        proof={'diagnostic_passed':True,**tested,'base':base,
               'lanes':{'compatibility':{'ok':True,**tested,'checks':checks,'composition':request}}}
        self.assertEqual(qualify.composition_evidence(request,proof),checks)
        altered=copy.deepcopy(proof);altered.update(base)
        with self.assertRaises(ValueError):qualify.composition_evidence(request,altered)
        altered=copy.deepcopy(proof);altered['base']=tested
        with self.assertRaises(ValueError):qualify.composition_evidence(request,altered)

    def test_base_binding_includes_actual_gateway_templates(self):
        import hashlib
        source=ROOT/'openwrt/files'
        paths=[p for p in source.rglob('*') if p.is_file()]
        inventory={str(p.relative_to(source)):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            def write():
                (root/'FILES.sha256').write_text(''.join(f'{digest}  {name}\n' for name,digest in inventory.items()))
            write()
            selected=base.runtime_files(root)
            template='usr/share/opl-netfleet/nikki/hijack.ut'
            self.assertEqual(selected['/'+template],inventory[template])
            del inventory[template]
            write()
            with self.assertRaises(ValueError):base.runtime_files(root)

    def test_dev_runner_releases_its_lock_after_success_or_failure(self):
        import os
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);binary=root/'bin';binary.mkdir();candidate=root/'candidate';candidate.mkdir()
            (candidate/'compat-manifest.json').write_text('{}')
            runner=binary/'python3';runner.write_text('#!/bin/sh\nexit "$FIXTURE_STATUS"\n');runner.chmod(0o755)
            lock=root/'lock'
            env={**os.environ,'PATH':str(binary)+os.pathsep+os.environ['PATH'],
                 'NETFLEET_COMPAT_LOCKDIR':str(lock),'OUTPUT':str(root/'out'),'REF':'HEAD',
                 'PACKAGES':str(root),'COMPAT_PACKAGES':str(candidate),'BASE_QUALIFICATION':str(root/'base.json'),
                 'PREVIOUS':str(candidate)}
            for status in [0,7]:
                result=subprocess.run(['bash',str(DIR/'dev.sh'),'qualify'],env={**env,'FIXTURE_STATUS':str(status)},capture_output=True)
                self.assertEqual(result.returncode,status,result.stderr.decode())
                self.assertFalse(lock.exists())

    def test_retained_set_binds_exact_owner_files_without_downgrading_other_plugins(self):
        import copy
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); name='opl-netfleet-plugin-platform'; version='0.8.5'
            archive=f'{name}-{version}.apk'; (root/archive).write_bytes(b'signed archive fixture')
            (root/'public.pem').write_bytes(b'PUBLIC KEY fixture')
            prefix='/usr/libexec/opl-netfleet/plugins/platform/'
            inventory={prefix+'manifest.json':'a'*64,prefix+'lib/paths.uc':'b'*64}
            manifest={'schema':'opl-netfleet-retained-base.v1','keys':[{'name':'public.pem','sha256':base.sha(root/'public.pem')}],
                      'artifacts':[{'package':name,'version':version,'artifact':archive,'sha256':base.sha(root/archive),'files':inventory}]}
            other='/usr/libexec/opl-netfleet/plugins/mihomo/lib/gateway.uc'
            runtime={prefix+'manifest.json':'c'*64,prefix+'lib/paths.uc':'d'*64,other:'e'*64}
            def run(value):
                (root/'retained-base.json').write_text(json.dumps(value))
                return base.retained_runtime(root,runtime)
            projected,proof=run(manifest)
            self.assertEqual(projected,{**inventory,other:'e'*64})
            self.assertEqual(proof['manifest_sha256'],base.sha(root/'retained-base.json'))
            for change in ['digest','escape','missing','gateway','key','extra']:
                value=copy.deepcopy(manifest)
                if change=='digest':value['artifacts'][0]['sha256']='0'*64
                if change=='escape':value['artifacts'][0]['files'][prefix+'../gateway.uc']='f'*64
                if change=='missing':del value['artifacts'][0]['files'][prefix+'lib/paths.uc']
                if change=='gateway':value['artifacts'][0]['package']='opl-netfleet-plugin-mihomo'
                if change=='key':value['keys'][0]['name']='../public.pem'
                if change=='extra':(root/'unexpected').write_text('not part of composition')
                with self.subTest(change=change),self.assertRaises(ValueError):run(value)

    def test_retained_scheduler_only_keeps_the_qualified_launcher(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);name='opl-netfleet-plugin-scheduler';archive=name+'-0.7.2-r1.apk'
            (root/archive).write_bytes(b'signed fixture');(root/'public.pem').write_bytes(b'PUBLIC KEY fixture')
            prefix='/usr/libexec/opl-netfleet/plugins/scheduler/'
            runtime={prefix+'manifest.json':'a'*64,'/etc/init.d/opl-netfleet':'b'*64}
            manifest={'schema':'opl-netfleet-retained-base.v1','keys':[{'name':'public.pem','sha256':base.sha(root/'public.pem')}],
                'artifacts':[{'package':name,'version':'0.7.2-r1','artifact':archive,'sha256':base.sha(root/archive),'files':dict(runtime)}]}
            def run():
                (root/'retained-base.json').write_text(json.dumps(manifest))
                return base.retained_runtime(root,runtime)
            self.assertEqual(run()[0],runtime)
            manifest['artifacts'][0]['files']['/etc/init.d/opl-netfleet']='c'*64
            with self.assertRaises(ValueError):run()
            del manifest['artifacts'][0]['files']['/etc/init.d/opl-netfleet']
            manifest['artifacts'][0]['files']['/etc/init.d/opl-netfleet-core']='b'*64
            with self.assertRaises(ValueError):run()

    def test_alternating_benchmark_requires_complete_versions(self):
        rows=[{'version':version,'name':f'{rep}-{scene}'} for version in ['old','new']
              for rep in range(1,4) for scene in ['off','idle','load','ui']]
        value={'seconds':300,'repeats':3,'comparison':'alternating_signed_packages_same_guest','rows':rows}
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'benchmark.json';path.write_text(json.dumps(value))
            self.assertEqual(len(compare.benchmark(path,'old')),12)
            self.assertEqual(len(compare.benchmark(path,'new')),12)
            rows.pop();path.write_text(json.dumps(value))
            with self.assertRaises(ValueError):compare.benchmark(path,'new')

    def test_benchmark_preserves_failed_samples_and_separate_ui_cost(self):
        row={'name':'1-load','groups':{'manager':{'cpu_percent':2,'memory':100,
             'peak_memory':200,'peak_rss':150,'throttled':1}},
             'requests':{'upload':[{'code':502,'ttfb':.2,'total':.3}], 'sse':[]},
             'ui':[{'seconds':.1,'cpu_ticks':4,'ok':False}], 'codes':'0\n28', 'errors':'protocol mismatch'}
        result=compare.summarize([row],'load')
        self.assertEqual(result['requests']['upload']['http_errors'],1)
        self.assertEqual(result['failed_commands'],1)
        self.assertTrue(result['error_output'])
        self.assertEqual(result['groups']['manager']['memory_max'],200)
        self.assertEqual(result['ui']['cpu_seconds'],.04)
        self.assertEqual(result['ui']['failed'],1)

    def test_benchmark_requires_admission_and_complete_work_in_every_window(self):
        import copy
        row={'name':'1-load','groups':{'manager':{'cpu_percent':2,'memory':100,
             'throttled':1,'throttled_usec':50000,'peak_processes':3}},
             'requests':{kind:[{'code':200,'ttfb':.02,'total':.03}] for kind in ['upload','sse']},
             'admission':{'samples':150,'invalid':0},'codes':'0','errors':''}
        good=compare.summarize([row],'load')
        self.assertTrue(good['performance_comparable'])
        self.assertEqual(good['groups']['manager']['throttled_seconds'],.05)
        for change in ['bypass','no_admission','no_upload','no_sse','http','command','body']:
            bad=copy.deepcopy(row);bad['name']='2-load'
            if change=='bypass':bad['admission']['invalid']=1
            if change=='no_admission':bad['admission']['samples']=0
            if change=='no_upload':bad['requests']['upload']=[]
            if change=='no_sse':bad['requests']['sse']=[]
            if change=='http':bad['requests']['upload'][0]['code']=503
            if change=='command':bad['codes']='28'
            if change=='body':bad['errors']='sse_incomplete'
            with self.subTest(change=change):
                self.assertFalse(compare.summarize([row,bad],'load')['performance_comparable'])
        row['name']='1-ui';row['ui']=[{'ok':True,'seconds':.1,'cpu_ticks':4}]
        self.assertTrue(compare.summarize([row],'ui')['performance_comparable'])
        other=copy.deepcopy(row);other['name']='2-ui';other['ui']=[]
        self.assertFalse(compare.summarize([row,other],'ui')['performance_comparable'])

    def test_independent_identity_source_on_newer_base(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.check_output(['git', '-C', str(root), *args], text=True).strip()
            git('init', '-q');git('config', 'user.name', 'Fixture');git('config', 'user.email', 'fixture@example.invalid')
            source=root/'plugins/device-identity/control';source.parent.mkdir(parents=True);source.write_text('stable')
            git('add', '.');git('commit', '-qm', 'identity')
            identity={'source_commit':git('rev-parse','HEAD'),'source_tree':git('rev-parse','HEAD^{tree}')}
            (root/'unrelated').write_text('base change');git('add','.');git('commit','-qm','new base')
            fixed={'source_commit':git('rev-parse','HEAD')}
            qualify.identity_matches_base(identity,fixed,root)
            with self.assertRaises(ValueError):
                qualify.identity_matches_base({**identity,'source_tree':'0'*40},fixed,root)
            source.write_text('changed');git('add','.');git('commit','-qm','identity change')
            with self.assertRaises(ValueError):
                qualify.identity_matches_base(identity,{'source_commit':git('rev-parse','HEAD')},root)

    def test_name_and_bytes_are_bound(self):
        for version in ('0.5.3-r1', '0.6.1'):
            with tempfile.TemporaryDirectory() as directory:
                root=Path(directory);name=f'opl-netfleet-https-compat-{version}.apk'
                (root/name).write_bytes(b'candidate')
                manifest={'artifact':name,'sha256':base.sha(root/name)}
                (root/'compat-manifest.json').write_text(json.dumps(manifest))
                self.assertEqual(qualify.artifact(root,'compat-manifest.json'),manifest)
                (root/name).write_bytes(b'changed')
                with self.assertRaises(ValueError):qualify.artifact(root,'compat-manifest.json')
                manifest['artifact']='../'+name
                (root/'compat-manifest.json').write_text(json.dumps(manifest))
                with self.assertRaises(ValueError):qualify.artifact(root,'compat-manifest.json')

if __name__=='__main__':unittest.main()
