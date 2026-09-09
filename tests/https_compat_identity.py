import copy
import json
import time
import importlib.util
import os
import sys
import tempfile
import subprocess
from pathlib import Path
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "openwrt/https-compat/files/usr/libexec/opl-netfleet-compat"))
import control
from policy import validate

IDENTITY = {"binding": "1" * 64, "mac": "02:00:00:00:00:01"}


class IdentityConsumer(unittest.TestCase):
    def test_finished_sync_workers_are_reaped_and_not_retained(self):
        finished = subprocess.Popen([sys.executable, "-c", "pass"])
        finished.wait(timeout=5)
        with tempfile.TemporaryDirectory() as directory:
            # Run the real background launcher; a missing owner exits immediately.
            with patch.object(control.device_identity, "_workers", [finished]), \
                    patch.object(control.device_identity, "RUN", Path(directory)), \
                    patch.object(control.device_identity, "OWNER", "/missing-test-owner"), \
                    patch.object(control.device_identity, "_next_sync", 0), \
                    patch.dict(os.environ, {"PATH": directory}):
                executable = Path(directory) / 'ucode'
                executable.write_text(f"#!{sys.executable}\npass\n")
                executable.chmod(0o700)
                control.device_identity.schedule_sync()
                workers = control.device_identity._workers
                self.assertEqual(len(workers), 1)
                self.assertIsNot(workers[0], finished)
                workers[0].wait(timeout=10)

    def test_sync_timeout_kills_descendants_and_does_not_retry_each_tick(self):
        for leader_exits in (False, True):
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory); marker = root / "child"
                executable = root / "ucode"
                child = "import time; from pathlib import Path; p=Path(" + repr(str(marker)) + "); \nwhile True: p.write_text(str(time.monotonic())); time.sleep(.02)"
                executable.write_text(f"#!{sys.executable}\nimport subprocess,time\n"
                                      f"subprocess.Popen([{sys.executable!r}, '-c', {child!r}])\n"
                                      + ("time.sleep(.05)\n" if leader_exits else "time.sleep(30)\n"))
                executable.chmod(0o700)
                with patch.object(control.device_identity, "RUN", root / "run"), \
                        patch.object(control.device_identity, "_workers", []), \
                        patch.object(control.device_identity, "_next_sync", 0), \
                        patch.dict(os.environ, {"PATH": directory}):
                    control.device_identity.schedule_sync()
                    worker = control.device_identity._workers[0]
                    try:
                        deadline = time.monotonic() + 2
                        while not marker.exists() and time.monotonic() < deadline:
                            time.sleep(.02)
                        self.assertTrue(marker.exists())
                        if leader_exits: time.sleep(.1)
                        else: worker.deadline = 0
                        control.device_identity.reap_sync()
                        stopped = marker.read_text(); time.sleep(.1)
                        self.assertEqual(stopped, marker.read_text(), 'descendant survived')
                        self.assertFalse(control.device_identity._workers)
                        self.assertFalse(list((root / "run").iterdir()))
                        for _ in range(3): control.device_identity.resolve(self.config, {}, schedule=True)
                        self.assertFalse(control.device_identity._workers, 'failed tick bypassed retry interval')
                    finally:
                        control.device_identity.reap_sync(force=True)

    def test_real_publication_revocation_expiry_and_no_reader_process(self):
        spec = importlib.util.spec_from_file_location("address_source", Path(__file__).resolve().parents[1] / "plugins/device-identity/resources/identity.py")
        owner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(owner)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence = root / "source" / "evidence.json"
            with patch.object(owner, "BASE", root / "base"), patch.object(owner, "RUN", evidence.parent), \
                    patch.object(control.device_identity, "EVIDENCE", evidence), \
                    patch.object(control.device_identity, "TRUSTED_UID", os.getuid()):
                owner.dispatch("load", {})
                config = {"enabled": True, "source": "local", "interfaces": ["eth0"]}
                state = owner.dispatch("get", {})
                owner.dispatch("configure", {"config_revision": state["config_revision"], "config": config})
                now = time.monotonic()
                row = {"mac": IDENTITY["mac"], "name": "Mac", "addresses": ["2001:db8::2"],
                       "ttl": 120, "reason": None, "address_expires": {"2001:db8::2": now + 60}}
                with patch.object(owner, "local", return_value=[row]):
                    owner.dispatch("sync", {})
                with patch.object(control.device_identity.subprocess, "Popen", side_effect=AssertionError("read spawned process")):
                    value, _ = control.device_identity.resolve(self.config)
                self.assertTrue(value["source_ready"])
                self.assertEqual(value["devices"][0]["addresses"], ["2001:db8::2"])
                raw = evidence.read_text()
                self.assertNotIn("password", raw)
                for changed in ("expired", "writable", "symlink", "invalid"):
                    evidence.write_text(raw); evidence.chmod(0o600)
                    if changed == "expired":
                        d = json.loads(raw); d["sampled_monotonic"] -= 121; evidence.write_text(json.dumps(d))
                    elif changed == "writable": evidence.chmod(0o666)
                    elif changed == "symlink":
                        target = root / "other"; target.write_text(raw); evidence.unlink(); evidence.symlink_to(target)
                    else: evidence.write_text("{}")
                    self.assertFalse(control.device_identity.published()["source_ready"], changed)
                    evidence.unlink()
                evidence.write_text(raw); evidence.chmod(0o600)
                owner.dispatch("unload", {})
                self.assertFalse(evidence.exists())
                self.assertFalse(control.device_identity.published()["source_ready"])

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
        with patch.object(control.device_identity, "schedule_sync") as call:
            control.device_identity.resolve(self.config, schedule=True)
        call.assert_not_called()


if __name__ == "__main__":
    unittest.main(verbosity=2)
