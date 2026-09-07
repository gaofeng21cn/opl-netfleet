import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/netfleet-plugin.py"
SPEC = importlib.util.spec_from_file_location("plugin_sdk", SCRIPT)
SDK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SDK)


class PluginSDKTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def scaffold(self, plugin_id="link-health", kind="process"):
        source = self.root / plugin_id
        SDK.scaffold(plugin_id, source, "Link health", kind)
        return source

    def test_cli_creates_runnable_plugin_with_independent_identity(self):
        source = self.root / "link-health"
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "scaffold", "link-health", str(source)],
            capture_output=True, text=True, check=True)
        self.assertTrue(json.loads(result.stdout)["ok"])
        manifest, files = SDK.validate(source)
        self.assertEqual("opl-netfleet-plugin-link-health", manifest["package"])
        self.assertEqual({"inspect": "read"}, manifest["actions"])
        self.assertIn('const ID = "link-health";', (source / "control").read_text())
        self.assertTrue(os.access(source / "control", os.X_OK))
        self.assertIn(Path("LICENSE"), files)
        with self.assertRaises(ValueError):
            SDK.scaffold("link-health", source, None)

    def test_validation_rejects_wrong_abi_identity_and_custom_lifecycle(self):
        source = self.scaffold()
        original = json.loads((source / "manifest.json").read_text())
        invalid = [
            {"id": "../escape"}, {"id": "Wrong-ID"}, {"api_version": True},
            {"api_version": 2}, {"package": "opl-netfleet"},
            {"actions": {"load": "write"}}, {"actions": {"inspect": "shell"}},
            {"backends": []}, {"dependencies": ["ucode;id"]},
            {"permissions": ["root"]}, {"version": "1.0\nPKG_NAME:=bad"},
        ]
        for fields in invalid:
            with self.subTest(fields=fields):
                (source / "manifest.json").write_text(json.dumps({**original, **fields}))
                with self.assertRaises(ValueError):
                    SDK.validate(source)

    def test_validation_rejects_duplicate_keys_and_linked_payload(self):
        source = self.scaffold()
        original = (source / "manifest.json").read_text()
        (source / "manifest.json").write_text(original.replace('"id":', '"id": "other", "id":', 1))
        with self.assertRaisesRegex(ValueError, "duplicate JSON key"):
            SDK.validate(source)
        (source / "manifest.json").write_text(original)
        (source / "resources").mkdir()
        (source / "resources/secret").symlink_to(source / "LICENSE")
        with self.assertRaisesRegex(ValueError, "links or special files"):
            SDK.validate(source)

    def test_package_source_copies_resources_and_preserves_executable_mode(self):
        source = self.scaffold()
        (source / "resources").mkdir()
        helper = source / "resources/helper"
        helper.write_text("#!/bin/sh\nexit 0\n")
        helper.chmod(0o755)
        destination = self.root / "package"
        result = SDK.package_source(source, destination, "Apache-2.0", 2)
        self.assertEqual("opl-netfleet-plugin-link-health", result["package"])
        self.assertEqual(helper.read_bytes(), (destination / "files/resources/helper").read_bytes())
        self.assertTrue(os.access(destination / "files/resources/helper", os.X_OK))
        SDK.validate(destination / "files")
        with self.assertRaises(ValueError):
            SDK.package_source(source, self.root / "bad", "MIT\nBAD:=1", 1)
        with self.assertRaises(ValueError):
            SDK.package_source(source, source / "package", "Apache-2.0", 1)

    def test_service_scaffold_rewrites_service_identity_and_declared_dependencies(self):
        source = self.root / "link-health"
        subprocess.run([sys.executable, str(SCRIPT), "scaffold", "link-health", str(source),
                        "--kind", "service"], text=True, capture_output=True, check=True)
        manifest, files = SDK.validate(source)
        self.assertEqual("opl-netfleet-service-plugin.v1", manifest["schema"])
        self.assertEqual({"link-health.reader": 1}, manifest["services"]["link-health.summary"]["requires"])
        self.assertEqual({"service": "link-health.summary", "method": "inspect", "access": "read"},
                         manifest["commands"]["link-health"])
        self.assertFalse((source / "control").exists())
        self.assertIn(Path("lib/reader.uc"), files)
        self.assertIn('context.use("link-health.reader")', (source / "lib/summary.uc").read_text())

    def test_service_validation_rejects_missing_modules_and_invalid_interfaces(self):
        source = self.scaffold(kind="service")
        original = (source / "manifest.json").read_text()
        mutations = [
            lambda value: value["services"]["link-health.reader"].update(module="../control.uc"),
            lambda value: value["services"]["link-health.reader"].update(module="lib/missing.uc"),
            lambda value: value["services"]["link-health.reader"].update(version=True),
            lambda value: value["services"]["link-health.summary"].update(requires={"reader": 1}),
            lambda value: value["services"]["link-health.summary"].update(requires={"link-health.reader": 0}),
            lambda value: value["commands"]["link-health"].update(service="unknown.reader"),
            lambda value: value["commands"]["link-health"].update(method="../read"),
            lambda value: value.update(lifecycle={"drain": {"service": "link-health.summary", "method": "stop"}}),
            lambda value: value.update(package_dependencies=["ucode;id"]),
        ]
        for index, mutate in enumerate(mutations):
            with self.subTest(index=index):
                manifest = json.loads(original)
                mutate(manifest)
                (source / "manifest.json").write_text(json.dumps(manifest))
                with self.assertRaises(ValueError):
                    SDK.validate(source)

    def extract_hook(self, package, name):
        include = self.root / "include"
        include.mkdir(exist_ok=True)
        (include / "package.mk").touch()
        (self.root / "rules.mk").touch()
        harness = self.root / "harness.mk"
        harness.write_text(
            "$(info __HOOK_START__)\n"
            f"$(info $(Package/opl-netfleet-plugin-link-health{('/' + name) if name else ''}))\n"
            "$(info __HOOK_END__)\nall:;@:\n")
        result = subprocess.run(
            ["make", "--no-print-directory", "-f", str(package / "Makefile"),
             "-f", str(harness), f"TOPDIR={self.root}", f"INCLUDE_DIR={include}", "all"],
            text=True, capture_output=True, check=True)
        return result.stdout.split("__HOOK_START__\n", 1)[1].split("__HOOK_END__", 1)[0]

    def test_package_dependencies_need_kernel_and_only_declared_packages(self):
        for kind in ("process", "service"):
            with self.subTest(kind=kind):
                source = self.scaffold(kind=kind)
                manifest = json.loads((source / "manifest.json").read_text())
                if kind == "service":
                    manifest["package_dependencies"] = ["ucode-mod-fs", "opl-netfleet-plugin-clock"]
                    (source / "manifest.json").write_text(json.dumps(manifest))
                package = self.root / f"package-{kind}"
                SDK.package_source(source, package, "Apache-2.0", 1)
                definition = self.extract_hook(package, "")
                dependencies = re.search(r"DEPENDS:=(.*)", definition).group(1).split()
                expected = ["+opl-netfleet-kernel"]
                expected += (["+" + name for name in manifest["package_dependencies"]] if kind == "service"
                             else ["+netfleet-plugin-api-v1", *["+" + name for name in manifest["dependencies"]]])
                self.assertEqual(set(expected), set(dependencies))
                shutil.rmtree(source)

    def test_package_hooks_delegate_to_kernel_with_phase_and_upgrade_context(self):
        source = self.scaffold(kind="service")
        package = self.root / "package"
        SDK.package_source(source, package, "Apache-2.0", 1)
        helper = self.root / "package-helper"
        helper.write_text('#!/bin/sh\nprintf "%s:%s:%s\\n" "$1" "$2" "${PKG_UPGRADE:-0}"\nexit "${PLUGIN_TEST_EXIT:-0}"\n')
        helper.chmod(0o755)
        for phase in ("preinst", "postinst", "prerm", "postrm"):
            with self.subTest(phase=phase):
                path = self.root / phase
                path.write_text(self.extract_hook(package, phase).replace(
                    "/usr/libexec/opl-netfleet-plugin-package", str(helper)))
                subprocess.run(["sh", "-n", str(path)], check=True)
                result = subprocess.run(["sh", str(path), "upgrade"], text=True, capture_output=True,
                                        env={**os.environ, "PLUGIN_TEST_EXIT": "7"})
                self.assertEqual(7, result.returncode)
                self.assertEqual(f"link-health:{phase}:1\n", result.stdout)
                offline = subprocess.run(["sh", str(path)], text=True, capture_output=True,
                                         env={**os.environ, "IPKG_INSTROOT": str(self.root)})
                self.assertEqual(0, offline.returncode)
                self.assertEqual("", offline.stdout)

    @unittest.skipUnless(os.environ.get("UCODE") or shutil.which("ucode"), "UCode runtime is not installed")
    def test_service_example_executes_factories_and_declared_dependency(self):
        subprocess.run([os.environ.get("UCODE") or shutil.which("ucode"),
                        str(ROOT / "tests/plugin_sdk_service.uc"), str(SDK.SERVICE_EXAMPLE)], check=True)


if __name__ == "__main__":
    unittest.main()
