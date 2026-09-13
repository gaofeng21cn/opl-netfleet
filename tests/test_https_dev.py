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
import update
import compare

class EngineArtifacts(unittest.TestCase):
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

    def test_update_requires_real_bound_checks(self):
        engine={'source_commit':'a'*40,'source_tree':'c'*40,'artifact':'engine.apk','sha256':'e'}
        old={'artifact':'old.apk','sha256':'o'};identity={'sha256':'i'};fixed={'source_commit':'b'*40}
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);receipt=root/'proof.json';diagnostic=receipt.with_suffix('.diagnostic.json')
            wire={'diagnostic_passed':True,'source_commit':engine['source_commit'],
                  'source_tree':engine['source_tree'],'base':fixed,
                  'lanes':{'compatibility':{'checks':dict.fromkeys(update.REQUIRED,True)}}}
            diagnostic.write_text(json.dumps(wire))
            proof={'schema':'opl-netfleet-https-plugin-qualification.v1','plugin_qualified':True,
                'source_commit':engine['source_commit'],'source_tree':engine['source_tree'],
                'base':fixed,'engine':engine,'previous_engine':old,'identity':identity,
                'packages':['opl-netfleet-https-compat'],
                'checks':dict.fromkeys(update.REQUIRED,True),'diagnostic_sha256':base.sha(diagnostic)}
            def run(value):
                receipt.write_text(json.dumps(value))
                with patch.object(update,'artifact',side_effect=[engine,old,identity]),patch.object(update,'validate',return_value=fixed),patch.object(update.subprocess,'check_output',side_effect=lambda args:(DIR/args[-1].split('/')[-1]).read_bytes()):
                    return update.verify(root,root,root,root,receipt)
            self.assertEqual(run(proof),(engine,old))
            for key in update.REQUIRED:
                changed={**proof,'checks':{**proof['checks'],key:False}}
                with self.subTest(key=key),self.assertRaises(ValueError):run(changed)
            for key,value in [('plugin_qualified',False),('source_commit','d'*40),('source_tree','d'*40),('base',{}),('packages',['opl-netfleet']),('engine',old),('identity',{})]:
                with self.subTest(key=key),self.assertRaises(ValueError):run({**proof,key:value})
            diagnostic.write_text(json.dumps({**wire,'diagnostic_passed':False}))
            with self.assertRaises(ValueError):run({**proof,'diagnostic_sha256':base.sha(diagnostic)})
            diagnostic.write_text('changed')
            with self.assertRaises(ValueError):run(proof)

if __name__=='__main__':unittest.main()
