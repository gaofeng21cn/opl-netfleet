"""Full native gateway -> compatibility -> Mihomo -> TLS origin wire experiment."""
import asyncio
import ipaddress
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
    HOST = "wire.example"

    @staticmethod
    def command(*args):
        result = subprocess.run(args, capture_output=True, text=True, timeout=15)
        if result.returncode:
            logs = subprocess.run(["logread", "-e", "opl-netfleet-core"], capture_output=True, text=True, timeout=2)
            raise AssertionError(f"{args}: {result.stdout} {result.stderr} {logs.stdout}")

    async def asyncSetUp(self):
        await super().asyncSetUp()
        await self.stop_proxy()
        # Port 443 in the router namespace belongs to LuCI. The wire origin
        # owns 443 only inside its isolated namespace.
        self.upstream_port = 443
        policy_path = self.directory / "config.json"
        policy = json.loads(policy_path.read_text())
        policy["rules"][0].update(domain=self.HOST, port=443)
        policy_path.write_text(json.dumps(policy))
        self.command("ip", "addr", "del", "198.51.100.10/32", "dev", "lo")
        self.addCleanup(self.command, "ip", "addr", "add", "198.51.100.10/32", "dev", "lo")
        self.command("ip", "netns", "add", "nfcompat-origin")
        self.addCleanup(self.command, "ip", "netns", "del", "nfcompat-origin")
        self.command("ip", "link", "add", "nfcompat-up", "type", "veth", "peer", "name", "nfcompat-wan")
        self.command("ip", "link", "set", "nfcompat-wan", "netns", "nfcompat-origin")
        self.command("ip", "addr", "add", "10.78.0.1/24", "dev", "nfcompat-up")
        self.command("ip", "link", "set", "nfcompat-up", "up")
        self.command("ip", "-6", "addr", "add", "2001:db8:78::1/64", "dev", "nfcompat-up", "nodad")
        self.command("ip", "-n", "nfcompat-origin", "addr", "add", "10.78.0.2/24", "dev", "nfcompat-wan")
        self.command("ip", "-n", "nfcompat-origin", "link", "set", "nfcompat-wan", "up")
        self.command("ip", "-n", "nfcompat-origin", "-6", "addr", "add", "2001:db8:78::2/64", "dev", "nfcompat-wan", "nodad")
        self.command("ip", "-6", "addr", "del", "2001:db8:88::10/128", "dev", "lo")
        self.addCleanup(self.command, "ip", "-6", "addr", "add", "2001:db8:88::10/128", "dev", "lo", "nodad")
        self.command("ip", "-n", "nfcompat-origin", "-6", "addr", "add", "2001:db8:88::10/128", "dev", "nfcompat-wan", "nodad")
        self.command("ip", "-6", "route", "add", "2001:db8:88::10/128", "via", "2001:db8:78::2")
        self.addCleanup(self.command, "ip", "-6", "route", "del", "2001:db8:88::10/128")
        self.command("ip", "-n", "nfcompat-origin", "-6", "route", "add", "default", "via", "2001:db8:78::1")
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
        self.command("ubus", "call", "network", "add_dynamic", json.dumps({"name": "nfcompat", "proto": "static", "device": "nfcompat0", "ipaddr": ["10.77.0.1/24"], "ip6addr": ["2001:db8:77::1/64"]}))
        self.addCleanup(self.command, "ubus", "call", "network.interface.nfcompat", "remove")
        # Documentation prefixes are classified as private and miss mitmproxy's
        # default block_global rejection. This source exists only on the VM veth.
        self.global_source = "2000:77::2"
        self.assertTrue(ipaddress.ip_address(self.global_source).is_global)
        self.command("ip", "-n", "netfleet-compat-test", "-6", "addr", "add", self.global_source + "/128", "dev", "nfcompat1", "nodad")
        self.command("ip", "-6", "route", "add", self.global_source + "/128", "dev", "nfcompat0")
        if not Path("/etc/config/netfleet").exists():
            self.command("cp", "/usr/share/opl-netfleet/netfleet.config", "/etc/config/netfleet")
        for assignment in ("netfleet.config.enabled=1", "netfleet.config.profile=file:compat.json", "netfleet.mixin.api_secret=compat-fixture"):
            self.command("uci", "set", assignment)
        self.command("uci", "delete", "netfleet.proxy.lan_inbound_interface")
        self.command("uci", "add_list", "netfleet.proxy.lan_inbound_interface=nfcompat")
        self.command("uci", "add_list", "netfleet.@router_access_control[0].user=nobody")
        self.command("uci", "add_list", "netfleet.@router_access_control[0].group=nogroup")
        self.command("uci", "commit", "netfleet")
        root = Path("/etc/opl-netfleet")
        (root / "backend.json").write_text('{"kind":"native-mihomo"}')
        (root / "native/profiles").mkdir(parents=True, exist_ok=True, mode=0o700)
        (root / "native/profiles/compat.json").write_text(json.dumps({"rules": ["SRC-PORT,41641,DIRECT", "MATCH,DIRECT"], "hosts": {self.HOST: "198.51.100.10"}}))
        bundle = Path("/etc/ssl/certs/ca-certificates.crt")
        previous_bundle = bundle.read_bytes()
        self.addCleanup(bundle.write_bytes, previous_bundle)
        bundle.write_bytes(previous_bundle + (self.directory / "upstream.pem").read_bytes())
        self.command("/etc/init.d/opl-netfleet-core", "start")
        self.addCleanup(self.command, "/etc/init.d/opl-netfleet-core", "stop")
        self.owner = Controller()
        self.addCleanup(self.disable)
        hosts = Path("/etc/hosts")
        original_hosts = hosts.read_bytes()
        self.addCleanup(hosts.write_bytes, original_hosts)
        hosts.write_bytes(original_hosts + b"\n198.51.100.10 wire.example\n2001:db8:88::10 wire.example\n")

    def disable(self):
        status = self.owner.call("get")
        self.owner.call("disable", {"revision": status["revision"]})

    async def stop_origin(self):
        if self.origin.returncode is None:
            self.origin.terminate()
        await asyncio.wait_for(self.origin.wait(), 5)

    async def test_native_egress_and_management_expiry(self):
        self.assertFalse((await self.request(ca=self.directory / "upstream.pem"))["h2"])
        # The controller inherits the core lifecycle cgroup, which bypasses Mihomo.
        # Keep that direct path broken while the engine and Mihomo retain their egress.
        self.command("nft", "add", "table", "inet", "netfleet_probe_test")
        self.addCleanup(self.command, "nft", "delete", "table", "inet", "netfleet_probe_test")
        self.command("nft", "add", "chain", "inet", "netfleet_probe_test", "output",
                     "{ type filter hook output priority 0; policy accept; }")
        self.command("nft", "add", "rule", "inet", "netfleet_probe_test", "output",
                     "oifname", "nfcompat-up", "ip", "daddr", "198.51.100.10", "tcp", "dport", "443",
                     "socket", "cgroupv2", "level", "3", "services/opl-netfleet-core/lifecycle", "counter", "drop")
        self.command(sys.executable, "-c", """import os, socket
from pathlib import Path
Path('/sys/fs/cgroup/services/opl-netfleet-core/lifecycle/cgroup.procs').write_text(str(os.getpid()))
try:
    connection = socket.create_connection(('198.51.100.10', 443), timeout=0.3)
except TimeoutError:
    pass
else:
    connection.close()
    raise AssertionError('lifecycle direct egress must be blocked')
""")
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
        self.assertFalse((await self.request(source_port=41641, ca=self.directory / "upstream.pem"))["h2"])
        self.assertTrue(self.owner.health(probe=True)["transparent_chain"])
        # The explicit probe stays healthy when only the transparent ingress fails.
        self.command("nft", "insert", "rule", "inet", "netfleet_compat", "private_listener",
                     "tcp", "dport", "18443", "reject", "with", "tcp", "reset")
        broken = self.owner.health(probe=True)
        self.assertTrue(broken["processing_chain"])
        self.assertFalse(broken["transparent_chain"])
        await asyncio.sleep(3)
        self.assertFalse(self.owner.call("get")["intercepting"])
        self.assertEqual(self.owner.call("get")["reason"], "transparent_chain_failed")
        rules = json.loads(subprocess.check_output(["nft", "-j", "list", "chain", "inet", "netfleet_compat", "private_listener"]))
        first = next(item["rule"] for item in rules["nftables"] if "rule" in item)
        self.command("nft", "delete", "rule", "inet", "netfleet_compat", "private_listener", "handle", str(first["handle"]))
        self.owner.call("probe", {"revision": self.owner.call("get")["revision"], "operation": "recover"})
        deadline = time.monotonic() + 85
        while not self.owner.call("get")["intercepting"]:
            self.assertLess(time.monotonic(), deadline, self.owner.call("get"))
            await asyncio.sleep(1)
        # Production uses one wildcard transparent listener for both families.
        config["devices"][0]["addresses"].append("2001:db8:77::2")
        config["devices"][0]["addresses"].append(self.global_source)
        saved = self.owner.call("apply", {"revision": self.owner.call("get")["revision"], "config": config})
        self.owner.call("probe", {"revision": saved["revision"], "operation": "trust_record", "device": "mac",
                                  "report": {"system": True, "ca_sha256": saved["ca_sha256"]}})
        deadline = time.monotonic() + 85
        while not self.owner.call("get")["intercepting"]:
            self.assertLess(time.monotonic(), deadline, self.owner.call("get"))
            await asyncio.sleep(1)
        self.DESTINATION = "2001:db8:88::10"
        wire6 = await self.request()
        self.assertTrue(wire6["h2"], {"wire": wire6, "health": self.owner.health()})
        self.assertFalse((await self.request(source_port=41641, ca=self.directory / "upstream.pem"))["h2"])
        global_wire = await self.request(source=self.global_source)
        self.assertTrue(global_wire["h2"], {"wire": global_wire, "health": self.owner.health()})
        await self.assert_occupied_port_paths()
        self.assertEqual((await self.request(ca=self.directory / "upstream.pem", h2=True))["alpn"], "h2")
        self.assertFalse((await self.request(host="other.example", ca=self.directory / "upstream.pem"))["h2"])
        self.DESTINATION = "198.51.100.10"
        await self.assert_occupied_port_paths()
        self.assertFalse((await self.request(host="other.example", ca=self.directory / "upstream.pem"))["h2"])
        packages = list(Path("/tmp/compat-runtime").glob("opl-netfleet-https-compat-*.apk"))
        if packages:
            core_command = ["ubus", "call", "service", "list", '{"name":"opl-netfleet-core"}']
            core_before_upgrade = json.loads(subprocess.check_output(core_command))["opl-netfleet-core"]["instances"]["core"]["pid"]
            held = await self.request(hold=True)
            upgrade = await asyncio.create_subprocess_exec("flock", "/var/lock/opl-netfleet-deploy.lock",
                "apk", "add", "--force-reinstall", str(packages[0]),
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
            try:
                await asyncio.sleep(32)
                self.assertIsNone(upgrade.returncode, "package replacement must wait for the live TLS connection")
                from https_compat_kernel import gateway as kernel_gateway
                self.assertFalse(kernel_gateway.status()["intercepting"])
                self.assertFalse((await self.request(ca=self.directory / "upstream.pem"))["h2"])
                output, error = await asyncio.wait_for(held.communicate(b"\n"), 6)
                self.assertEqual(held.returncode, 0, error.decode())
                self.assertTrue(json.loads(output)["h2"], "the existing connection must finish before engine replacement")
                output, error = await asyncio.wait_for(upgrade.communicate(), 30)
                self.assertEqual(upgrade.returncode, 0, error.decode())
                core_after_upgrade = json.loads(subprocess.check_output(core_command))["opl-netfleet-core"]["instances"]["core"]["pid"]
                self.assertEqual(core_before_upgrade, core_after_upgrade, "plugin replacement cannot restart the base core")
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
        service = json.loads(subprocess.check_output(["ubus", "call", "service", "list", '{"name":"opl-netfleet-compat"}']))
        lifecycle = service["opl-netfleet-compat"]["instances"]["manager"]["pid"]
        core_before = json.loads(subprocess.check_output(["ubus", "call", "service", "list", '{"name":"opl-netfleet-core"}']))["opl-netfleet-core"]["instances"]["core"]["pid"]
        engine = self.owner.health()["pid"]
        import os
        os.kill(lifecycle, signal.SIGSTOP)
        os.kill(engine, signal.SIGSTOP)
        try:
            await asyncio.sleep(11)
            self.assertFalse(self.owner.call("get")["intercepting"])
            self.assertFalse((await self.request(ca=self.directory / "upstream.pem"))["h2"])
            core_after = json.loads(subprocess.check_output(["ubus", "call", "service", "list", '{"name":"opl-netfleet-core"}']))["opl-netfleet-core"]["instances"]["core"]["pid"]
            self.assertEqual(core_before, core_after, 'plugin faults cannot restart the base core')
        finally:
            os.kill(engine, signal.SIGCONT)
            os.kill(lifecycle, signal.SIGCONT)
        resumed_at = time.monotonic()
        for _ in range(3):
            deadline = time.monotonic() + 12
            while True:
                state = json.loads(Path("/var/run/opl-netfleet-compat/state.json").read_text())
                recovery = state.get("recovery", {})
                # A tick can begin before SIGCONT and finish its health probe afterward.
                if recovery.get("latched") or recovery.get("healthy") and state.get("last_tick", 0) >= resumed_at:
                    break
                self.assertLess(time.monotonic(), deadline, recovery)
                await asyncio.sleep(1)
            if recovery.get("latched"):
                break
            fault_count = len(recovery.get("faults", []))
            engine = self.owner.health()["pid"]
            os.kill(engine, signal.SIGSTOP)
            try:
                deadline = time.monotonic() + 12
                while True:
                    recovery = self.owner.call("get").get("recovery", {})
                    if len(recovery.get("faults", [])) > fault_count:
                        break
                    self.assertLess(time.monotonic(), deadline, recovery)
                    await asyncio.sleep(0.5)
            finally:
                os.kill(engine, signal.SIGCONT)
                resumed_at = time.monotonic()
        await asyncio.sleep(32)
        state = self.owner.call("get")
        self.assertTrue(state["recovery"]["latched"], state)
        self.assertFalse(state["intercepting"])
        self.assertFalse((await self.request(ca=self.directory / "upstream.pem"))["h2"])
        self.owner.call("probe", {"revision": state["revision"], "operation": "recover"})
        deadline = time.monotonic() + 45
        while not self.owner.call("get")["intercepting"]:
            self.assertLess(time.monotonic(), deadline, self.owner.call("get"))
            await asyncio.sleep(1)
        self.assertTrue((await self.request())["h2"])
        sys.path.insert(0, "/usr/libexec/opl-netfleet-compat")
        import gateway
        for selector in ("user", "group"):
            self.command("uci", "add_list", f"netfleet.@router_access_control[0].{selector}=netfleet-compat")
            try:
                self.assertTrue(gateway.snapshot()["custom_lan_access"], "matching engine identity must reject admission")
            finally:
                self.command("uci", "del_list", f"netfleet.@router_access_control[0].{selector}=netfleet-compat")


if __name__ == "__main__":
    unittest.main(defaultTest="Native.test_native_egress_and_management_expiry", verbosity=2)
