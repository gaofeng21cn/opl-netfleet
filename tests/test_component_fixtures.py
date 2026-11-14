import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("component_fixtures", ROOT / "scripts/openwrt-vm/component-fixtures.py")
fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixtures)

class PrebuiltComponentFixtures(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.candidate = self.root / "candidate"
        self.output = self.root / "fixtures"
        self.candidate.mkdir(); self.output.mkdir()
        self.manifest = {"source_commit": "a" * 40, "source_tree": "b" * 40, "package_version": "1.2.3"}
        (self.candidate / "manifest.json").write_text(json.dumps(self.manifest))
        (self.output / "fixture.json").write_text(json.dumps({"schema_version": 1, "version": "1.2.3", **self.manifest}))
        (self.output / "old").mkdir()
        (self.output / "old/package.apk").write_bytes(b"synthetic update bytes")
        fixtures.seal_prebuilt(self.candidate, self.output)

    def test_frozen_candidate_and_complete_fixture_resources_are_reusable(self):
        fixtures.validate_prebuilt(self.candidate, self.output)
        for kind in ("changed", "extra", "symlink"):
            path = self.output / ("old/package.apk" if kind == "changed" else kind)
            if kind == "changed": path.write_bytes(b"different bytes")
            elif kind == "extra": path.write_bytes(b"undeclared resource")
            else: path.symlink_to(self.candidate / "manifest.json")
            with self.assertRaises(SystemExit): fixtures.validate_prebuilt(self.candidate, self.output)
            if kind == "changed": path.write_bytes(b"synthetic update bytes")
            else: path.unlink()
        fixtures.validate_prebuilt(self.candidate, self.output)

    def test_other_candidate_bytes_cannot_reuse_the_fixture(self):
        (self.candidate / "manifest.json").write_text(json.dumps({**self.manifest, "package_version": "1.2.4"}))
        with self.assertRaises(SystemExit): fixtures.validate_prebuilt(self.candidate, self.output)
        (self.candidate / "manifest.json").write_text(json.dumps(self.manifest))
        path = self.output / "fixture.json"
        value = json.loads(path.read_text()); value["version"] = "9.9.9"
        path.write_text(json.dumps(value))
        with self.assertRaises(SystemExit): fixtures.validate_prebuilt(self.candidate, self.output)

if __name__ == "__main__": unittest.main()
