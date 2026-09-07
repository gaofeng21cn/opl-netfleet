"""Exercise both installed owners in the disposable OpenWrt VM."""
import json
from pathlib import Path
import subprocess
import tempfile
import time
import unittest


MAIN = "/usr/libexec/opl-netfleet/main.uc"
MAC = "02:00:00:00:00:01"


class InstalledIdentity(unittest.TestCase):
    def test_plugin_entry_and_dynamic_trust(self):
        if not Path("/tmp/netfleet-compat-vm-authorized").exists():
            self.skipTest("disposable VM required")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def call(command, request=None):
                argv = ["ucode", MAIN, command]
                if request is not None:
                    (root / "request.json").write_text(json.dumps({"request": request}))
                    argv.append(str(root / "request.json"))
                deadline = time.monotonic() + 5
                while True:
                    result = subprocess.run(argv, capture_output=True, text=True, timeout=15)
                    data = json.loads(result.stdout)
                    if data.get("error") != "mutation_busy" or time.monotonic() >= deadline:
                        break
                    time.sleep(0.2)
                self.assertTrue(data["ok"], data)
                return data["result"]
            listed = call("plugins-list")
            plugin = next(item for item in listed["plugins"] if item["id"] == "device-identity")
            def source(action, params=None):
                return call("plugin-call" if action in ("load", "unload", "configure") else "plugin-read",
                            {"id": "device-identity", "action": action, "confirm": True,
                             "revision": plugin["revision"], "params": params or {}})
            loaded = source("load")
            self.assertTrue(loaded["loaded"])
            self.assertFalse(loaded["source_ready"])
            def command(*args):
                result = subprocess.run(args, capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 0, (args, result.stderr))
                return result.stdout
            namespace, interface, peer = "nfidentity-test", "nfidentity0", "nfidentity1"
            command("ip", "netns", "add", namespace)
            self.addCleanup(command, "ip", "netns", "del", namespace)
            command("ip", "link", "add", interface, "type", "veth", "peer", "name", peer)
            command("ip", "link", "set", peer, "netns", namespace)
            command("ip", "link", "set", interface, "address", "02:00:00:00:00:fe")
            command("ip", "-n", namespace, "link", "set", peer, "address", MAC)
            command("ip", "link", "set", interface, "up")
            command("ip", "-n", namespace, "link", "set", peer, "up")
            command("ip", "-6", "addr", "add", "fe80::fe/64", "dev", interface, "nodad")
            command("ip", "-n", namespace, "-6", "addr", "add", "fe80::1/64", "dev", peer, "nodad")
            command("ip", "-n", namespace, "-6", "addr", "add", "2001:db8::2/64", "dev", peer, "nodad")
            def candidate(ip):
                command("conntrack", "-I", "-p", "tcp", "-s", ip, "-d", "2001:db8:1::80",
                        "--sport", "45555", "--dport", "443", "--state", "ESTABLISHED", "--timeout", "120")
                self.addCleanup(subprocess.run, ["conntrack", "-D", "-f", "ipv6", "-s", ip],
                                capture_output=True, timeout=5)
            candidate("2001:db8::2")
            before_routes = command("ip", "-6", "-j", "route", "show", "table", "main")
            config = {"enabled": True, "source": "local", "interfaces": [interface]}
            source("configure", {"config_revision": loaded["config_revision"], "config": config})
            synced = source("sync")
            self.assertTrue(synced["source_ready"], synced)
            compat = call("compatibility-get")
            desired = {"schema": 1, "enabled": False, "devices": [{"id": "dynamic", "name": "Dynamic", "addresses": ["2001:db8::2"]}],
                       "rules": [{"id": "target", "name": "Target", "devices": ["dynamic"], "domain": "example.com", "match": "exact", "port": 443, "enabled": True, "strategy": "h2"}]}
            compat = call("compatibility-apply", {"revision": compat["revision"], "config": desired})
            compat = call("compatibility-probe", {"revision": compat["revision"], "operation": "trust_record", "device": "dynamic",
                                                  "report": {"ca_sha256": compat["ca_sha256"], "system": True}})
            desired["devices"][0].update(addresses=[], identity={"binding": synced["binding"], "mac": MAC})
            bound = call("compatibility-apply", {"revision": compat["revision"], "config": desired})
            self.assertTrue(bound["trust"]["dynamic"]["verified"])
            self.assertIn("2001:db8::2", bound["device_addresses"]["dynamic"])
            command("ip", "-n", namespace, "-6", "addr", "del", "2001:db8::2/64", "dev", peer)
            command("ip", "-n", namespace, "-6", "addr", "add", "2001:db8::3/64", "dev", peer, "nodad")
            candidate("2001:db8::3")
            # Advance the source's private fixture clock; no real device uses this path.
            Path("/var/run/opl-netfleet-device-identity/attempt.json").unlink()
            source("sync")
            changed = call("compatibility-get")
            self.assertIn("2001:db8::3", changed["device_addresses"]["dynamic"])
            self.assertNotIn("2001:db8::2", changed["device_addresses"]["dynamic"])
            self.assertEqual(changed["revision"], bound["revision"])
            self.assertEqual(changed["trust"], bound["trust"])
            self.assertEqual(command("ip", "-6", "-j", "route", "show", "table", "main"), before_routes)
            source("unload")
            unavailable = call("compatibility-get")
            self.assertEqual(unavailable["device_addresses"]["dynamic"], [])
            self.assertEqual(unavailable["eligible_devices"], [])
            self.assertFalse(unavailable["requested"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
