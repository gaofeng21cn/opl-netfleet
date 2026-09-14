import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('compile_plugins', ROOT / 'openwrt/compile-plugins.py')
compiler_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compiler_module)


class PluginBytecodeTests(unittest.TestCase):
    def test_factories_load_with_relative_import_and_preserve_independent_update(self):
        executable = shutil.which(os.environ.get('NETFLEET_BYTECODE_TEST_UCODE', ''))
        if not executable:
            self.skipTest('Requires the OpenWrt SDK compiler/interpreter pair')
        libraries = Path(os.environ.get('NETFLEET_BYTECODE_TEST_LIB', '/usr/lib/ucode'))
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            plugin = root / 'sample'
            plugin.mkdir()
            (plugin / 'manifest.json').write_text(json.dumps({'id': 'sample', 'services': {
                'sample.value': {'module': 'main.uc'}}}))
            helper = plugin / 'helper.uc'
            source = "import { value } from './helper.uc'; return context => ({ get: () => value });"
            def compile_and_read(value):
                helper.write_text(f'export const value = {value};')
                (plugin / 'main.uc').write_text(source)
                rows = compiler_module.compile_plugins(root, Path(executable), libraries)
                self.assertEqual(len(rows), 1)
                result = subprocess.run([executable, '-L', str(libraries / '*.so'), '-p',
                    f'loadfile({json.dumps(str(plugin / "main.uc"))})()({{}}).get()'],
                    capture_output=True, text=True, check=True)
                self.assertEqual(result.stdout, str(value))
                return (plugin / 'main.uc').read_bytes()
            first = compile_and_read(42)
            second = compile_and_read(43)
            self.assertNotEqual(first, second)
            self.assertEqual(helper.read_text(), 'export const value = 43;')
            self.assertEqual(compile_and_read(43), second, 'same source and build path produce stable bytes')
            installed = root / 'installed.uc'
            (plugin / 'main.uc').replace(installed)
            shutil.rmtree(plugin)
            result = subprocess.run([executable, '-p', f'loadfile({json.dumps(str(installed))})()({{}}).get()'],
                                    capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout, '43')
            self.assertEqual(result.stderr, '', 'installed bytecode must not read build source paths')

    def test_rejects_module_outside_plugin_before_compilation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'sample').mkdir()
            (root / 'outside.uc').write_text('return {};')
            (root / 'sample/manifest.json').write_text(json.dumps({'id': 'sample', 'services': {
                'sample.value': {'module': '../outside.uc'}}}))
            with self.assertRaisesRegex(ValueError, 'unsafe service module'):
                compiler_module.compile_plugins(root, Path('/missing-compiler'), root)
