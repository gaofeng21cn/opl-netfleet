"""Host-side exact package and qualification admission."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch
from types import SimpleNamespace
import json
import tempfile

spec = importlib.util.spec_from_file_location('plugin_update', Path(__file__).resolve().parents[1] / 'scripts/update-openwrt-plugins.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

class PluginUpdateTests(unittest.TestCase):
    def test_exact_selection_excludes_core_and_optional_packages(self):
        manifest = {'artifacts': [{'package': 'opl-netfleet-plugin-models'}, {'package': 'opl-netfleet-plugin-components'}, {'package': 'opl-netfleet'}, {'package': 'luci-app-netfleet'}, {'package': 'luci-app-nikki'}]}
        selected = mod.package_selection(manifest, ['opl-netfleet-plugin-models'])
        self.assertEqual(selected, [{'package': 'opl-netfleet-plugin-models'}])
        self.assertEqual(mod.package_selection(manifest, ['luci-app-netfleet']), [{'package': 'luci-app-netfleet'}])
        for names in [[], ['opl-netfleet'], ['luci-app-nikki'], ['mihomo-meta'], ['opl-netfleet-https-compat'], ['opl-netfleet-plugin-models'] * 2]:
            with self.assertRaises(ValueError): mod.package_selection(manifest, names)

    def test_unchanged_packages_need_no_transport_or_rollback_archive(self):
        rows=[{'package':'ui','version':'1.2.3'},{'package':'service','version':'2.0.0'}]
        version=lambda row: row['version']
        self.assertEqual(mod.changed_selection(rows,{'ui':'1.2.3','service':'1.9.0'},version),([rows[1]],['ui']))
        self.assertEqual(mod.changed_selection(rows,{'ui':'1.2.3','service':'2.0.0'},version),([],['ui','service']))
        with self.assertRaises(ValueError):mod.changed_selection(rows,{'ui':'1.2.3'},version)

    def test_qualification_must_match_source_and_candidate(self):
        manifest = b'candidate'
        receipt = {'schema': 'opl-netfleet-openwrt-vm-qualification.v2', 'qualified': True,
                   'source_commit': 'a'*40, 'source_tree': 'b'*40, 'package_qualified': True,
                   'package': {'manifest_sha256': mod.sha(manifest)},
                   'checks': dict.fromkeys(['boot','ssh','var_symlink','ubus','deploy_failure_rollback','post_failure_management'], True)}
        mod.qualified(receipt, 'a'*40, 'b'*40, manifest)
        for changed, commit, data in [({'qualified': False}, 'a'*40, manifest), ({}, 'c'*40, manifest), ({}, 'a'*40, b'other')]:
            with self.assertRaises(ValueError): mod.qualified(receipt | changed, commit, 'b'*40, data)

class FeedUpdateTests(unittest.TestCase):
    def args(self, name):
        return SimpleNamespace(target='fixture', plugin=[name], dry_run=True)

    def test_optional_runtime_uses_device_solver_without_local_pairing(self):
        row={'name':'example-engine','installed_version':'1','available_version':'2'}
        plan={'names':['example-engine','opl-netfleet-plugin-example'],
              'candidates':{'example-engine':'2','opl-netfleet-plugin-example':'3'}}
        calls=[]
        def run(command, **kwargs):
            calls.append((command,kwargs))
            if 'components-get' in command[-1]:
                return json.dumps({'ok':True,'result':{'plugin_packages':[row]}}).encode()
            self.assertIn('components_plugin_plan',command[-1])
            request=json.loads(kwargs['input'])['request']
            self.assertEqual(request['name'],'example-engine')
            self.assertNotIn('plan',request)
            return json.dumps({'ok':True,'result':plan}).encode()
        with patch.object(mod,'run',side_effect=run), patch.object(mod.subprocess,'run') as mutation:
            result=mod.feed_update(self.args('example-engine'),['ssh','fixture'])
        self.assertEqual(result['plan'],plan)
        self.assertEqual(len(calls),2)
        mutation.assert_not_called()

    def test_feed_no_change_needs_no_transaction_or_archive(self):
        row={'name':'opl-netfleet-plugin-example','installed_version':'2','available_version':'2'}
        with patch.object(mod,'run',return_value=json.dumps({'ok':True,'result':{'plugin_packages':[row]}}).encode()) as read, patch.object(mod.subprocess,'run') as mutation:
            result=mod.feed_update(self.args(row['name']),['ssh','fixture'])
        self.assertEqual(result['state'],'no_change')
        self.assertFalse(result['device_mutation'])
        self.assertEqual(read.call_count,1)
        mutation.assert_not_called()

if __name__ == '__main__': unittest.main()
