"""Host-side exact package and qualification admission."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('plugin_update', Path(__file__).resolve().parents[1] / 'scripts/update-openwrt-plugins.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

class PluginUpdateTests(unittest.TestCase):
    def test_exact_selection_excludes_core_and_optional_packages(self):
        manifest = {'artifacts': [{'package': 'opl-netfleet-plugin-models'}, {'package': 'opl-netfleet-plugin-components'}, {'package': 'opl-netfleet'}]}
        selected = mod.package_selection(manifest, ['opl-netfleet-plugin-models'])
        self.assertEqual(selected, [{'package': 'opl-netfleet-plugin-models'}])
        for names in [[], ['opl-netfleet'], ['mihomo-meta'], ['opl-netfleet-https-compat'], ['opl-netfleet-plugin-models'] * 2]:
            with self.assertRaises(ValueError): mod.package_selection(manifest, names)

    def test_qualification_must_match_source_and_candidate(self):
        manifest = b'candidate'
        receipt = {'schema': 'opl-netfleet-openwrt-vm-qualification.v2', 'qualified': True,
                   'source_commit': 'a'*40, 'source_tree': 'b'*40, 'package_qualified': True,
                   'package': {'manifest_sha256': mod.sha(manifest)},
                   'checks': dict.fromkeys(['boot','ssh','var_symlink','ubus','deploy_failure_rollback','post_failure_management'], True)}
        mod.qualified(receipt, 'a'*40, 'b'*40, manifest)
        for changed, commit, data in [({'qualified': False}, 'a'*40, manifest), ({}, 'c'*40, manifest), ({}, 'a'*40, b'other')]:
            with self.assertRaises(ValueError): mod.qualified(receipt | changed, commit, 'b'*40, data)

if __name__ == '__main__': unittest.main()
