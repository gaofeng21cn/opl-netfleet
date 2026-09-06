"""Real nftables lease and transparent TLS checks, restricted to the disposable QEMU lane."""

import asyncio
import json
from pathlib import Path
import signal
import subprocess
import sys
import unittest

from https_compat_protocol import Protocol

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "openwrt/https-compat/files/usr/libexec/opl-netfleet-compat"))
import gateway


class Kernel(Protocol):
    BIND = "0.0.0.0"
    DEVICE = "10.77.0.2"
    MODE = "transparent"
    PROXY_PORT = gateway.PORT

    async def asyncSetUp(self):
        if not Path("/tmp/netfleet-compat-vm-authorized").exists():
            self.skipTest("requires disposable OpenWrt VM authorization")
        self.command("ip", "netns", "add", "netfleet-compat-test")
        self.addCleanup(self.command, "ip", "netns", "del", "netfleet-compat-test")
        self.command("ip", "link", "add", "nfcompat0", "type", "veth", "peer", "name", "nfcompat1")
        self.command("ip", "link", "set", "nfcompat1", "netns", "netfleet-compat-test")
        self.command("ip", "addr", "add", "10.77.0.1/24", "dev", "nfcompat0")
        self.command("ip", "link", "set", "nfcompat0", "up")
        self.command("ip", "-n", "netfleet-compat-test", "addr", "add", "10.77.0.2/24", "dev", "nfcompat1")
        self.command("ip", "-n", "netfleet-compat-test", "link", "set", "nfcompat1", "up")
        self.command("ip", "-n", "netfleet-compat-test", "route", "add", "default", "via", "10.77.0.1")
        self.command("ip", "addr", "add", "198.51.100.10/32", "dev", "lo")
        self.addCleanup(self.command, "ip", "addr", "del", "198.51.100.10/32", "dev", "lo")
        # Only this isolated veth is admitted to the QEMU router's input policy.
        self.command("nft", "insert", "rule", "inet", "fw4", "input", "iifname", "nfcompat0", "accept")
        await super().asyncSetUp()
        self.ca_bundle = self.directory / "client-ca.pem"
        self.ca_bundle.write_bytes((self.directory / "upstream.pem").read_bytes() + (self.directory / "ca/mitmproxy-ca-cert.pem").read_bytes())
        gateway.prepare(["nfcompat0"])
        self.addCleanup(gateway.remove)

    @staticmethod
    def command(*args):
        subprocess.run(args, check=True, capture_output=True, timeout=5)

    async def request(self):
        code = """import json,socket,ssl,sys
context=ssl.create_default_context(cafile=sys.argv[2]); context.set_alpn_protocols(['http/1.1'])
with socket.create_connection(('198.51.100.10',int(sys.argv[1])),timeout=3) as raw:
 with context.wrap_socket(raw,server_hostname='localhost') as connection:
  connection.sendall(('GET /wire HTTP/1.1\\r\\nHost: localhost:'+sys.argv[1]+'\\r\\nConnection: close\\r\\n\\r\\n').encode())
  result=b''
  while data:=connection.recv(65536): result+=data
  print(json.dumps({'h2':b'x-upstream-protocol: 2' in result.lower(),'status':result.split(b'\\r\\n')[0].decode()}))
"""
        child = await asyncio.create_subprocess_exec("ip", "netns", "exec", "netfleet-compat-test",
            sys.executable, "-c", code, str(self.upstream_port), str(self.ca_bundle),
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        out, error = await asyncio.wait_for(child.communicate(), 6)
        self.assertEqual(child.returncode, 0, error.decode())
        return json.loads(out)

    async def test_kernel_expiry_and_manual_bypass(self):
        self.assertFalse((await self.request())["h2"])
        candidates = [(self.DEVICE, "198.51.100.10/32", self.upstream_port)]
        gateway.renew(candidates)
        self.assertTrue(gateway.status()["intercepting"])
        self.assertTrue((await self.request())["h2"])
        gateway.bypass()
        self.assertFalse(gateway.status()["intercepting"])
        self.assertFalse((await self.request())["h2"])
        gateway.renew(candidates)
        self.proxy.send_signal(signal.SIGSTOP)
        await asyncio.sleep(10.5)
        self.assertFalse(gateway.status()["intercepting"])
        self.assertFalse((await self.request())["h2"])
        self.proxy.send_signal(signal.SIGCONT)
        gateway.renew(candidates)
        self.assertTrue((await self.request())["h2"])
        self.proxy.kill()
        await self.proxy.wait()
        await asyncio.sleep(10.5)
        self.assertFalse(gateway.status()["intercepting"])
        self.assertFalse((await self.request())["h2"])


if __name__ == "__main__":
    unittest.main(defaultTest="Kernel.test_kernel_expiry_and_manual_bypass", verbosity=2)
