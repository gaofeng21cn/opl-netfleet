"""Identity gates for engine-only development and deployment; never contact devices."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
DIR=ROOT/'scripts/https-compat'
sys.path.insert(0,str(DIR))
import base
import qualify
import update

class EngineArtifacts(unittest.TestCase):
    def test_name_and_bytes_are_bound(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);name='opl-netfleet-https-compat-0.5.3-r1.apk'
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
