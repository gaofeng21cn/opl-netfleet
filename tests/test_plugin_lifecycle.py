"""Plugin update admission, bytecode verification, and APK package hooks."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
HOOK = ROOT / 'openwrt/files/usr/libexec/opl-netfleet-plugin-package'


def _load_module(name: str, relative: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


mod = _load_module('plugin_update', 'scripts/update-openwrt-plugins.py')


class PluginUpdateTests(unittest.TestCase):
    def test_exact_selection_excludes_core_and_optional_packages(self):
        manifest = {'artifacts': [{'package': 'opl-netfleet-plugin-models'}, {'package': 'opl-netfleet-plugin-components'}, {'package': 'opl-netfleet'}, {'package': 'luci-app-netfleet'}, {'package': 'luci-app-nikki'}]}
        selected = mod.package_selection(manifest, ['opl-netfleet-plugin-models'])
        self.assertEqual(selected, [{'package': 'opl-netfleet-plugin-models'}])
        self.assertEqual(mod.package_selection(manifest, ['luci-app-netfleet']), [{'package': 'luci-app-netfleet'}])
        for names in [[], ['opl-netfleet'], ['luci-app-nikki'], ['mihomo-meta'], ['opl-netfleet-https-compat'], ['opl-netfleet-plugin-models'] * 2]:
            with self.assertRaises(ValueError): mod.package_selection(manifest, names)

    def test_unchanged_packages_need_no_transport_or_rollback_archive(self):
        rows = [{'package': 'ui', 'version': '1.2.3'}, {'package': 'service', 'version': '2.0.0'}]
        version = lambda row: row['version']
        self.assertEqual(mod.changed_selection(rows, {'ui': '1.2.3', 'service': '1.9.0'}, version), ([rows[1]], ['ui']))
        self.assertEqual(mod.changed_selection(rows, {'ui': '1.2.3', 'service': '2.0.0'}, version), ([], ['ui', 'service']))
        with self.assertRaises(ValueError): mod.changed_selection(rows, {'ui': '1.2.3'}, version)

    def test_qualification_must_match_source_and_candidate(self):
        manifest = b'candidate'
        receipt = {'schema': 'opl-netfleet-openwrt-vm-qualification.v2', 'qualified': True,
                   'source_commit': 'a' * 40, 'source_tree': 'b' * 40, 'package_qualified': True,
                   'package': {'manifest_sha256': mod.sha(manifest)},
                   'checks': dict.fromkeys(['boot', 'ssh', 'var_symlink', 'ubus', 'deploy_failure_rollback', 'post_failure_management'], True)}
        mod.qualified(receipt, 'a' * 40, 'b' * 40, manifest)
        for changed, commit, data in [({'qualified': False}, 'a' * 40, manifest), ({}, 'c' * 40, manifest), ({}, 'a' * 40, b'other')]:
            with self.assertRaises(ValueError): mod.qualified(receipt | changed, commit, 'b' * 40, data)


class FeedUpdateTests(unittest.TestCase):
    def args(self, name):
        return SimpleNamespace(target='fixture', plugin=[name], dry_run=True)

    def test_optional_runtime_uses_device_solver_without_local_pairing(self):
        row = {'name': 'example-engine', 'installed_version': '1', 'available_version': '2'}
        plan = {'names': ['example-engine', 'opl-netfleet-plugin-example'],
                'candidates': {'example-engine': '2', 'opl-netfleet-plugin-example': '3'}}
        calls = []

        def run(command, **kwargs):
            calls.append((command, kwargs))
            if 'components-get' in command[-1]:
                return json.dumps({'ok': True, 'result': {'plugin_packages': [row]}}).encode()
            self.assertIn('components_plugin_plan', command[-1])
            request = json.loads(kwargs['input'])['request']
            self.assertEqual(request['name'], 'example-engine')
            self.assertNotIn('plan', request)
            return json.dumps({'ok': True, 'result': plan}).encode()

        with patch.object(mod, 'run', side_effect=run), patch.object(mod.subprocess, 'run') as mutation:
            result = mod.feed_update(self.args('example-engine'), ['ssh', 'fixture'])
        self.assertEqual(result['plan'], plan)
        self.assertEqual(len(calls), 2)
        mutation.assert_not_called()

    def test_feed_no_change_needs_no_transaction_or_archive(self):
        row = {'name': 'opl-netfleet-plugin-example', 'installed_version': '2', 'available_version': '2'}
        with patch.object(mod, 'run', return_value=json.dumps({'ok': True, 'result': {'plugin_packages': [row]}}).encode()) as read, patch.object(mod.subprocess, 'run') as mutation:
            result = mod.feed_update(self.args(row['name']), ['ssh', 'fixture'])
        self.assertEqual(result['state'], 'no_change')
        self.assertFalse(result['device_mutation'])
        self.assertEqual(read.call_count, 1)
        mutation.assert_not_called()

    def test_solver_product_dependency_keeps_its_original_rollback_archive(self):
        with tempfile.TemporaryDirectory() as work:
            directory = Path(work)
            for name in ('opl-netfleet-0.9.7.apk', 'opl-netfleet-plugin-mihomo-0.9.10.apk'):
                (directory / name).write_bytes(name.encode())
            args = SimpleNamespace(target='fixture', plugin=['opl-netfleet-plugin-mihomo'], dry_run=False,
                                   rollback_dir=directory, output=directory / 'result.json', observe_seconds=10)
            snapshot = {'ok': True, 'result': {
                'plugin_packages': [{'name': args.plugin[0], 'installed_version': '0.9.10', 'available_version': '0.9.11'}],
                'product': {'packages': [{'name': 'opl-netfleet', 'installed_version': '0.9.7'}]}}}
            plan = {'ok': True, 'result': {'names': ['opl-netfleet-plugin-mihomo', 'opl-netfleet'],
                                            'candidates': {'opl-netfleet-plugin-mihomo': '0.9.11', 'opl-netfleet': '0.9.10'}}}
            sent = []

            def execute(command, **kwargs):
                if 'stdin' in kwargs:
                    with tarfile.open(fileobj=kwargs['stdin']) as archive:
                        sent.extend(archive.getnames())
                        self.assertEqual(archive.extractfile('old/opl-netfleet-0.9.7.apk').read(), b'opl-netfleet-0.9.7.apk')
                return SimpleNamespace(returncode=0, stdout=b'{"ok":true}\n', stderr=b'')

            with patch.object(mod, 'run', side_effect=[json.dumps(snapshot).encode(), json.dumps(plan).encode()]), \
                 patch.object(mod.subprocess, 'run', side_effect=execute):
                mod.feed_update(args, ['ssh', 'fixture'])
            self.assertIn('old/opl-netfleet-0.9.7.apk', sent)
            self.assertIn('old/opl-netfleet-plugin-mihomo-0.9.10.apk', sent)


class PackageHookTests(unittest.TestCase):
    def invoke(self, failures, phase='postinst'):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'state').write_text('0')
            (root / 'errors').write_text(''.join(f'{item or ""}\n' for item in failures))
            stub = root / 'ucode'
            stub.write_text('''#!/bin/sh
if [ "${1:-}" = -e ]; then
  sed -n 's/.*"error":"\\([^"]*\\)".*/\\1/p'
  exit 0
fi
n=$(cat "$HOOK_STATE")
printf '%s' "$((n + 1))" >"$HOOK_STATE"
idx=$((n + 1))
err=$(awk -v idx="$idx" 'NR==idx { line=$0 } END { print (NR>=idx ? line : prev) } { prev=$0 }' "$HOOK_ERRORS")
if [ -n "$err" ]; then
  printf '{"ok":false,"error":"%s"}\n' "$err"
  exit 1
fi
printf '{"ok":true,"error":null}\n'
exit 0
''')
            stub.chmod(0o755)
            sleeper = root / 'sleep'
            sleeper.write_text('#!/bin/sh\nexit 0\n')
            sleeper.chmod(0o755)
            result = subprocess.run(['sh', str(HOOK), 'subscriptions', phase],
                env={**os.environ, 'PATH': str(root) + ':' + os.environ['PATH'],
                     'HOOK_STATE': str(root / 'state'), 'HOOK_ERRORS': str(root / 'errors')},
                capture_output=True, text=True, timeout=10)
            return result, int((root / 'state').read_text())

    def test_temporary_mutation_contention_recovers(self):
        for phase in ('postinst', 'postrm'):
            result, calls = self.invoke(['mutation_busy', 'mutation_busy', None], phase)
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertEqual(calls, 3)

    def test_persistent_contention_is_bounded(self):
        result, calls = self.invoke(['mutation_busy'])
        self.assertEqual(result.returncode, 1)
        self.assertEqual(calls, 15)

    def test_real_lifecycle_failure_is_not_retried(self):
        result, calls = self.invoke(['plugin_resume_unconfirmed'])
        self.assertEqual(result.returncode, 1)
        self.assertEqual(calls, 1)

    def test_upgrade_removal_remains_noop(self):
        result = subprocess.run(['sh', str(HOOK), 'subscriptions', 'postrm', 'upgrade'],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')


if __name__ == '__main__':
    unittest.main()
