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
        # Include a globally classified IPv6 source as well as documentation
        # prefixes. This address exists only on the isolated VM veth.
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
        if not wire['h2']:
            import csv, io, haproxy, control
            stats = list(csv.DictReader(io.StringIO(haproxy.command(control.RUN, 'show stat').removeprefix('# '))))
            fields = ('pxname', 'svname', 'scur', 'stot', 'req_tot', 'econ', 'eresp', 'status', 'hrsp_2xx', 'hrsp_5xx')
            print('wire_failure_diagnostic=' + json.dumps({
                'map': haproxy.command(control.RUN, f'show map {control.RUN}/rules.map'),
                'stats': [{key: row.get(key) for key in fields} for row in stats],
                'errors': haproxy.command(control.RUN, 'show errors')}), flush=True)
        self.assertTrue(wire["h2"], {"wire": wire, "engine": self.owner.health()})
        # Measure the whole running plugin without polling its management API.
        # These synthetic VM results are not WAN throughput or Home measurements.
        def resources():
            result = {}
            for name, group in (('engine', 'netfleet-compat'), ('manager', 'netfleet-compat-manager')):
                root = Path('/sys/fs/cgroup') / group
                result[name] = {**{key: int(value) for key, value in
                                  (line.split() for line in (root / 'cpu.stat').read_text().splitlines())},
                                'memory_current': int((root / 'memory.current').read_text())}
            return result
        # Include a realistic populated base set: an empty VM ruleset hid the
        # cost of repeatedly rendering the whole gateway table on small routers.
        elements = ', '.join(f'198.18.{number // 256}.{number % 256}' for number in range(8192))
        subprocess.run(['nft', '-f', '-'], input='add set inet netfleet compatibility_scale_test '
                       '{ type ipv4_addr; elements = { ' + elements + ' }; }\n',
                       text=True, check=True, capture_output=True)
        measurements = {}
        for workload in ('idle', '10_small_https_requests'):
            before, started = resources(), time.monotonic()
            latencies = []
            if workload == 'idle':
                await asyncio.sleep(20)
            else:
                for _ in range(10):
                    request_started = time.monotonic()
                    self.assertTrue((await self.request())['h2'])
                    latencies.append(round((time.monotonic() - request_started) * 1000, 2))
                    await asyncio.sleep(max(0, 1 - (time.monotonic() - request_started)))
            elapsed, after = time.monotonic() - started, resources()
            measurements[workload] = {'seconds': round(elapsed, 3), 'request_ms': latencies,
                'groups': {name: {'cpu_percent_of_one_core': round((values['usage_usec'] - before[name]['usage_usec']) / elapsed / 10000, 3),
                                 'memory_current_bytes': values['memory_current'],
                                 'throttled_periods': values.get('nr_throttled', 0) - before[name].get('nr_throttled', 0)}
                           for name, values in after.items()}}
        Path('/tmp/compat-performance.json').write_text(json.dumps(measurements))
        print('compatibility_performance=' + json.dumps(measurements), flush=True)
        self.command('nft', 'delete', 'set', 'inet', 'netfleet', 'compatibility_scale_test')
        # A normal owner transaction can outlast the lease. The kernel must
        # bypass during the lock, then fresh health can readmit without an outage.
        faults_before = self.owner.call("get")["recovery"]["faults"]
        holder = await asyncio.create_subprocess_exec(sys.executable, "-c", """import fcntl, time
with open('/var/lock/opl-netfleet-deploy.lock', 'a') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    print('locked', flush=True)
    time.sleep(14)
""", stdout=asyncio.subprocess.PIPE)
        try:
            self.assertEqual(await asyncio.wait_for(holder.stdout.readline(), 10), b'locked\n')
            await asyncio.sleep(11)
            self.assertFalse((await self.request(ca=self.directory / "upstream.pem"))["h2"])
            await asyncio.wait_for(holder.wait(), 6)
        finally:
            if holder.returncode is None:
                holder.kill()
                await holder.wait()
        deadline = time.monotonic() + 15
        while not self.owner.call("get")["intercepting"]:
            self.assertLess(time.monotonic(), deadline, self.owner.call("get"))
            await asyncio.sleep(1)
        self.assertEqual(self.owner.call("get")["recovery"]["faults"], faults_before)

        # Keep one real local processing outage across multiple procd restarts.
        # Our independent fault table survives the engine's listener rebuild.
        self.command("nft", "add", "table", "inet", "netfleet_processing_fault")
        self.command("nft", "add", "chain", "inet", "netfleet_processing_fault", "output",
                     "{ type filter hook output priority 0; policy accept; }")
        self.command("nft", "add", "rule", "inet", "netfleet_processing_fault", "output",
                     "oifname", "lo", "tcp", "dport", "18445", "reject", "with", "tcp", "reset")
        try:
            await asyncio.sleep(26)
            failed = self.owner.call("get")
            self.assertFalse(failed["intercepting"], failed)
            self.assertFalse(failed["recovery"]["latched"], failed)
            self.assertEqual(len(failed["recovery"]["faults"]), len(faults_before) + 1, failed)
            self.assertGreaterEqual(failed["engine_restart"]["attempts"], 2, failed)
            self.assertFalse((await self.request(ca=self.directory / "upstream.pem"))["h2"])
        finally:
            self.command("nft", "delete", "table", "inet", "netfleet_processing_fault")
        deadline = time.monotonic() + 60
        while not self.owner.call("get")["intercepting"]:
            self.assertLess(time.monotonic(), deadline, self.owner.call("get"))
            await asyncio.sleep(1)
        self.assertTrue((await self.request())["h2"])
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
            deadline = time.monotonic() + 45
            while True:
                state = json.loads(Path("/var/run/opl-netfleet-compat/state.json").read_text())
                recovery = state.get("recovery", {})
                # Failures during the recovery window belong to the same outage.
                # Start another incident only after the kernel admits new flows.
                if recovery.get("latched") or (state.get("intercepting")
                        and state.get("last_tick", 0) >= resumed_at
                        and self.owner.call("get")["intercepting"]):
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
        suspended = self.owner.call("suspend", internal=True)
        self.owner.call("resume", suspended, internal=True)
        await asyncio.sleep(3)
        after_resume = self.owner.call("get")
        self.assertTrue(after_resume["recovery"]["latched"], after_resume)
        self.assertEqual(after_resume["last_failure"], state["last_failure"])
        self.assertFalse(after_resume["intercepting"])
        old_packages = list(Path("/tmp/compat-runtime/rollback").glob("opl-netfleet-https-compat-*.apk"))
        if packages and old_packages:
            import hashlib
            predecessor = old_packages[0].parent
            old_manifest = json.loads((predecessor / "compat-manifest.json").read_text())
            self.assertEqual(old_packages[0].name, old_manifest["artifact"])
            self.assertEqual(hashlib.sha256(old_packages[0].read_bytes()).hexdigest(), old_manifest["sha256"])
            self.command("cp", str(predecessor / "compat-public-key.pem"), "/etc/apk/keys/compat-predecessor.pem")
            self.command("apk", "verify", str(old_packages[0]))
            async def replace_engine(package):
                operation = await asyncio.create_subprocess_exec("flock", "/var/lock/opl-netfleet-deploy.lock",
                    "apk", "--no-network", "add", str(package),
                    stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
                try:
                    output, error = await asyncio.wait_for(operation.communicate(), 90)
                    self.assertEqual(operation.returncode, 0, error.decode())
                finally:
                    if operation.returncode is None:
                        operation.kill()
                        await operation.wait()
            # Exercise the real old controller and package hooks. No fabricated
            # latch/state migration can prove this upgrade boundary.
            await replace_engine(old_packages[0])
            legacy_suspend = self.owner.call("suspend", internal=True)
            self.assertNotIn("keep_maintenance", legacy_suspend)
            self.assertEqual(self.owner.call("get")["reason"], "maintenance")
            await replace_engine(packages[0])
            await asyncio.sleep(3)
            upgraded = self.owner.call("get")
            self.assertTrue(upgraded["requested"])
            self.assertFalse(upgraded["intercepting"])
            self.assertEqual(upgraded["reason"], "maintenance")
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
