"""Exercise both installed owners in the disposable OpenWrt VM."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import hashlib
import json
from pathlib import Path
import ssl
import subprocess
import tempfile
import threading
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
                result = subprocess.run(argv, capture_output=True, text=True, timeout=15)
                data = json.loads(result.stdout)
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
            subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                            "-subj", "/CN=localhost", "-keyout", str(root / "key"), "-out", str(root / "cert")],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            addresses = ["2001:db8::2"]
            class Handler(BaseHTTPRequestHandler):
                def log_message(self, *args):
                    pass

                def do_POST(self):
                    self.rfile.read(int(self.headers["Content-Length"]))
                    self.send_response(200)
                    self.send_header("Set-Cookie", "TOKEN=fixture; Secure")
                    self.end_headers()

                def do_GET(self):
                    self.send_response(200)
                    self.end_headers()
                    self.wfile.write(json.dumps([{"mac": MAC, "hostname": "Mac", "ip": "192.0.2.2",
                                                 "ipv6_address": addresses, "last_seen": time.time()}]).encode())
            server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            tls.load_cert_chain(root / "cert", root / "key")
            server.socket = tls.wrap_socket(server.socket, server_side=True)
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            self.addCleanup(server.server_close)
            self.addCleanup(server.shutdown)
            pin = hashlib.sha256(ssl.PEM_cert_to_DER_cert((root / "cert").read_text())).hexdigest()
            config = {"enabled": True, "source": "unifi", "endpoint": f"https://127.0.0.1:{server.server_port}",
                      "site": "default", "username": "viewer", "password": "fixture", "certificate_sha256": pin}
            configured = source("configure", {"config_revision": loaded["config_revision"], "config": config})
            synced = source("sync")
            self.assertTrue(synced["source_ready"], synced)
            compat = call("compatibility-get")
            desired = {"schema": 1, "enabled": False, "devices": [{"id": "dynamic", "name": "Dynamic", "addresses": ["192.0.2.2"]}],
                       "rules": [{"id": "target", "name": "Target", "devices": ["dynamic"], "domain": "example.com", "match": "exact", "port": 443, "enabled": True, "strategy": "h2"}]}
            compat = call("compatibility-apply", {"revision": compat["revision"], "config": desired})
            compat = call("compatibility-probe", {"revision": compat["revision"], "operation": "trust_record", "device": "dynamic",
                                                  "report": {"ca_sha256": compat["ca_sha256"], "system": True}})
            desired["devices"][0].update(addresses=[], identity={"binding": synced["binding"], "mac": MAC})
            bound = call("compatibility-apply", {"revision": compat["revision"], "config": desired})
            self.assertTrue(bound["trust"]["dynamic"]["verified"])
            self.assertIn("2001:db8::2", bound["device_addresses"]["dynamic"])
            addresses[:] = ["2001:db8::3"]
            # Advance the source's private fixture clock; no real device uses this path.
            Path("/var/run/opl-netfleet-device-identity/attempt.json").unlink()
            source("sync")
            changed = call("compatibility-get")
            self.assertIn("2001:db8::3", changed["device_addresses"]["dynamic"])
            self.assertNotIn("2001:db8::2", changed["device_addresses"]["dynamic"])
            self.assertEqual(changed["revision"], bound["revision"])
            self.assertEqual(changed["trust"], bound["trust"])
            source("unload")
            unavailable = call("compatibility-get")
            self.assertEqual(unavailable["device_addresses"]["dynamic"], [])
            self.assertEqual(unavailable["eligible_devices"], [])
            self.assertFalse(unavailable["requested"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
