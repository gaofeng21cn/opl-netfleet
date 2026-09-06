"""Exercise the installed controller and procd in the disposable OpenWrt VM."""
import json
from pathlib import Path
import signal
import socket
import subprocess
import time
import unittest


MAIN = "/usr/libexec/opl-netfleet/main.uc"
CONTROL = "/usr/libexec/opl-netfleet-compat/control.py"


class Controller(unittest.TestCase):
    def call(self, action, request=None, success=True):
        command = ["ucode", MAIN, "compatibility-" + action]
        if request is not None:
            path = Path("/tmp/netfleet-controller-request.json")
            path.write_text(json.dumps({"request": request}))
            command.append(str(path))
        result = subprocess.run(command, capture_output=True, text=True, timeout=15)
        value = json.loads(result.stdout)
        self.assertEqual(value["ok"], success, value)
        return value.get("result", value)

    def health(self, probe=False):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(2)
            connection.connect("/var/run/opl-netfleet-compat/engine.sock")
            connection.sendall(b"probe\n" if probe else b"status\n")
            return json.loads(connection.makefile("rb").readline())

    def test_lifecycle(self):
        if not Path("/tmp/netfleet-compat-vm-authorized").exists():
            self.skipTest("disposable VM required")
        initial = self.call("get")
        self.assertFalse(initial["requested"])
        config = {"schema": 1, "enabled": False, "devices": [{"id": "test", "name": "Test", "addresses": ["192.0.2.2"]}],
                  "rules": [{"id": "target", "name": "Target", "devices": ["test"], "domain": "example.com", "match": "exact", "port": 443, "enabled": True, "strategy": "h2"}]}
        saved = self.call("apply", {"revision": initial["revision"], "config": config})
        ca = self.call("ca")
        self.assertNotIn("PRIVATE KEY", ca["pem"])
        self.assertEqual(saved["ca_sha256"], ca["sha256"])
        self.call("enable", {"revision": initial["revision"]}, success=False)
        enabled = self.call("enable", {"revision": saved["revision"]})
        self.assertTrue(enabled["requested"])
        self.assertFalse(enabled["intercepting"])
        deadline = time.monotonic() + 10
        while True:
            try:
                health = self.health(probe=True)
                if health.get("processing_chain"):
                    break
            except (OSError, ValueError):
                pass
            self.assertLess(time.monotonic(), deadline, "procd engine did not become healthy")
            time.sleep(0.2)
        self.assertEqual(health["active_connections"], 0)
        self.assertEqual(health["active_requests"], 0)
        process = subprocess.run(["ubus", "call", "service", "list", '{"name":"opl-netfleet-compat"}'], check=True, capture_output=True, text=True)
        self.assertTrue(json.loads(process.stdout)["opl-netfleet-compat"]["instances"]["engine"]["running"])
        verified = self.call("probe", {"revision": enabled["revision"], "operation": "trust_record", "device": "test",
                                       "report": {"ca_sha256": ca["sha256"], "system": True}})
        self.assertNotEqual(verified["revision"], enabled["revision"])
        self.assertIsNone(verified["trust"]["test"]["runtimes"]["codex_app"])
        changed = verified["config"]
        changed["devices"][0]["addresses"] = ["192.0.2.3"]
        changed = self.call("apply", {"revision": verified["revision"], "config": changed})
        self.assertNotIn("test", changed["trust"])
        revoked = self.call("probe", {"revision": changed["revision"], "operation": "trust_revoke", "device": "test"})
        self.assertNotIn("test", revoked["trust"])
        disabled = self.call("disable", {"revision": revoked["revision"]})
        self.assertFalse(disabled["requested"])
        self.assertFalse(disabled["intercepting"])
        self.assertEqual(self.call("ca")["sha256"], ca["sha256"])
        # A subsequent reconciliation must not undo a manual disable.
        subprocess.run(["python3", CONTROL, "tick"], check=True, capture_output=True, timeout=10)
        self.assertFalse(self.call("get")["requested"])
        subprocess.run(["python3", CONTROL, "drain"], check=True, capture_output=True, timeout=10)
        public_ca = Path("/etc/opl-netfleet/compatibility/ca/mitmproxy-ca-cert.pem")
        original = public_ca.read_bytes()
        try:
            public_ca.write_bytes(b"")
            state = self.call("get")
            self.assertIsNone(state["ca_sha256"])
            self.assertFalse(self.call("disable", {"revision": state["revision"]})["requested"])
        finally:
            public_ca.write_bytes(original)


if __name__ == "__main__":
    unittest.main(verbosity=2)
