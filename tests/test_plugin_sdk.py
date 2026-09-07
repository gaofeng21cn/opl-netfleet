import importlib.util
import json
import os
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

    def scaffold(self, plugin_id="link-health"):
        source = self.root / plugin_id
        SDK.scaffold(plugin_id, source, "Link health")
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
            {"id": "../escape"}, {"id": "zashboard"}, {"api_version": True},
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

    def extract_hook(self, package, name):
        include = self.root / "include"
        include.mkdir(exist_ok=True)
        (include / "package.mk").touch()
        (self.root / "rules.mk").touch()
        harness = self.root / "harness.mk"
        harness.write_text(
            "$(info __HOOK_START__)\n"
            f"$(info $(Package/opl-netfleet-plugin-link-health/{name}))\n"
            "$(info __HOOK_END__)\nall:;@:\n")
        result = subprocess.run(
            ["make", "--no-print-directory", "-f", str(package / "Makefile"),
             "-f", str(harness), f"TOPDIR={self.root}", f"INCLUDE_DIR={include}", "all"],
            text=True, capture_output=True, check=True)
        return result.stdout.split("__HOOK_START__\n", 1)[1].split("__HOOK_END__", 1)[0]

    def exercise_package_hook(self, installed):
        source = self.scaffold()
        package = self.root / "package"
        SDK.package_source(source, package, "Apache-2.0", 1)
        hook = self.extract_hook(package, "preinst")
        hook_path = self.root / "preinst"
        hook_path.write_text(hook)
        subprocess.run(["sh", "-n", str(hook_path)], check=True)
        helper = self.root / "ucode"
        helper.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
root = Path(os.environ["PLUGIN_TEST_ROOT"])
args = sys.argv[1:]
with (root / "calls").open("a") as log:
    log.write(("code" if args[0] == "-e" else args[1]) + "\\n")
if args[0] == "-e":
    code, argv = args[1], args[2:]
    if "const root =" in code:
        (root / "maintenance").mkdir(exist_ok=True)
    elif "const list =" in code:
        rows = json.loads(Path(argv[0]).read_text())["result"]["plugins"]
        revision = rows[0]["revision"] if rows else "absent"
        print(json.dumps({"request": {"id": argv[2], "action": "unload", "revision": revision, "confirm": True, "params": {}}}))
    else:
        result = json.loads(Path(argv[0]).read_text())
        sys.exit(0 if result.get("ok") is True and result["result"]["loaded"] is False and result["result"]["state"] == "replacing" else 1)
elif args[1] == "plugins-list":
    count_file = root / "count"
    count = int(count_file.read_text()) + 1 if count_file.exists() else 1
    count_file.write_text(str(count))
    rows = [] if os.environ["PLUGIN_TEST_ABSENT"] == "1" else [{"id": "link-health", "revision": str(count)}]
    print(json.dumps({"ok": True, "result": {"plugins": rows}}))
elif args[1] == "plugin-drain":
    request = json.loads(Path(args[2]).read_text())["request"]
    assert request["confirm"] is True and request["action"] == "unload"
    expected = "absent" if os.environ["PLUGIN_TEST_ABSENT"] == "1" else (root / "count").read_text()
    assert request["revision"] == expected
    if request["revision"] == "1": sys.exit(1)
    (root / "maintenance/replacing").touch()
    print(json.dumps({"ok": True, "result": {"loaded": False, "ready": False, "state": "replacing"}}))
else: sys.exit(2)
''')
        helper.chmod(0o755)
        result = subprocess.run(["sh", str(hook_path)], text=True, capture_output=True, timeout=8,
                                env={**os.environ, "PATH": f"{self.root}:{os.environ['PATH']}",
                                     "PLUGIN_TEST_ROOT": str(self.root),
                                     "PLUGIN_TEST_ABSENT": "0" if installed else "1"})
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("2" if installed else "1", (self.root / "count").read_text())
        self.assertTrue((self.root / "maintenance").is_dir())
        self.assertTrue((self.root / "maintenance/replacing").is_file())
        if installed:
            self.assertIn("waiting for unload/readback", result.stderr)
        expected = ["code", "plugins-list", "code", "plugin-drain"]
        if installed:
            expected += ["plugins-list", "code", "plugin-drain"]
        self.assertEqual(expected + ["code"],
                         (self.root / "calls").read_text().splitlines())

    def test_package_hook_retries_drain_with_fresh_revision_before_returning(self):
        self.exercise_package_hook(installed=True)

    def test_first_install_enters_replacing_through_the_owner(self):
        self.exercise_package_hook(installed=False)

    def test_postrm_preserves_transition_during_upgrade_and_clears_after_removal(self):
        source = self.scaffold()
        package = self.root / "package"
        SDK.package_source(source, package, "Apache-2.0", 1)
        maintenance = self.root / "maintenance/link-health"
        maintenance.mkdir(parents=True)
        (maintenance / "replacing").touch()
        hook = self.extract_hook(package, "postrm").replace(
            "/var/run/opl-netfleet-plugin-maintenance", str(self.root / "maintenance"))
        path = self.root / "postrm"
        path.write_text(hook)
        subprocess.run(["sh", str(path)], env={**os.environ, "PKG_UPGRADE": "1"}, check=True)
        self.assertTrue(maintenance.is_dir())
        self.assertTrue((maintenance / "replacing").is_file())
        subprocess.run(["sh", str(path), "remove"], env={**os.environ, "PKG_UPGRADE": "0"}, check=True)
        self.assertFalse(maintenance.exists())


if __name__ == "__main__":
    unittest.main()
