"""Real Mihomo fault-injection test verifying 4-stage Fail-Open escalation."""

import http.server
import json
import os
import select
import shutil
import socket
import socketserver
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def _free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def _find_mihomo() -> str | None:
    runtime_root = os.environ.get("NETFLEET_RUNTIME_ROOT")
    if runtime_root:
        candidate = Path(runtime_root) / "bin/mihomo"
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return shutil.which("mihomo")


def _resolve_ucode() -> tuple[str, str]:
    ucode_bin = os.environ.get("UCODE")
    ucode_lib = os.environ.get("UCODE_LIB", "")
    if ucode_bin and os.access(ucode_bin, os.X_OK):
        return ucode_bin, ucode_lib
    out = subprocess.check_output(
        ["sh", "-c", "UCODE_PREFLIGHT='fs socket' . ./scripts/resolve-ucode-runtime.sh && printf '%s\\n%s\\n' \"$UCODE\" \"${UCODE_LIB:-}\""],
        cwd=ROOT,
        text=True,
    ).splitlines()
    return out[0], out[1] if len(out) > 1 else ""


class FailOpenRealMihomoTests(unittest.TestCase):
    def test_four_stage_escalation_uses_compiled_groups_without_premature_direct(self):
        mihomo_bin = _find_mihomo()
        if not mihomo_bin:
            self.skipTest("mihomo binary unavailable")
        ucode_bin, ucode_lib = _resolve_ucode()

        class _ThreadingServer(socketserver.ThreadingTCPServer):
            allow_reuse_address = True
            daemon_threads = True
            request_queue_size = 128

        class ProbeTarget(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def do_GET(self):
                time.sleep(0.01)
                self.send_response(204)
                self.send_header("Content-Length", "0")
                self.send_header("Connection", "close")
                self.end_headers()

            def do_HEAD(self):
                self.do_GET()

            def log_message(self, *args):
                pass

        probe_port = _free_port()
        probe_srv = _ThreadingServer(("127.0.0.1", probe_port), ProbeTarget)
        threading.Thread(target=probe_srv.serve_forever, daemon=True).start()
        self.addCleanup(probe_srv.shutdown)
        self.addCleanup(probe_srv.server_close)

        healthy = {"pref": True, "primary_alt": True, "reserve": True}

        def start_proxy(key: str) -> int:
            class ToggleProxy(http.server.BaseHTTPRequestHandler):
                protocol_version = "HTTP/1.1"

                def do_CONNECT(self):
                    self.close_connection = True
                    if not healthy[key]:
                        return
                    host, port = self.path.split(":")
                    upstream = socket.create_connection((host, int(port)), timeout=2)
                    self.send_response(200, "Connection Established")
                    self.end_headers()
                    conns = [self.connection, upstream]
                    try:
                        while True:
                            readable, _, _ = select.select(conns, [], [], 2)
                            if not readable:
                                break
                            for s in readable:
                                chunk = s.recv(4096)
                                if not chunk:
                                    try:
                                        (upstream if s is self.connection else self.connection).shutdown(socket.SHUT_WR)
                                    except OSError:
                                        pass
                                    conns.remove(s)
                                    if not conns:
                                        return
                                    continue
                                (upstream if s is self.connection else self.connection).sendall(chunk)
                    except OSError:
                        pass
                    finally:
                        upstream.close()

                def do_GET(self):
                    self.close_connection = True
                    if not healthy[key]:
                        return
                    time.sleep(0.01)
                    self.send_response(204)
                    self.send_header("Content-Length", "0")
                    self.send_header("Connection", "close")
                    self.end_headers()

                def do_HEAD(self):
                    return self.do_GET()

                def log_message(self, *args):
                    pass

            port = _free_port()
            srv = _ThreadingServer(("127.0.0.1", port), ToggleProxy)
            threading.Thread(target=srv.serve_forever, daemon=True).start()
            self.addCleanup(srv.shutdown)
            self.addCleanup(srv.server_close)
            return port

        pref_port = start_proxy("pref")
        alt_port = start_proxy("primary_alt")
        res_port = start_proxy("reserve")

        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            provider_files = {
                "alpha": work / "alpha.json",
                "beta": work / "beta.json",
                "reserve_prov": work / "reserve_prov.json",
            }
            provider_files["alpha"].write_text(json.dumps({
                "proxies": [{"name": "JP ALPHA", "type": "http", "server": "127.0.0.1", "port": pref_port}]
            }))
            provider_files["beta"].write_text(json.dumps({
                "proxies": [{"name": "SG BETA", "type": "http", "server": "127.0.0.1", "port": alt_port}]
            }))
            provider_files["reserve_prov"].write_text(json.dumps({
                "proxies": [{"name": "US RESERVE", "type": "http", "server": "127.0.0.1", "port": res_port}]
            }))

            probe_url = f"http://127.0.0.1:{probe_port}/generate_204"
            base_profile = {
                "proxy-groups": [{"name": "AI", "type": "select", "proxies": ["DIRECT"]}],
                "proxy-providers": {},
                "rules": ["MATCH,AI"],
            }
            policy = {
                "schema_version": 2,
                "main": {"target": "fixture", "enabled": True},
                "policy_source": {"kind": "profile", "ref": "file:base.json"},
                "recovery_profile": {"ref": "file:recovery.json"},
                "bindings": {"AI": {"capability": "ai-compatible", "kind": "entry"}},
                "providers": {
                    "alpha": {"section": "alpha", "enabled": True, "role": "primary"},
                    "beta": {"section": "beta", "enabled": True, "role": "primary"},
                    "reserve_prov": {"section": "reserve_prov", "enabled": True, "role": "reserve"},
                },
                "regions": {
                    "japan": {"mode": "automatic", "display_name": "日本", "flag": "🇯🇵", "display_order": 10},
                    "singapore": {"mode": "automatic", "display_name": "新加坡", "flag": "🇸🇬", "display_order": 20},
                    "united_states": {"mode": "automatic", "display_name": "美国", "flag": "🇺🇸", "display_order": 30},
                },
                "provider_regions": {
                    "alpha": [{"region": "japan", "filter": "ALPHA"}],
                    "beta": [{"region": "singapore", "filter": "BETA"}],
                    "reserve_prov": [{"region": "united_states", "filter": "RESERVE"}],
                },
                "capabilities": {
                    "ai-compatible": {
                        "display_name": "AI 出口",
                        "display_order": 10,
                        "enabled": True,
                        "mode": "automatic",
                    }
                },
                "selection": {"region_switch_margin_ms": 150, "leaf_switch_margin_ms": 80},
                "checks": {
                    "provider_healthcheck_timeout_ms": 1000,
                    "latency": {"method": "mihomo_delay", "url": probe_url, "timeout_ms": 800, "expected_status": 204},
                    "quota": {"source": "nikki_subscription_metadata", "zero_is_exhausted": True},
                },
                "evidence": {"path": str(work / "evidence.json")},
                "fail_open": {
                    "healthcheck": {"path_probe_id": "path", "guard_probe_id": "guard", "interval_seconds": 30, "timeout_ms": 800, "max_failed_times": 2},
                    "probes": [
                        {"id": "path", "url": probe_url, "expected_status": 204, "head_expected_status": 204},
                        {"id": "guard", "url": probe_url, "expected_status": 204, "head_expected_status": 204},
                    ],
                },
            }
            provider_profiles = {
                "alpha": {"path": str(provider_files["alpha"]), "runtime_path": str(provider_files["alpha"]), "display_name": "Alpha", "profile": {"proxies": [{"name": "JP ALPHA"}]}},
                "beta": {"path": str(provider_files["beta"]), "runtime_path": str(provider_files["beta"]), "display_name": "Beta", "profile": {"proxies": [{"name": "SG BETA"}]}},
                "reserve_prov": {"path": str(provider_files["reserve_prov"]), "runtime_path": str(provider_files["reserve_prov"]), "display_name": "Reserve", "profile": {"proxies": [{"name": "US RESERVE"}]}},
            }

            compile_script = work / "compile.uc"
            compiled_out = work / "compiled.json"
            compile_script.write_text(f"""
import * as fs from "fs";
import {{ use, release }} from "{ROOT}/tests/services.uc";
const compile = use("compilation.compiler").compile;
const res = compile(
  json(fs.readfile({json.dumps(str(work / "base.json"))})),
  json(fs.readfile({json.dumps(str(work / "policy.json"))})),
  "{"a"*64}", "{"b"*64}", "{"c"*64}",
  json(fs.readfile({json.dumps(str(work / "providers.json"))}))
);
release();
if (!res.ok) {{ warn(sprintf("%J\\n", res.errors)); exit(1); }}
fs.writefile({json.dumps(str(compiled_out))}, sprintf("%J\\n", res.profile));
""")
            (work / "base.json").write_text(json.dumps(base_profile))
            (work / "policy.json").write_text(json.dumps(policy))
            (work / "providers.json").write_text(json.dumps(provider_profiles))

            cmd = [ucode_bin]
            if ucode_lib:
                cmd += ["-L", ucode_lib]
            cmd.append(str(compile_script))
            res = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
            self.assertEqual(0, res.returncode, res.stderr + res.stdout)

            compiled = json.loads(compiled_out.read_text())
            ctrl_port = _free_port()
            mixed_port = _free_port()
            for src in compiled["proxy-providers"].values():
                src["path"] = Path(src["path"]).name
                src["health-check"] = {"enable": True, "url": probe_url, "interval": 30, "timeout": 800, "lazy": False}
            compiled["log-level"] = "warning"
            compiled["mixed-port"] = mixed_port
            compiled["external-controller"] = f"127.0.0.1:{ctrl_port}"
            compiled_cfg = work / "runtime.json"
            compiled_cfg.write_text(json.dumps(compiled, ensure_ascii=False))

            proc = subprocess.Popen([mihomo_bin, "-d", str(work), "-f", str(compiled_cfg)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            def drain_logs() -> str:
                if proc.poll() is None:
                    proc.terminate()
                out, _ = proc.communicate(timeout=3)
                return out[-3500:]
            try:
                ready = False
                for _ in range(40):
                    if proc.poll() is not None:
                        out = proc.stdout.read() if proc.stdout else ""
                        self.fail(f"mihomo exited early ({proc.returncode}): {out}")
                    try:
                        urllib.request.urlopen(f"http://127.0.0.1:{ctrl_port}/version", timeout=0.5).read()
                        ready = True
                        break
                    except Exception:
                        time.sleep(0.1)
                self.assertTrue(ready, "mihomo controller did not become ready in time")

                time.sleep(0.5)
                # Bind preferred choice to Alpha Japan and visible exit to automatic,
                # then initialize path health across group members.
                for grp, choice in [("AI 出口 · 当前优选", "AI 出口 · 🇯🇵 日本 · Alpha"), ("AI 出口", "AI 出口 · 自动选优")]:
                    req = urllib.request.Request(
                        f"http://127.0.0.1:{ctrl_port}/proxies/{urllib.request.quote(grp)}",
                        data=json.dumps({"name": choice}).encode(),
                        headers={"Content-Type": "application/json"},
                        method="PUT",
                    )
                    urllib.request.urlopen(req, timeout=2).read()

                group_names = {g["name"] for g in compiled.get("proxy-groups", [])}
                self.assertNotIn("AI 出口 · 代理路径", group_names)
                for kind, grp in [
                    ("group", "AI 出口 · 🇯🇵 日本 · Alpha"),
                    ("group", "AI 出口 · Alpha"),
                    ("group", "AI 出口 · Beta"),
                    ("group", "AI 出口 · Reserve"),
                    ("proxies", "AI 出口 · 当前优选"),
                    ("proxies", "AI 出口 · 自动选优"),
                ]:
                    delay_url = (
                        f"http://127.0.0.1:{ctrl_port}/{kind}/{urllib.request.quote(grp)}/delay"
                        f"?url={urllib.request.quote(probe_url, safe='')}&timeout=800&expected=204"
                    )
                    for attempt in range(3):
                        try:
                            urllib.request.urlopen(delay_url, timeout=3).read()
                            break
                        except urllib.error.HTTPError as exc:
                            if attempt < 2:
                                time.sleep(0.3)
                                continue
                            provs = urllib.request.urlopen(f"http://127.0.0.1:{ctrl_port}/providers/proxies", timeout=2).read().decode()
                            grp_info = urllib.request.urlopen(f"http://127.0.0.1:{ctrl_port}/proxies/{urllib.request.quote(grp)}", timeout=2).read().decode()
                            self.fail(f"/delay failed for {grp}: {exc.code} {exc.read().decode()} | grp={grp_info} | logs=\n{drain_logs()}")

                time.sleep(0.3)

                def trace(group: str = "AI 出口") -> list[str]:
                    proxies = json.loads(urllib.request.urlopen(f"http://127.0.0.1:{ctrl_port}/proxies", timeout=2).read())["proxies"]
                    chain = []
                    cur = group
                    for _ in range(10):
                        chain.append(cur)
                        nxt = (proxies.get(cur) or {}).get("now")
                        if not nxt:
                            break
                        cur = nxt
                    return chain

                def send_failing_traffic(rounds: int = 8):
                    opener = urllib.request.build_opener(urllib.request.ProxyHandler({"http": f"http://127.0.0.1:{mixed_port}"}))
                    for _ in range(rounds):
                        try:
                            opener.open(probe_url, timeout=1.5).read()
                        except Exception:
                            pass

                # Stage 1: Preferred node healthy
                chain1 = trace()
                self.assertIn("AI 出口 · 当前优选", chain1)
                self.assertEqual("JP ALPHA", chain1[-1])

                def debug_groups() -> str:
                    p = json.loads(urllib.request.urlopen(f"http://127.0.0.1:{ctrl_port}/proxies", timeout=2).read())["proxies"]
                    keys = ["AI 出口 · 自动选优", "AI 出口 · 当前优选", "AI 出口 · 主用机场", "AI 出口 · Alpha", "AI 出口 · Beta", "AI 出口 · 备用机场", "NetFleet · 直连护栏"]
                    return json.dumps({k: {"now": p.get(k, {}).get("now"), "alive": p.get(k, {}).get("alive"), "extra": p.get(k, {}).get("extra")} for k in keys}, ensure_ascii=False)

                # Stage 2: Preferred dies -> must fail over to sibling primary SG BETA, NOT Reserve or DIRECT
                healthy["pref"] = False
                deadline = time.monotonic() + 12.0
                chain2 = trace()
                while time.monotonic() < deadline and chain2[-1] != "SG BETA":
                    send_failing_traffic(3)
                    time.sleep(0.4)
                    chain2 = trace()
                    if "NetFleet · 直连护栏" in chain2:
                        self.fail(f"Premature DIRECT during primary failover: {chain2} | groups={debug_groups()} | logs=\n{drain_logs()}")
                    if "AI 出口 · 备用机场" in chain2:
                        self.fail(f"Skipped sibling primary onto reserve: {chain2} | groups={debug_groups()} | logs=\n{drain_logs()}")
                self.assertEqual("SG BETA", chain2[-1])
                self.assertNotIn("AI 出口 · 备用机场", chain2)
                self.assertNotIn("NetFleet · 直连护栏", chain2)

                # Stage 3: Primary alt dies too -> must escalate to Reserve Tier (US RESERVE), NOT DIRECT
                healthy["primary_alt"] = False
                deadline = time.monotonic() + 12.0
                chain3 = trace()
                while time.monotonic() < deadline and chain3[-1] != "US RESERVE":
                    send_failing_traffic(3)
                    time.sleep(0.4)
                    chain3 = trace()
                    if "NetFleet · 直连护栏" in chain3:
                        self.fail(f"Premature DIRECT during reserve failover: {chain3} | groups={debug_groups()} | logs=\n{drain_logs()}")
                self.assertIn("AI 出口 · 备用机场", chain3)
                self.assertEqual("US RESERVE", chain3[-1])

                # Stage 4: All providers dead -> escalates to NetFleet · 直连护栏 -> DIRECT
                healthy["reserve"] = False
                deadline = time.monotonic() + 18.0
                chain4 = trace()
                while time.monotonic() < deadline and chain4[-1] != "DIRECT":
                    send_failing_traffic(6)
                    time.sleep(0.6)
                    chain4 = trace()
                self.assertIn("NetFleet · 直连护栏", chain4)
                self.assertEqual("DIRECT", chain4[-1])
            finally:
                proc.terminate()
                proc.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
