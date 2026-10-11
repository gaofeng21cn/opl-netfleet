import importlib.util
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "delivery_preflight", ROOT / "scripts/netfleet-delivery-preflight.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class DeliveryPreflightTests(unittest.TestCase):
    def test_source_contract_binds_components_to_platform_paths(self):
        result = MODULE.source_contract(MODULE.git("rev-parse", "HEAD"))
        self.assertEqual(
            result,
            {
                "platform_paths_provider": True,
                "components_path_dependency": True,
                "path_shadowing": False,
            },
        )

    def test_fixture_inventory_rejects_editor_files_and_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "cycle.json").write_text("{}\n")
            (root / "._cycle.json").write_text("temporary\n")
            with self.assertRaisesRegex(ValueError, "temporary"):
                MODULE.fixture_inventory(root)
            (root / "._cycle.json").unlink()
            (root / "link").symlink_to(root / "cycle.json")
            with self.assertRaisesRegex(ValueError, "symlink"):
                MODULE.fixture_inventory(root)

    def test_test_ref_path_policy_is_narrow(self):
        self.assertTrue(MODULE.is_test_only_path("scripts/openwrt-vm/guest-qualify.sh"))
        self.assertTrue(MODULE.is_test_only_path("tests/fixture.uc"))
        self.assertFalse(MODULE.is_test_only_path("openwrt/files/usr/libexec/opl-netfleet/main.uc"))


if __name__ == "__main__":
    unittest.main()
