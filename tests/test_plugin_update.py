"""Host-side exact package and qualification admission."""
import importlib.util
from pathlib import Path
import unittest

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

if __name__ == '__main__': unittest.main()
