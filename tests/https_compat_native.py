"""Full native gateway -> compatibility -> Mihomo -> TLS origin wire experiment."""
import asyncio
import json
from pathlib import Path
import signal
import subprocess
import sys
import time
import unittest

from https_compat_kernel import Kernel
from https_compat_controller import Controller


class Native(Kernel):
    @staticmethod
    def command(*args):
        result = subprocess.run(args, capture_output=True, text=True, timeout=15)
        if result.returncode:
            logs = subprocess.run(["logread", "-e", "opl-netfleet-core"], capture_output=True, text=True, timeout=2)
            raise AssertionError(f"{args}: {result.stdout} {result.stderr} {logs.stdout}")

    async def asyncSetUp(self):
        await super().asyncSetUp()
        await self.stop_proxy()
        self.command("ip", "addr", "del", "198.51.100.10/32", "dev", "lo")
        self.addCleanup(self.command, "ip", "addr", "add", "198.51.100.10/32", "dev", "lo")
        self.command("ip", "netns", "add", "nfcompat-origin")
        self.addCleanup(self.command, "ip", "netns", "del", "nfcompat-origin")
        self.command("ip", "link", "add", "nfcompat-up", "type", "veth", "peer", "name", "nfcompat-wan")
        self.command("ip", "link", "set", "nfcompat-wan", "netns", "nfcompat-origin")
        self.command("ip", "addr", "add", "10.78.0.1/24", "dev", "nfcompat-up")
        self.command("ip", "link", "set", "nfcompat-up", "up")
        self.command("ip", "-n", "nfcompat-origin", "addr", "add", "10.78.0.2/24", "dev", "nfcompat-wan")
        self.command("ip", "-n", "nfcompat-origin", "link", "set", "nfcompat-wan", "up")
        self.command("ip", "-n", "nfcompat-origin", "link", "set", "lo", "up")
        self.command("ip", "-n", "nfcompat-origin", "addr", "add", "198.51.100.10/32", "dev", "lo")
        self.command("ip", "route", "add", "198.51.100.10/32", "via", "10.78.0.2")
        self.addCleanup(self.command, "ip", "route", "del", "198.51.100.10/32")
        self.command("ip", "-n", "nfcompat-origin", "route", "add", "default", "via", "10.78.0.1")
        self.command("nft", "insert", "rule", "inet", "fw4", "input", "iifname", "nfcompat-up", "accept")
        self.command("nft", "insert", "rule", "inet", "fw4", "forward", "iifname", "nfcompat0", "ip", "daddr", "198.51.100.10", "reject")
        self.origin = await asyncio.create_subprocess_exec("ip", "netns", "exec", "nfcompat-origin", sys.executable,
            str(Path(__file__).with_name("https_compat_origin.py")), str(self.directory), str(self.upstream_port))
        self.addAsyncCleanup(self.stop_origin)
        self.command("ubus", "call", "network", "add_dynamic", json.dumps({"name": "nfcompat", "proto": "static", "device": "nfcompat0", "ipaddr": ["10.77.0.1/24"]}))
        self.addCleanup(self.command, "ubus", "call", "network.interface.nfcompat", "remove")
        if not Path("/etc/config/netfleet").exists():
            self.command("cp", "/usr/share/opl-netfleet/netfleet.config", "/etc/config/netfleet")
        for assignment in ("netfleet.config.enabled=1", "netfleet.config.profile=file:compat.json", "netfleet.mixin.api_secret=compat-fixture"):
            self.command("uci", "set", assignment)
        self.command("uci", "delete", "netfleet.proxy.lan_inbound_interface")
        self.command("uci", "add_list", "netfleet.proxy.lan_inbound_interface=nfcompat")
        self.command("uci", "commit", "netfleet")
        root = Path("/etc/opl-netfleet")
        (root / "backend.json").write_text('{"kind":"native-mihomo"}')
        (root / "native/profiles").mkdir(parents=True, exist_ok=True, mode=0o700)
        (root / "native/profiles/compat.json").write_text(json.dumps({"rules": ["MATCH,DIRECT"], "hosts": {"localhost": "198.51.100.10"}}))
        bundle = Path("/etc/ssl/certs/ca-certificates.crt")
        previous_bundle = bundle.read_bytes()
        self.addCleanup(bundle.write_bytes, previous_bundle)
        bundle.write_bytes(previous_bundle + (self.directory / "upstream.pem").read_bytes())
        self.command("/etc/init.d/opl-netfleet-core", "start")
        self.addCleanup(self.command, "/etc/init.d/opl-netfleet-core", "stop")
        self.owner = Controller()
        self.addCleanup(self.disable)

    def disable(self):
        status = self.owner.call("get")
        self.owner.call("disable", {"revision": status["revision"]})

    async def stop_origin(self):
        self.origin.terminate()
        await asyncio.wait_for(self.origin.wait(), 5)

    async def test_native_egress_and_management_expiry(self):
        self.assertFalse((await self.request(ca=self.directory / "upstream.pem"))["h2"])
        config = json.loads((self.directory / "config.json").read_text())
        saved = self.owner.call("apply", {"revision": self.owner.call("get")["revision"], "config": config})
        self.ca_bundle.write_bytes((self.directory / "upstream.pem").read_bytes() + self.owner.call("ca")["pem"].encode())
        self.owner.call("probe", {"revision": saved["revision"], "operation": "trust_record", "device": "mac",
                                  "report": {"system": True, "ca_sha256": saved["ca_sha256"]}})
        deadline = time.monotonic() + 85
        while True:
            state = self.owner.call("get")
            if state["intercepting"]:
                break
            self.assertLess(time.monotonic(), deadline, state)
            await asyncio.sleep(1)
        wire = await self.request()
        self.assertTrue(wire["h2"], {"wire": wire, "engine": self.owner.health()})
        self.assertFalse((await self.request(host="other.example", ca=self.directory / "upstream.pem"))["h2"])
        packages = list(Path("/tmp/compat-runtime").glob("*.apk"))
        if packages:
            held = await self.request(hold=True)
            upgrade = await asyncio.create_subprocess_exec("apk", "add", "--force-reinstall", str(packages[0]),
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
            try:
                await asyncio.sleep(2)
                self.assertIsNone(upgrade.returncode, "package replacement must wait for the live TLS connection")
                self.assertFalse(self.owner.call("get")["intercepting"])
                self.assertFalse((await self.request(ca=self.directory / "upstream.pem"))["h2"])
                output, error = await asyncio.wait_for(held.communicate(b"\n"), 6)
                self.assertEqual(held.returncode, 0, error.decode())
                self.assertTrue(json.loads(output)["h2"], "the existing connection must finish before engine replacement")
                output, error = await asyncio.wait_for(upgrade.communicate(), 30)
                self.assertEqual(upgrade.returncode, 0, error.decode())
            finally:
                for process in (held, upgrade):
                    if process.returncode is None:
                        process.kill()
                        await process.wait()
            self.owner.call("probe", {"revision": self.owner.call("get")["revision"], "operation": "recover"})
            deadline = time.monotonic() + 85
            while not self.owner.call("get")["intercepting"]:
                self.assertLess(time.monotonic(), deadline, self.owner.call("get"))
                await asyncio.sleep(1)
            self.assertTrue((await self.request())["h2"])
        rules = json.loads(subprocess.check_output(["nft", "-j", "list", "chain", "inet", "netfleet", "mangle_prerouting_lan"]))
        first = next(item["rule"] for item in rules["nftables"] if "rule" in item)
        self.command("nft", "delete", "rule", "inet", "netfleet", "mangle_prerouting_lan", "handle", str(first["handle"]))
        try:
            await asyncio.sleep(5)
            state = self.owner.call("get")
            self.assertFalse(state["intercepting"], state)
            self.assertEqual(state["reason"], "native_ownership_guard_missing")
            self.assertFalse((await self.request(ca=self.directory / "upstream.pem"))["h2"])
        finally:
            self.command("nft", "insert", "rule", "inet", "netfleet", "mangle_prerouting_lan",
                         "ct", "mark", "&", "0x01000000", "!=", "0", "counter", "return")
        await asyncio.sleep(5)
        self.assertFalse(self.owner.call("get")["intercepting"])
        deadline = time.monotonic() + 45
        while not self.owner.call("get")["intercepting"]:
            self.assertLess(time.monotonic(), deadline, self.owner.call("get"))
            await asyncio.sleep(1)
        self.assertTrue((await self.request())["h2"])
        service = json.loads(subprocess.check_output(["ubus", "call", "service", "list", '{"name":"opl-netfleet-core"}']))
        lifecycle = service["opl-netfleet-core"]["instances"]["lifecycle"]["pid"]
        engine = self.owner.health()["pid"]
        import os
        os.kill(lifecycle, signal.SIGSTOP)
        os.kill(engine, signal.SIGSTOP)
        try:
            await asyncio.sleep(11)
            self.assertFalse(self.owner.call("get")["intercepting"])
            self.assertFalse((await self.request(ca=self.directory / "upstream.pem"))["h2"])
        finally:
            os.kill(engine, signal.SIGCONT)
            os.kill(lifecycle, signal.SIGCONT)


if __name__ == "__main__":
    unittest.main(defaultTest="Native.test_native_egress_and_management_expiry", verbosity=2)
