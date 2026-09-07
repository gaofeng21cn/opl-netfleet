import importlib.util
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("source_identity", ROOT / "plugins/device-identity/resources/identity.py")
identity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(identity)
MAC = "02:00:00:00:00:01"
NEW = "2001:db8::1234"


class Source(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        root = Path(self.directory.name)
        for name in ("BASE", "RUN"):
            patcher = patch.object(identity, name, root / name)
            patcher.start()
            self.addCleanup(patcher.stop)
        identity.dispatch("load", {})

    def config(self):
        return {"enabled": True, "source": "unifi", "endpoint": "https://localhost", "site": "default",
                "username": "viewer", "password": "test-secret", "certificate_sha256": ""}

    def save(self, config):
        state = identity.dispatch("get", {})
        return identity.dispatch("configure", {"config_revision": state["config_revision"], "config": config})

    def test_real_tls_login_ipv6_and_pinned_certificate_before_credentials(self):
        root = Path(self.directory.name)
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                        "-subj", "/CN=localhost", "-keyout", str(root / "key"), "-out", str(root / "cert")],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        seen = []
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                seen.append((self.command, self.path))
                data = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                self.send_response(200 if data == {"username": "viewer", "password": "test-secret", "rememberMe": False} else 401)
                self.send_header("Set-Cookie", "TOKEN=test-session; HttpOnly; Secure")
                self.end_headers()

            def do_GET(self):
                seen.append((self.command, self.path))
                self.send_response(200 if self.headers.get("Cookie") == "TOKEN=test-session" else 401)
                self.end_headers()
                self.wfile.write(json.dumps([{"mac": MAC, "hostname": "Mac", "ip": "192.0.2.2",
                                             "ipv6_address": [NEW], "last_seen": int(time.time())}]).encode())
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(root / "cert", root / "key")
        server.socket = context.wrap_socket(server.socket, server_side=True)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        pin = identity.hashlib.sha256(ssl.PEM_cert_to_DER_cert((root / "cert").read_text())).hexdigest()
        config = {**self.config(), "endpoint": f"https://127.0.0.1:{server.server_port}", "certificate_sha256": pin}
        self.save(config)
        result = identity.dispatch("sync", {})
        self.assertTrue(result["source_ready"], result)
        self.assertEqual(result["devices"][0]["addresses"], ["192.0.2.2", NEW])
        self.assertEqual(seen[0], ("POST", "/api/auth/login"))
        self.assertIn("/clients/active?", seen[1][1])
        self.assertNotIn("test-secret", json.dumps(result))
        self.assertNotIn("test-session", json.dumps(result))
        before = list(seen)
        self.save({**config, "certificate_sha256": "0" * 64})
        self.assertEqual(identity.dispatch("sync", {})["reason"], "controller_certificate_changed")
        self.assertEqual(seen, before)
        self.save({**config, "certificate_sha256": ""})
        self.assertEqual(identity.dispatch("sync", {})["reason"], "controller_certificate_untrusted")
        self.assertEqual(seen, before)

    def test_address_changes_failure_expiry_and_disable(self):
        config = self.config()
        state = self.save(config)
        row = {"mac": MAC, "name": "Mac", "addresses": [NEW], "ttl": 120, "reason": None}
        now = time.monotonic()
        with patch.object(identity, "unifi", return_value=[row]), patch.object(identity.time, "monotonic", return_value=now):
            first = identity.sync(config)
        self.assertEqual(first["config_revision"], state["config_revision"])
        row = {**row, "addresses": ["2001:db8::5678"]}
        with patch.object(identity, "unifi", return_value=[row]), patch.object(identity.time, "monotonic", return_value=now + 30):
            changed = identity.sync(config)
        self.assertEqual(changed["devices"][0]["addresses"], row["addresses"])
        with patch.object(identity, "unifi", side_effect=TimeoutError()), patch.object(identity.time, "monotonic", return_value=now + 60):
            failed = identity.sync(config)
        self.assertEqual(failed["reason"], "controller_timeout")
        with patch.object(identity.time, "monotonic", return_value=now + 151):
            expired = identity.status(config)
        self.assertFalse(expired["source_ready"])
        self.assertEqual(expired["devices"][0]["addresses"], [])
        disabled = self.save({**config, "enabled": False})
        self.assertFalse(disabled["source_ready"])
        self.assertTrue(disabled["loaded"])
        identity.dispatch("unload", {})
        self.assertFalse(identity.dispatch("resolve", {})["loaded"])

    def test_snapshot_requires_current_identity_and_complete_ipv6(self):
        now = time.time()
        rows = [{"mac": MAC, "ipv6_address": [NEW], "last_seen": now - 121},
                {"mac": "02:00:00:00:00:02", "ip": "192.0.2.3", "last_seen": now},
                {"mac": "02:00:00:00:00:03", "ipv6_address": [NEW], "last_seen": now + 100}]
        with patch.object(identity, "request", side_effect=[(200, b"", "TOKEN=test"), (200, json.dumps(rows).encode(), "")]):
            result = identity.unifi(self.config(), now)
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["addresses"], [])
        self.assertEqual(result[0]["reason"], "controller_ipv6_data_missing")

    def test_conflicting_and_duplicate_device_evidence(self):
        row = {"mac": MAC, "name": "Mac", "addresses": [NEW], "ttl": 120, "reason": None}
        for other in (row, {**row, "mac": "02:00:00:00:00:02"}):
            self.assertTrue(all(not item["addresses"] for item in identity.unique_devices([row, other])))

    def test_config_revision_and_credential_destination_binding(self):
        config = self.config()
        state = self.save(config)
        public = state["config"]
        self.assertNotIn("password", public)
        self.assertNotEqual(state["config_revision"], identity.digest(config))
        self.assertEqual(state["config_revision"], identity.dispatch("get", {})["config_revision"])
        self.assertEqual(identity.validate(public, config), config)
        with self.assertRaisesRegex(ValueError, "controller_password_required"):
            identity.validate({**public, "endpoint": "https://other.example"}, config)
        with self.assertRaisesRegex(ValueError, "identity_revision_conflict"):
            identity.dispatch("configure", {"config_revision": "stale", "config": config})
        self.assertEqual(identity.binding(config), identity.binding({**config, "password": "rotated"}))
        self.assertNotEqual(identity.binding(config), identity.binding({**config, "site": "changed"}))

    def test_local_neighbour_cannot_assign_the_next_hop_to_a_client(self):
        config = {"source": "local", "enabled": True, "interfaces": ["br-lan"]}
        neighbour = {"dst": "192.0.2.2", "lladdr": MAC, "dev": "br-lan", "state": ["REACHABLE"]}
        link = {"ifname": "br-lan", "flags": ["UP"], "address": "02:00:00:00:00:fe",
                "addr_info": [{"family": "inet6", "scope": "link", "local": "fe80::fe"}]}
        for route in ({"dev": "br-lan", "gateway": "2001:db8::1"}, {"dev": "other"}):
            with patch.object(identity, "ip_command", side_effect=[[neighbour], [route], [link]]), \
                    patch.object(identity, "connection_addresses", return_value=[]):
                self.assertEqual(identity.local(config, time.time()), [])
        with patch.object(identity, "ip_command", side_effect=[[neighbour], [{"dev": "br-lan"}], [link]]), \
                patch.object(identity, "connection_addresses", return_value=[]):
            self.assertEqual(identity.local(config, time.time())[0]["addresses"], ["192.0.2.2"])

    def test_local_candidates_need_fresh_on_link_confirmation(self):
        config = {"source": "local", "enabled": True, "interfaces": ["observe0"]}
        self.save(config)
        link = {"ifname": "observe0", "flags": ["UP"], "address": "02:00:00:00:00:fe",
                "addr_info": [{"family": "inet6", "scope": "link", "local": "fe80::fe"}]}
        def addresses(confirmed):
            with patch.object(identity, "ip_command", side_effect=[[], [link]]), \
                    patch.object(identity, "connection_addresses", return_value=[NEW, "2001:db8::99"]), \
                    patch.object(identity, "observe", return_value=confirmed) as observed:
                result = identity.sync(config, force=True)
                self.assertEqual(observed.call_args.args[0], [("observe0", "fe80::fe", "02:00:00:00:00:fe")])
                return result
        confirmed = addresses([(NEW, MAC)])
        self.assertEqual(confirmed["devices"][0]["addresses"], [NEW])
        conflict = addresses([(NEW, MAC), (NEW, "02:00:00:00:00:02")])
        self.assertTrue(all(not row["addresses"] for row in conflict["devices"]))
        self.assertEqual(addresses([])["devices"], [])

    def test_conntrack_candidates_only_use_original_ipv6_sources(self):
        xml = b'<conntrack><flow><meta direction="original"><layer3><src>2001:db8::2</src></layer3></meta><meta direction="reply"><layer3><src>2001:db8::80</src></layer3></meta></flow></conntrack>'
        with patch.object(identity.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, xml)):
            self.assertEqual(identity.connection_addresses(), ["2001:db8::2"])

    def test_sample_rotation_keeps_original_address_expiry(self):
        config = {"source": "local", "enabled": True, "interfaces": ["observe0"]}
        self.save(config)
        link = {"ifname": "observe0", "flags": ["UP"], "address": "02:00:00:00:00:fe",
                "addr_info": [{"family": "inet6", "scope": "link", "local": "fe80::fe"}]}
        candidates = [f"2001:db8::{i:x}" for i in range(1, 100)]
        watched = sorted(candidates)[0]
        with patch.object(identity, "ip_command", side_effect=lambda *args: [] if args[0] == "neigh" else [link]), \
                patch.object(identity, "connection_addresses", return_value=candidates):
            with patch.object(identity.time, "monotonic", return_value=1000), \
                    patch.object(identity, "observe", return_value=[(watched, MAC)]):
                first = identity.sync(config, force=True)
            self.assertEqual(first["devices"][0]["expires_in"], 120)
            # Keep the watched address outside this batch; no new proof may extend its TTL.
            identity.atomic(identity.RUN / "cursor.json", 1)
            with patch.object(identity.time, "monotonic", return_value=1030), \
                    patch.object(identity, "observe", return_value=[]):
                later = identity.sync(config, force=True)
            self.assertEqual(later["devices"][0]["addresses"], [watched])
            self.assertEqual(later["devices"][0]["expires_in"], 90)
            with patch.object(identity.time, "monotonic", return_value=1121):
                self.assertEqual(identity.status(config)["devices"][0]["addresses"], [])

    def test_mixed_address_expiry_does_not_withdraw_the_whole_device(self):
        config = {"source": "local", "enabled": True, "interfaces": ["observe0"]}
        self.save(config)
        identity.atomic(identity.RUN / "cache.json", {"revision": identity.revision(config), "monotonic": 1000,
            "devices": [{"mac": MAC, "name": "Mac", "ttl": 120, "reason": None,
                         "addresses": [NEW, "2001:db8::2"], "address_expires": {NEW: 1030.5, "2001:db8::2": 1120}}]})
        with patch.object(identity.time, "monotonic", return_value=1030):
            current = identity.status(config)["devices"][0]
            self.assertEqual(current["expires_in"], 1)
            self.assertEqual(len(current["addresses"]), 2)
        with patch.object(identity.time, "monotonic", return_value=1031):
            current = identity.status(config)["devices"][0]
            self.assertEqual(current["addresses"], ["2001:db8::2"])
            self.assertEqual(current["expires_in"], 89)

    def test_neighbor_reply_validation(self):
        from scapy.layers.inet6 import IPv6, ICMPv6ND_NA, ICMPv6NDOptDstLLAddr
        from scapy.layers.l2 import Ether
        from neighbor import advertisement

        source, destination = "fe80::fe", "02:00:00:00:00:fe"
        packet = Ether(src=MAC, dst=destination) / IPv6(src="fe80::1", dst=source, hlim=255) / \
                 ICMPv6ND_NA(tgt=NEW, S=1, R=0) / ICMPv6NDOptDstLLAddr(lladdr=MAC)
        self.assertEqual(advertisement(Ether(bytes(packet)), [NEW], destination, source), (NEW, MAC))
        for layer, field, value in ((IPv6, "hlim", 64), (IPv6, "dst", "fe80::99"),
                                    (ICMPv6ND_NA, "tgt", "2001:db8::99"), (ICMPv6ND_NA, "S", 0),
                                    (ICMPv6ND_NA, "R", 1), (ICMPv6ND_NA, "cksum", 1),
                                    (ICMPv6NDOptDstLLAddr, "lladdr", destination), (Ether, "dst", MAC)):
            changed = packet.copy()
            setattr(changed[layer], field, value)
            self.assertIsNone(advertisement(Ether(bytes(changed)), [NEW], destination, source), (layer, field))


if __name__ == "__main__":
    unittest.main(verbosity=2)
