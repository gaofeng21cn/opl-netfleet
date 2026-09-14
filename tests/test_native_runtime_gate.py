import importlib.util
import hashlib
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('native_gate', Path(__file__).parents[1] / 'scripts/verify-native-runtime.py')
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class NativeRuntimeGate(unittest.TestCase):
    def test_bytecode_requires_matching_checked_source_and_payload(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            relative = Path('usr/libexec/opl-netfleet/plugins/example/main.uc')
            source = root / 'source' / relative
            installed = root / 'installed' / relative
            source.parent.mkdir(parents=True)
            installed.parent.mkdir(parents=True)
            source.write_text('return context => ({});')
            data = b'#!/usr/bin/env ucode\n\x1bucb\x01\xff'
            installed.write_bytes(data)
            entry = {'plugin': 'example', 'module': 'main.uc',
                     'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
                     'compiled_sha256': hashlib.sha256(data).hexdigest()}
            with self.assertRaisesRegex(ValueError, 'unverified'):
                gate.inspect_payload(root / 'installed')
            checked = gate.verified_bytecode(root / 'source', [entry])
            self.assertEqual(gate.inspect_payload(root / 'installed', checked), 1)
            installed.write_bytes(data + b'changed')
            with self.assertRaisesRegex(ValueError, 'unverified'):
                gate.inspect_payload(root / 'installed', checked)
            source.write_text('return context => ({changed: true});')
            with self.assertRaisesRegex(ValueError, 'source mismatch'):
                gate.verified_bytecode(root / 'source', [entry])
            source.write_text('command(["python3", "helper.py"]);')
            entry['source_sha256'] = hashlib.sha256(source.read_bytes()).hexdigest()
            with self.assertRaisesRegex(ValueError, 'caller'):
                gate.verified_bytecode(root / 'source', [entry])

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
