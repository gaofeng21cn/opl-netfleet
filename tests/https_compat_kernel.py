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
    PRESERVE_SOURCE_PORT = True
    DESTINATION = "198.51.100.10"

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
        self.command("ip", "addr", "add", "10.77.0.3/24", "dev", "nfcompat0")
        self.command("ip", "-6", "addr", "add", "2001:db8:77::1/64", "dev", "nfcompat0", "nodad")
        self.command("ip", "-n", "netfleet-compat-test", "-6", "addr", "add", "2001:db8:77::2/64", "dev", "nfcompat1", "nodad")
        self.command("ip", "-n", "netfleet-compat-test", "-6", "route", "add", "default", "via", "2001:db8:77::1")
        self.command("ip", "-6", "addr", "add", "2001:db8:88::10/128", "dev", "lo", "nodad")
        self.addCleanup(self.command, "ip", "-6", "addr", "del", "2001:db8:88::10/128", "dev", "lo")
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

    async def request(self, host="localhost", ca=None, source=None, hold=False, h2=False):
        code = """import json,socket,ssl,sys
context=ssl.create_default_context(cafile=sys.argv[2]); context.set_alpn_protocols(['h2','http/1.1'] if sys.argv[7]=='h2' else ['http/1.1'])
source=(sys.argv[5],0) if sys.argv[5] else None
with socket.create_connection((sys.argv[3],int(sys.argv[1])),timeout=3,source_address=source) as raw:
 with context.wrap_socket(raw,server_hostname=sys.argv[4]) as connection:
  if sys.argv[7]=='h2':
   print(json.dumps({'alpn':connection.selected_alpn_protocol()})); sys.exit(0)
  if sys.argv[6]=='hold':
   print('connected',flush=True)
   sys.stdin.readline()
  connection.sendall(('GET /wire HTTP/1.1\\r\\nHost: localhost:'+sys.argv[1]+'\\r\\nConnection: close\\r\\n\\r\\n').encode())
  result=b''
  while data:=connection.recv(65536): result+=data
  print(json.dumps({'h2':b'x-upstream-protocol: 2' in result.lower(),'source_port':connection.getsockname()[1],'status':result.split(b'\\r\\n')[0].decode(),'error':result[-512:].decode(errors='replace') if b'502 Bad Gateway' in result else None}))
"""
        child = await asyncio.create_subprocess_exec("ip", "netns", "exec", "netfleet-compat-test",
            sys.executable, "-c", code, str(self.upstream_port), str(ca or self.ca_bundle), self.DESTINATION, host, source or "", "hold" if hold else "", "h2" if h2 else "h1",
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        if hold:
            self.assertEqual(await asyncio.wait_for(child.stdout.readline(), 6), b"connected\n")
            return child
        out, error = await asyncio.wait_for(child.communicate(), 6)
        self.assertEqual(child.returncode, 0, error.decode())
        return json.loads(out)

    async def test_kernel_expiry_and_manual_bypass(self):
        self.assertFalse((await self.request())["h2"])
        candidates = [(self.DEVICE, self.DESTINATION + ("/128" if ":" in self.DESTINATION else "/32"), self.upstream_port)]
        gateway.renew(candidates)
        self.assertTrue(gateway.status()["intercepting"])
        response = await self.request()
        self.assertTrue(response["h2"])
        self.assertEqual(self.received[-1]["source_port"], response["source_port"])
        # The same destination IP with a different SNI must preserve the origin certificate.
        self.assertFalse((await self.request(host="other.example", ca=self.directory / "upstream.pem"))["h2"])
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


class KernelIPv6(Kernel):
    BIND = "::"
    DEVICE = "2001:db8:77::2"
    DESTINATION = "2001:db8:88::10"


if __name__ == "__main__":
    unittest.main(defaultTest=["Kernel.test_kernel_expiry_and_manual_bypass", "KernelIPv6.test_kernel_expiry_and_manual_bypass"], verbosity=2)
