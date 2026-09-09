import copy
import os
import sys
import tempfile
from pathlib import Path
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "openwrt/https-compat/files/usr/libexec/opl-netfleet-compat"))
import control
from policy import validate

IDENTITY = {"binding": "1" * 64, "mac": "02:00:00:00:00:01"}


class IdentityConsumer(unittest.TestCase):
    def test_real_plugin_startup_budget_and_hung_source_bypass(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executable = root / "ucode"
            for delay, ready in ((1.1, True), (4, False)):
                executable.write_text(f"#!{sys.executable}\nimport time\ntime.sleep({delay})\n"
                                      "print('{\"ok\":true,\"result\":{\"source_ready\":true,\"devices\":[]}}')\n")
                executable.chmod(0o700)
                with patch.dict(os.environ, {"PATH": directory}), patch.object(control.device_identity, "RUN", root / "run"):
                    result = control.device_identity.request("resolve")
                self.assertEqual(result["source_ready"], ready)
                self.assertEqual(result["devices"], [])
                self.assertEqual(list((root / "run").iterdir()), [])

    def setUp(self):
        self.config = {"schema": 1, "enabled": True, "devices": [
            {"id": "mac", "name": "Mac", "addresses": [], "identity": IDENTITY}], "rules": [
            {"id": "target", "name": "Target", "devices": ["mac"], "domain": "example.com", "match": "exact", "port": 443, "enabled": True, "strategy": "h2"}]}
        self.trust = {"mac": {"verified": True, "ca_sha256": "ca", "identity": IDENTITY}}
        self.source = {"source_ready": True, "binding": IDENTITY["binding"], "devices": [
            {"mac": IDENTITY["mac"], "addresses": ["2001:db8::2"], "expires_in": 100}]}

    def test_new_address_preserves_trust_and_never_changes_desired_config(self):
        original = copy.deepcopy(self.config)
        first = control.effective(self.config, self.trust, "ca", self.source)
        self.assertEqual(first["devices"][0]["addresses"], ["2001:db8::2"])
        self.source["devices"][0]["addresses"] = ["2001:db8::3"]
        second = control.effective(self.config, self.trust, "ca", self.source)
        self.assertEqual(second["devices"][0]["addresses"], ["2001:db8::3"])
        self.assertEqual(self.config, original)
        self.assertIn("mac", control.verified_trust(self.config, self.trust, "ca"))
        validate(first)
        validate(second)

    def test_expired_disabled_or_rebound_source_has_no_stale_address_fallback(self):
        self.config["devices"][0]["addresses"] = ["2001:db8::1"]
        for source in ({}, {**self.source, "source_ready": False}, {**self.source, "binding": "2" * 64},
                       {**self.source, "devices": [{**self.source["devices"][0], "expires_in": 0}]}):
            result = control.effective(self.config, self.trust, "ca", source)
            self.assertEqual(result["rules"], [])
            self.assertEqual(result["devices"][0]["addresses"], [])

    def test_manual_and_dynamic_address_conflict_is_bypassed(self):
        self.config["devices"].append({"id": "other", "name": "Other", "addresses": ["2001:db8::2"]})
        effective = control.effective(self.config, self.trust, "ca", self.source)
        self.assertFalse(effective["rules"])
        self.assertFalse(effective["devices"][0]["addresses"])
        validate(effective)

    def test_changed_identity_requires_new_trust_and_duplicate_binding_rejected(self):
        changed = copy.deepcopy(self.config)
        changed["devices"][0]["identity"]["mac"] = "02:00:00:00:00:02"
        self.assertFalse(control.verified_trust(changed, self.trust, "ca"))
        duplicate = {**self.config["devices"][0], "id": "second"}
        self.config["devices"].append(duplicate)
        with self.assertRaisesRegex(ValueError, "duplicate_device_identity"):
            validate(self.config)

    def test_manual_devices_do_not_invoke_optional_plugin(self):
        self.config["devices"][0] = {"id": "mac", "name": "Mac", "addresses": ["192.0.2.2"]}
        with patch.object(control.device_identity, "request") as call:
            control.device_identity.resolve(self.config, schedule=True)
        call.assert_not_called()


if __name__ == "__main__":
    unittest.main(verbosity=2)
