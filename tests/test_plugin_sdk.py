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

    def scaffold(self, plugin_id="link-health", kind="process", template="minimal"):
        source = self.root / plugin_id
        SDK.scaffold(plugin_id, source, "Link health", kind, template)
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
        self.assertEqual([], manifest["backends"])
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
            {"backends": ["../backend"]}, {"dependencies": ["ucode;id"]},
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

    def test_complete_scaffold_keeps_contributions_with_independent_identity(self):
        source = self.root / "link-health"
        subprocess.run([sys.executable, str(SCRIPT), "scaffold", "link-health", str(source),
                        "--kind", "service", "--template", "complete"],
                       capture_output=True, text=True, check=True)
        manifest, files = SDK.validate(source)
        self.assertEqual({"link-health.document"}, set(manifest["services"]))
        self.assertEqual("link-health.document", manifest["commands"]["link-health"]["service"])
        self.assertEqual("link-health.document", manifest["actions"]["config-set"]["service"])
        self.assertEqual({"read": "config-get", "write": "config-set"}, manifest["configuration"])
        self.assertIn(Path("resources/page.js"), files)
        self.assertIn(Path("resources/style.css"), files)
        with self.assertRaises(ValueError):
            SDK.scaffold("other", self.root / "other", None, "process", "complete")

    def test_contributions_reject_broken_references_and_resource_escape(self):
        source = self.scaffold(kind="service", template="complete")
        original = (source / "manifest.json").read_text()
        mutations = [
            lambda value: value["actions"].update(load=value["actions"]["config-set"]),
            lambda value: value["actions"]["config-set"].update(service="other.document"),
            lambda value: value["actions"]["config-set"].update(access="execute"),
            lambda value: value["configuration"].update(write="config-get"),
            lambda value: value["configuration"].update(read="missing"),
            lambda value: value["configuration"].update(read=[]),
            lambda value: value["configuration"].pop("write"),
            lambda value: value["ui"].append(value["ui"][0]),
            lambda value: value["ui"][0].update(module="resources/../control.js"),
            lambda value: value["ui"][0].update(module="https://example.invalid/page.js"),
            lambda value: value["ui"][0].update(module="resources/missing.js"),
            lambda value: value["ui"][0].update(title="hidden\npage"),
            lambda value: value["ui"][0].update(id="../note"),
            lambda value: value["ui"][0].update(script="resources/page.js"),
            lambda value: value.update(ui={"note": "resources/page.js"}),
        ]
        for index, mutate in enumerate(mutations):
            with self.subTest(index=index):
                manifest = json.loads(original)
                mutate(manifest)
                (source / "manifest.json").write_text(json.dumps(manifest))
                with self.assertRaises(ValueError):
                    SDK.validate(source)

    def test_process_plugins_can_contribute_ui_and_configuration(self):
        source = self.scaffold()
        (source / "resources").mkdir()
        (source / "resources/page.js").write_text("export function mount() {}\n")
        manifest = json.loads((source / "manifest.json").read_text())
        manifest["actions"].update({"save": "write"})
        manifest["configuration"] = {"read": "inspect", "write": "save"}
        manifest["ui"] = [{"id": "health", "title": "Health", "module": "resources/page.js"}]
        (source / "manifest.json").write_text(json.dumps(manifest))
        SDK.validate(source)
        manifest["configuration"]["write"] = "inspect"
        (source / "manifest.json").write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, "configuration"):
            SDK.validate(source)

    def test_resource_lifecycle_scope_is_explicit_and_validated(self):
        source = self.scaffold(kind="service")
        manifest = json.loads((source / "manifest.json").read_text())
        lifecycle = {"drain": {"service": "link-health.summary", "method": "drain"},
                     "resume": {"service": "link-health.summary", "method": "resume"}}
        for scope in (None, "host", "instance", "global", False):
            with self.subTest(scope=scope):
                manifest["lifecycle"] = {**lifecycle, **({"scope": scope} if scope is not None else {})}
                (source / "manifest.json").write_text(json.dumps(manifest))
                if scope in (None, "host", "instance"):
                    SDK.validate(source)
                else:
                    with self.assertRaises(ValueError):
                        SDK.validate(source)

    def test_ui_only_service_plugin_requires_real_page_payload(self):
        source = self.scaffold(kind="service", template="complete")
        manifest = json.loads((source / "manifest.json").read_text())
        manifest.update(services={}, commands={})
        del manifest["actions"]
        del manifest["configuration"]
        (source / "manifest.json").write_text(json.dumps(manifest))
        SDK.validate(source)
        manifest["ui"] = []
        (source / "manifest.json").write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, "services or UI"):
            SDK.validate(source)

    def test_complete_package_installs_private_code_and_public_resources(self):
        source = self.scaffold(kind="service", template="complete")
        package = self.root / "package"
        built = SDK.package_source(source, package, "Apache-2.0", 1)
        include = self.root / "include"
        include.mkdir()
        (include / "package.mk").touch()
        (self.root / "rules.mk").touch()
        harness = self.root / "install.mk"
        target = self.root / "installed"
        harness.write_text("all:\n\t$(call Package/opl-netfleet-plugin-link-health/install," + str(target) + ")\n")
        subprocess.run(["make", "--no-print-directory", "-f", str(package / "Makefile"),
                        "-f", str(harness), f"TOPDIR={self.root}", f"INCLUDE_DIR={include}",
                        "INSTALL_DIR=mkdir -p", "CP=cp -R", "all"],
                       cwd=package, capture_output=True, text=True, check=True)
        private = target / "usr/libexec/opl-netfleet/plugins/link-health"
        public = target / "www/luci-static/resources/netfleet/plugins/link-health" / built["revision"] / "resources"
        SDK.validate(private)
        self.assertEqual((source / "resources/page.js").read_bytes(), (public / "page.js").read_bytes())
        self.assertEqual((source / "resources/style.css").read_bytes(), (public / "style.css").read_bytes())
        self.assertFalse((public / "lib").exists())
        self.assertFalse((public / "manifest.json").exists())

    def test_resource_revision_changes_for_static_imports_as_well_as_entry_module(self):
        source = self.scaffold(kind="service", template="complete")
        helper = source / "resources/value.js"
        helper.write_text("export const value = 1;\n")
        entry = source / "resources/page.js"
        entry.write_text("import { value } from './value.js';\nexport function mount() { return value; }\n")
        first = SDK.package_source(source, self.root / "first", "Apache-2.0", 1)
        helper.write_text("export const value = 2;\n")
        second = SDK.package_source(source, self.root / "second", "Apache-2.0", 2)
        self.assertNotEqual(first["revision"], second["revision"])
        self.assertEqual((self.root / "first/files/resources/page.js").read_bytes(),
                         (self.root / "second/files/resources/page.js").read_bytes())
        self.assertIn(f"/{second['revision']}/resources", (self.root / "second/Makefile").read_text())
        self.assertNotIn(f"/{first['revision']}/resources", (self.root / "second/Makefile").read_text())

    def test_independent_repository_metadata_is_not_installable_payload(self):
        source = self.scaffold(kind="service", template="complete")
        subprocess.run(["git", "init", "--quiet", str(source)], check=True)
        (source / ".gitignore").write_text("build/\n")
        (source / ".gitattributes").write_text("* text=auto\n")
        (source / ".github/workflows").mkdir(parents=True)
        (source / ".github/workflows/build.yml").write_text("name: plugin\n")
        manifest, files = SDK.validate(source)
        self.assertFalse(any(path.parts[0] in SDK.PROJECT_METADATA for path in files))
        package = self.root / "package"
        SDK.package_source(source, package, "Apache-2.0", 1)
        self.assertEqual(manifest, SDK.validate(package / "files")[0])
        for metadata in SDK.PROJECT_METADATA:
            self.assertFalse((package / "files" / metadata).exists())

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
                self.assertIn("EXTRA_DEPENDS:=opl-netfleet-kernel (>=0.8.0)", definition)
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

    @unittest.skipUnless((os.environ.get("UCODE") or shutil.which("ucode")) and sys.platform == "linux",
                         "host-info requires Linux /proc and UCode")
    def test_service_example_executes_factories_and_declared_dependency(self):
        subprocess.run([os.environ.get("UCODE") or shutil.which("ucode"),
                        str(ROOT / "tests/plugin_sdk_service.uc"), str(SDK.SERVICE_EXAMPLE)], check=True)

    @unittest.skipUnless(os.environ.get("UCODE") or shutil.which("ucode"), "UCode runtime is not installed")
    def test_complete_example_persists_without_platform_dependencies_and_rejects_stale_writes(self):
        source = self.scaffold(kind="service", template="complete")
        data = self.root / "note.json"
        scope_module = ROOT / "openwrt/files/usr/libexec/opl-netfleet/kernel/scope.uc"
        script = f'import {{ create_scope }} from {json.dumps(str(scope_module))};\n' + '''
import * as fs from "fs";
function check(value, message) { if (!value) die(message); };
const factory = loadfile(ARGV[0])();
function instance(path) {
    const scope = create_scope();
    return { scope, service: factory({ config: path == null ? {} : { data_path: path },
        scope: scope.scope, use: () => die("no platform dependency is declared") }) };
};
const absent = instance(null);
check(absent.service.read({}).error == "not_configured", "missing storage must be explicit");
absent.scope.dispose();
const owner = instance(ARGV[1]);
const initial = owner.service.read({});
check(initial.ok && initial.result.generation == 0, "new note must be empty");
check(owner.service.inspect(["link-health"]).ok, "CLI reads the same owner");
check(!owner.service.inspect(["link-health", "extra"]).ok, "CLI rejects excess arguments");
const saved = owner.service.save({ title: "Independent note", text: "<script>literal text</script>", generation: 0 });
check(saved.ok && saved.result.generation == 1, "first write must persist");
check(owner.service.save({ title: "Stale", text: "", generation: 0 }).error == "configuration_conflict",
    "old drafts must not overwrite another save");
check(owner.service.save({ title: "", text: "bad", generation: 1 }).error == "invalid_configuration",
    "invalid config must not replace valid bytes");
owner.scope.dispose();
const reopened = instance(ARGV[1]);
const stored = reopened.service.read({});
check(stored.ok && stored.result.title == "Independent note" && stored.result.generation == 1,
    "a fresh factory must read persisted owner state");
check(reopened.service.save({ title: "Updated note", text: "fresh", generation: 1 }).ok,
    "fresh generations may update");
reopened.scope.dispose();
print("portable_note_ok\\n");
'''
        result = subprocess.run([os.environ.get("UCODE") or shutil.which("ucode"), "-e", script,
                                 str(source / "lib/document.uc"), str(data)],
                                capture_output=True, text=True)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("portable_note_ok", result.stdout)
        self.assertEqual({"title": "Updated note", "text": "fresh", "generation": 2}, json.loads(data.read_text()))
        self.assertEqual(0o600, data.stat().st_mode & 0o777)
        self.assertEqual([], list(self.root.glob("note.json.*")))

    @unittest.skipUnless(os.environ.get("UCODE") or shutil.which("ucode"), "UCode runtime is not installed")
    def test_complete_example_preserves_corrupt_or_linked_storage(self):
        source = self.scaffold(kind="service", template="complete")
        original = self.root / "original.json"
        original.write_text("not JSON\n")
        linked = self.root / "linked.json"
        linked.symlink_to(original)
        scope_module = ROOT / "openwrt/files/usr/libexec/opl-netfleet/kernel/scope.uc"
        script = f'import {{ create_scope }} from {json.dumps(str(scope_module))};\n' + '''
const factory = loadfile(ARGV[0])();
for (let path in slice(ARGV, 1)) {
    const scope = create_scope();
    const service = factory({ config: { data_path: path }, scope: scope.scope });
    if (service.read({}).error != "invalid_document") die("unsafe existing document was accepted");
    if (service.save({ title: "New", text: "", generation: 0 }).ok) die("unsafe document was overwritten");
    scope.dispose();
}
'''
        result = subprocess.run([os.environ.get("UCODE") or shutil.which("ucode"), "-e", script,
                                 str(source / "lib/document.uc"), str(original), str(linked)],
                                capture_output=True, text=True)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("not JSON\n", original.read_text())
        self.assertTrue(linked.is_symlink())


if __name__ == "__main__":
    unittest.main()
