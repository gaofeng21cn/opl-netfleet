import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('native_gate', Path(__file__).parents[1] / 'scripts/verify-native-runtime.py')
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class NativeRuntimeGate(unittest.TestCase):
    def test_payload_only_and_native_identifiers(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'usr/libexec').mkdir(parents=True)
            (root / 'tests').mkdir()
            (root / 'tests/probe.py').write_text('test_only = True')
            script = root / 'usr/libexec/control.uc'
            script.write_text('const matches = filter(nodes, node => node.name == state.now);\n')
            self.assertEqual(gate.inspect_payload(root), 1)
            script.write_text('command(["python3", "/tmp/helper.py"]);\n')
            with self.assertRaisesRegex(ValueError, 'caller'):
                gate.inspect_payload(root)
            script.unlink()
            script = root / 'usr/libexec/control'
            script.write_text('#!/usr/bin/env python3\n')
            with self.assertRaisesRegex(ValueError, 'caller'):
                gate.inspect_payload(root)
            script.unlink()
            script.symlink_to('/missing/python3')
            with self.assertRaisesRegex(ValueError, 'link'):
                gate.inspect_payload(root)
