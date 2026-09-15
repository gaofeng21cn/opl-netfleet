"""Exercise the APK hook's retry boundary without a device or network."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HOOK = ROOT / 'openwrt/files/usr/libexec/opl-netfleet-plugin-package'


class PackageHookTests(unittest.TestCase):
    def invoke(self, failures, phase='postinst'):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'state').write_text('0')
            stub = root / 'ucode'
            stub.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
if sys.argv[1] == '-e':
    try: print(json.load(sys.stdin).get('error', ''), end='')
    except ValueError: pass
    sys.exit(0)
p = pathlib.Path(os.environ['HOOK_STATE'])
n = int(p.read_text()); p.write_text(str(n + 1))
errors = json.loads(os.environ['HOOK_ERRORS'])
error = errors[min(n, len(errors)-1)] if errors else None
print(json.dumps({'ok': not bool(error), 'error': error}))
sys.exit(1 if error else 0)
''')
            stub.chmod(0o755)
            sleeper = root / 'sleep'
            sleeper.write_text('#!/bin/sh\nexit 0\n')
            sleeper.chmod(0o755)
            result = subprocess.run(['sh', str(HOOK), 'subscriptions', phase],
                env={**os.environ, 'PATH': str(root) + ':' + os.environ['PATH'],
                     'HOOK_STATE': str(root/'state'), 'HOOK_ERRORS': json.dumps(failures)},
                capture_output=True, text=True, timeout=10)
            return result, int((root/'state').read_text())

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
