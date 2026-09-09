"""Exercise the shipped in-process health reader against real UDP sockets."""
import os
from pathlib import Path
import shutil
import socket
import subprocess
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / "openwrt/files/usr/libexec/opl-netfleet/plugins/mihomo/lib/health.uc"
UCODE = os.environ.get("UCODE") or shutil.which("ucode")


@unittest.skipUnless(UCODE, "ucode required (also exercised by OpenWrt qualification)")
class BackendHealthTests(unittest.TestCase):
    def run_ucode(self, body):
        args = [UCODE]
        if os.environ.get("UCODE_LIB"):
            args += ["-L", os.environ["UCODE_LIB"]]
        result = subprocess.run(args + ["-e", f'import * as h from "{MODULE}"; ' + body],
                                text=True, capture_output=True, timeout=4)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def probe(self, response):
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as server:
            server.bind(("127.0.0.1", 0))
            server.settimeout(3)
            requests = []

            def serve():
                query, address = server.recvfrom(512)
                requests.append(query)
                reply = response(query)
                if reply is not None:
                    server.sendto(reply, address)

            thread = threading.Thread(target=serve)
            thread.start()
            started = time.monotonic()
            try:
                result = self.run_ucode(f'print(h.dns_ready({server.getsockname()[1]}));')
            finally:
                thread.join(timeout=4)
            elapsed = time.monotonic() - started
            self.assertEqual(len(requests), 1)
            self.assertEqual(requests[0][12:], b'\x06health\x0copl-netfleet\x07invalid\0\0\x10\0\x01')
            return result, elapsed

    def test_local_nxdomain_is_healthy(self):
        result, _ = self.probe(lambda q: q[:2] + b'\x85\x83' + q[4:])
        self.assertEqual(result, "true")

    def test_listener_without_response_times_out(self):
        result, elapsed = self.probe(lambda q: None)
        self.assertEqual(result, "false")
        self.assertGreaterEqual(elapsed, 0.9)
        self.assertLess(elapsed, 2.5)

    def test_unrelated_or_invalid_reply_is_not_health(self):
        replies = [lambda q: q, lambda q: b'XX\x85\x83' + q[4:],
                   lambda q: q[:2] + b'\x85\x82' + q[4:],
                   lambda q: q[:2] + b'\x87\x83' + q[4:],
                   lambda q: q[:2] + b'\x85\x83' + q[4:-1],
                   lambda q: q[:2] + b'\x85\x83' + q[4:] + b'extra']
        for reply in replies:
            with self.subTest(reply=reply):
                self.assertEqual(self.probe(reply)[0], "false")

    def test_wildcards_require_listening_state_and_full_address(self):
        self.assertEqual(self.run_ucode('''
            const p = h.parse_listeners({
              tcp: "0: 00000000:1ED4 00000000:0000 0A\\n1: 0100007F:2382 00000000:0000 0A\\n2: 00000000:1ED5 00000000:0000 01",
              tcp6: "0: 00000000000000000000000000000000:2382 00000000000000000000000000000000:0000 0A",
              udp: "0: 00000000:041D 00000000:0000 07\\n1: 00000000:1ED4 0100007F:1234 01",
              udp6: null
            });
            print(p.tcp[7892] == true && p.tcp[9090] == true && p.tcp[7893] == null &&
                  p.udp[1053] == true && p.udp[7892] == null);
        '''), "true")
