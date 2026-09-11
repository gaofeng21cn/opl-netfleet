"""Exercise macOS source provenance without requiring platform build tools."""
import importlib.util
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(ROOT / "scripts/macos"))
spec = importlib.util.spec_from_file_location("macos_builder", ROOT / "scripts/macos/build-app.py")
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class MacOSBuildIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        self.git("init", "-q")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "user.name", "Test")
        info = self.repo / "desktop/app/Info.plist"
        info.parent.mkdir(parents=True)
        info.write_bytes(plistlib.dumps({"CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "4"}))
        (self.repo / ".gitignore").write_text(".build/\n")
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.repo), *args], text=True).strip()

    def test_delivery_records_commit_tree_and_platform_version(self):
        identity = builder.build_identity(self.repo, True)
        self.assertEqual(identity["source_commit"], self.git("rev-parse", "HEAD"))
        self.assertEqual(identity["source_tree"], self.git("rev-parse", "HEAD^{tree}"))
        self.assertEqual((identity["package_version"], identity["package_release"]), ("1.2.3", "4"))
        self.assertEqual(identity["channel"], "local")
        self.assertFalse(identity["working_tree_dirty"])
        (self.repo / ".build").mkdir()
        (self.repo / ".build/output").write_text("generated")
        builder.verify_source_unchanged(self.repo, identity)

    def test_dirty_source_is_development_only(self):
        for path in ("untracked", "desktop/app/Info.plist"):
            with self.subTest(path=path):
                target = self.repo / path
                old = target.read_bytes() if target.exists() else None
                target.write_bytes((old or b"") + b"\n")
                with self.assertRaisesRegex(RuntimeError, "clean source"):
                    builder.build_identity(self.repo, True)
                identity = builder.build_identity(self.repo)
                self.assertTrue(identity["working_tree_dirty"])
                self.assertEqual(identity["channel"], "development")
                target.write_bytes(old) if old is not None else target.unlink()

    def test_distribution_requires_clean_source(self):
        with self.assertRaisesRegex(RuntimeError, "require-clean-source"):
            builder.build_identity(self.repo, signing_identity="Developer ID Application: Fixture")
        identity = builder.build_identity(self.repo, True, "Developer ID Application: Fixture")
        self.assertEqual(identity["channel"], "distribution")
        (self.repo / "untracked").write_text("change")
        with self.assertRaisesRegex(RuntimeError, "clean source"):
            builder.build_identity(self.repo, True, "Developer ID Application: Fixture")

    def test_source_changes_during_build_are_rejected(self):
        identity = builder.build_identity(self.repo, True)
        (self.repo / "source").write_text("change")
        with self.assertRaisesRegex(RuntimeError, "Source identity changed"):
            builder.verify_source_unchanged(self.repo, identity)
        self.git("add", ".")
        self.git("commit", "-qm", "new source")
        with self.assertRaisesRegex(RuntimeError, "Source identity changed"):
            builder.verify_source_unchanged(self.repo, identity)


if __name__ == "__main__":
    unittest.main()
