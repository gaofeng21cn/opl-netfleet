"""Real Mihomo fault-injection test verifying 4-stage Fail-Open escalation."""

import http.client
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
    def _run_fail_open_scenario(self, *, probe_mode: str, multi_alpha_leaf: bool = False):
        mihomo_bin = _find_mihomo()
        if not mihomo_bin:
            self.skipTest("mihomo binary unavailable")
        ucode_bin, ucode_lib = _resolve_ucode()

        class _ThreadingServer(socketserver.ThreadingTCPServer):
            allow_reuse_address = True
            daemon_threads = True
            request_queue_size = 128

        def start_probe_target():
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

            port = _free_port()
            srv = _ThreadingServer(("127.0.0.1", port), ProbeTarget)
            threading.Thread(target=srv.serve_forever, daemon=True).start()
            self.addCleanup(srv.shutdown)
            self.addCleanup(srv.server_close)
            return port

        probe_port = start_probe_target()
        guard_port = start_probe_target() if probe_mode == "separate_endpoint" else probe_port

        healthy = {"pref": True, "pref_backup": True, "primary_alt": True, "reserve": True}

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
        pref_backup_port = start_proxy("pref_backup") if multi_alpha_leaf else None
        alt_port = start_proxy("primary_alt")
        res_port = start_proxy("reserve")

        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            alpha_proxies = [{"name": "JP ALPHA", "type": "http", "server": "127.0.0.1", "port": pref_port}]
            if multi_alpha_leaf:
                alpha_proxies.append({"name": "JP ALPHA 2", "type": "http", "server": "127.0.0.1", "port": pref_backup_port})
            provider_files = {
                "alpha": work / "alpha.json",
                "beta": work / "beta.json",
                "reserve_prov": work / "reserve_prov.json",
            }
            provider_files["alpha"].write_text(json.dumps({"proxies": alpha_proxies}))
            provider_files["beta"].write_text(json.dumps({
                "proxies": [{"name": "SG BETA", "type": "http", "server": "127.0.0.1", "port": alt_port}]
            }))
            provider_files["reserve_prov"].write_text(json.dumps({
                "proxies": [{"name": "US RESERVE", "type": "http", "server": "127.0.0.1", "port": res_port}]
            }))

            if probe_mode == "shared":
                latency_url = f"http://127.0.0.1:{probe_port}/generate_204"
                path_url = latency_url
                guard_url = latency_url
            elif probe_mode == "query_param":
                latency_url = f"http://127.0.0.1:{probe_port}/latency_204"
                path_url = f"http://127.0.0.1:{probe_port}/generate_204"
                guard_url = f"http://127.0.0.1:{probe_port}/generate_204?guard=1"
            elif probe_mode == "separate_endpoint":
                latency_url = f"http://127.0.0.1:{probe_port}/latency_204"
                path_url = f"http://127.0.0.1:{probe_port}/path_204"
                guard_url = f"http://127.0.0.1:{guard_port}/guard_204"
            else:
                raise AssertionError(f"unknown probe_mode: {probe_mode}")

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
                    "latency": {"method": "mihomo_delay", "url": latency_url, "timeout_ms": 800, "expected_status": 204},
                    "quota": {"source": "nikki_subscription_metadata", "zero_is_exhausted": True},
                },
                "evidence": {"path": str(work / "evidence.json")},
                "fail_open": {
                    "healthcheck": {"path_probe_id": "path", "guard_probe_id": "guard", "interval_seconds": 30, "timeout_ms": 800, "max_failed_times": 2},
                    "probes": [
                        {"id": "path", "url": path_url, "expected_status": 204, "head_expected_status": 204},
                        {"id": "guard", "url": guard_url, "expected_status": 204, "head_expected_status": 204},
                    ],
                },
            }
            provider_profiles = {
                "alpha": {"path": str(provider_files["alpha"]), "runtime_path": str(provider_files["alpha"]), "display_name": "Alpha", "profile": {"proxies": alpha_proxies}},
                "beta": {"path": str(provider_files["beta"]), "runtime_path": str(provider_files["beta"]), "display_name": "Beta", "profile": {"proxies": [{"name": "SG BETA"}]}},
                "reserve_prov": {"path": str(provider_files["reserve_prov"]), "runtime_path": str(provider_files["reserve_prov"]), "display_name": "Reserve", "profile": {"proxies": [{"name": "US RESERVE"}]}},
            }

            compile_script = work / "compile.uc"
            compiled_out = work / "compiled.json"
            manifest_out = work / "manifest.json"
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
fs.writefile({json.dumps(str(manifest_out))}, sprintf("%J\\n", res.manifest));
""")
            (work / "base.json").write_text(json.dumps(base_profile))
            (work / "policy.json").write_text(json.dumps(policy))
            (work / "providers.json").write_text(json.dumps(provider_profiles))

            def run_ucode(script_path: Path):
                cmd = [ucode_bin]
                if ucode_lib:
                    cmd += ["-L", ucode_lib]
                cmd.append(str(script_path))
                res = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
                self.assertEqual(0, res.returncode, res.stderr + res.stdout)
                return res.stdout

            run_ucode(compile_script)

            compiled = json.loads(compiled_out.read_text())
            ctrl_port = _free_port()
            mixed_port = _free_port()
            for src in compiled["proxy-providers"].values():
                src["path"] = Path(src["path"]).name
            compiled["log-level"] = "warning"
            compiled["mixed-port"] = mixed_port
            compiled["external-controller"] = f"127.0.0.1:{ctrl_port}"
            compiled_cfg = work / "runtime.json"
            compiled_cfg.write_text(json.dumps(compiled, ensure_ascii=False))

            # Verify compiled group probes: automatic tiers & provider groups share guard_url.
            compiled_by_name = {g["name"]: g for g in compiled.get("proxy-groups", [])}
            self.assertNotIn("AI 出口 · 代理路径", compiled_by_name)
            for auto_group in ("AI 出口 · 自动选优", "AI 出口 · 主用机场", "AI 出口 · 备用机场", "AI 出口 · Alpha", "AI 出口 · Beta", "AI 出口 · Reserve"):
                self.assertEqual(guard_url, compiled_by_name[auto_group]["url"], auto_group)

            activate_script = work / "activate.uc"
            activate_script.write_text(f"""
import * as fs from "fs";
const plugins = "{ROOT}/plugins";
const policy = json(fs.readfile({json.dumps(str(work / "policy.json"))}));
const manifest = json(fs.readfile({json.dumps(str(manifest_out))}));
const entry = manifest.generated_groups["ai-compatible"];
const services = {{}};
services["platform.runtime"] = {{ API: {json.dumps(f"http://127.0.0.1:{ctrl_port}")}, RUN_DIR: {json.dumps(str(work))} }};
services["platform.credentials"] = {{ api_secret: () => "fixture", proxy_authentication: () => null }};
services["platform.process"] = {{ shell_quote: value => "'" + replace(`${{value}}`, "'", "'\\\\''") + "'" }};
const ctx = {{ use: name => services[name] }};
services["models.ordering"] = loadfile(`${{plugins}}/models/lib/ordering.uc`)()(ctx);
services["models.policy"] = loadfile(`${{plugins}}/models/lib/policy.uc`)()(ctx);
services["models.selector"] = loadfile(`${{plugins}}/models/lib/selector.uc`)()(ctx);
services["models.evidence"] = loadfile(`${{plugins}}/models/lib/evidence.uc`)()(ctx);
services["models.activation"] = loadfile(`${{plugins}}/models/lib/activation.uc`)()(ctx);
services["models.status"] = loadfile(`${{plugins}}/models/lib/status.uc`)()(ctx);
services["mihomo.controller"] = loadfile(`${{plugins}}/mihomo/lib/controller.uc`)()(ctx);
services["mihomo.latency"] = loadfile(`${{plugins}}/mihomo/lib/latency.uc`)()(ctx);
services["mihomo.probes"] = {{ protected_probes: () => ({{ ok: true }}), protected_probes_after_restart: () => ({{ ok: true }}) }};
const paths = loadfile(`${{plugins}}/mihomo/lib/paths.uc`)()(ctx);
const choice = "AI 出口 · 🇯🇵 日本 · Alpha";
const ctrl = services["mihomo.controller"];
const latency = services["mihomo.latency"];
const sources = map(values(entry.providers), provider => provider.source_name);
if (!latency.measure_providers("fixture", sources, policy.checks)) {{
    warn("provider measurement failed\\n"); exit(1);
}}
const round = latency.measure("fixture", choice, policy.checks);
if (round?.status != "ok" || !ctrl.test_group_path("fixture", choice, policy.checks)) {{
    warn("preferred candidate measurement failed\\n"); exit(1);
}}
const selected = ctrl.proxies("fixture")?.proxies?.[choice]?.now;
const leaf = round.results[selected] != null ? selected : null;
if (leaf == null) {{ warn("latency measurement did not include the selected leaf\\n"); exit(1); }}
const res = paths.activate_preferred_choice("fixture", entry, choice, policy, false, false, {{ group: choice, candidate_id: leaf }});
if (!res.ok) {{ warn(sprintf("activate failed: %J\\n", res)); exit(1); }}
printf("%J\\n", res);
""")

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
                # Drive activation through real mihomo.paths.activate_preferred_choice + real mihomo.latency.measure
                act_out = run_ucode(activate_script)
                act_res = json.loads(act_out.strip().splitlines()[-1])
                self.assertEqual("preferred", act_res["data_path"])

                time.sleep(0.2)

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

                def send_traffic(rounds: int = 1) -> list[int | None]:
                    statuses = []
                    for _ in range(rounds):
                        connection = http.client.HTTPConnection("127.0.0.1", mixed_port, timeout=1.5)
                        try:
                            connection.request("GET", probe_url_traffic)
                            response = connection.getresponse()
                            statuses.append(response.status)
                            response.read()
                        except (OSError, http.client.HTTPException):
                            statuses.append(None)
                        finally:
                            connection.close()
                    return statuses

                probe_url_traffic = f"http://127.0.0.1:{probe_port}/traffic"

                def debug_groups() -> str:
                    p = json.loads(urllib.request.urlopen(f"http://127.0.0.1:{ctrl_port}/proxies", timeout=2).read())["proxies"]
                    keys = ["AI 出口 · 自动选优", "AI 出口 · 当前优选", "AI 出口 · 主用机场", "AI 出口 · Alpha", "AI 出口 · Beta", "AI 出口 · 备用机场", "NetFleet · 直连护栏"]
                    return json.dumps({k: {"now": p.get(k, {}).get("now"), "alive": p.get(k, {}).get("alive"), "extra": p.get(k, {}).get("extra")} for k in keys}, ensure_ascii=False)

                # Stage 1: Preferred node healthy — must NOT skip 当前优选!
                chain1 = trace()
                self.assertIn("AI 出口 · 当前优选", chain1, f"Skipped preferred on activation: {chain1} | groups={debug_groups()}")
                self.assertIn(chain1[-1], ("JP ALPHA", "JP ALPHA 2"))
                self.assertEqual([204], send_traffic())

                # Stage 2: Preferred leaf dies -> fail over inside same Alpha or sibling primary SG BETA, NOT Reserve or DIRECT
                healthy["pref"] = False
                if multi_alpha_leaf:
                    # With 2 leaves in Alpha, Mihomo may stay in Alpha (JP ALPHA 2) or fail over to SG BETA;
                    # either primary leaf is valid, never Reserve or DIRECT.
                    deadline = time.monotonic() + 12.0
                    chain2 = trace()
                    while time.monotonic() < deadline and chain2[-1] not in ("JP ALPHA 2", "SG BETA"):
                        send_traffic(3)
                        time.sleep(0.4)
                        chain2 = trace()
                        if "NetFleet · 直连护栏" in chain2:
                            self.fail(f"Premature DIRECT during primary failover: {chain2} | groups={debug_groups()} | logs=\n{drain_logs()}")
                        if "AI 出口 · 备用机场" in chain2:
                            self.fail(f"Skipped primary onto reserve: {chain2} | groups={debug_groups()} | logs=\n{drain_logs()}")
                    self.assertIn(chain2[-1], ("JP ALPHA 2", "SG BETA"))
                    healthy["pref_backup"] = False

                deadline = time.monotonic() + 12.0
                chain2b = trace()
                while time.monotonic() < deadline and chain2b[-1] != "SG BETA":
                    send_traffic(3)
                    time.sleep(0.4)
                    chain2b = trace()
                    if "NetFleet · 直连护栏" in chain2b:
                        self.fail(f"Premature DIRECT during sibling primary failover: {chain2b} | groups={debug_groups()} | logs=\n{drain_logs()}")
                    if "AI 出口 · 备用机场" in chain2b:
                        self.fail(f"Skipped sibling primary onto reserve: {chain2b} | groups={debug_groups()} | logs=\n{drain_logs()}")
                self.assertEqual("SG BETA", chain2b[-1])
                self.assertEqual([204], send_traffic())
                self.assertNotIn("AI 出口 · 备用机场", chain2b)
                self.assertNotIn("NetFleet · 直连护栏", chain2b)

                # Stage 3: Primary alt dies too -> must escalate to Reserve Tier (US RESERVE), NOT DIRECT
                healthy["primary_alt"] = False
                deadline = time.monotonic() + 12.0
                chain3 = trace()
                while time.monotonic() < deadline and chain3[-1] != "US RESERVE":
                    send_traffic(3)
                    time.sleep(0.4)
                    chain3 = trace()
                    if "NetFleet · 直连护栏" in chain3:
                        self.fail(f"Premature DIRECT during reserve failover: {chain3} | groups={debug_groups()} | logs=\n{drain_logs()}")
                self.assertIn("AI 出口 · 备用机场", chain3)
                self.assertEqual("US RESERVE", chain3[-1])
                self.assertEqual([204], send_traffic())

                # Stage 4: All providers dead -> escalates to NetFleet · 直连护栏 -> DIRECT
                healthy["reserve"] = False
                deadline = time.monotonic() + 18.0
                chain4 = trace()
                while time.monotonic() < deadline and chain4[-1] != "DIRECT":
                    send_traffic(6)
                    time.sleep(0.6)
                    chain4 = trace()
                self.assertIn("NetFleet · 直连护栏", chain4)
                self.assertEqual("DIRECT", chain4[-1])
                self.assertEqual([204], send_traffic())

                # Stage 5 (recovery re-activation): preferred recovers -> re-running activate_preferred_choice restores 当前优选 -> JP ALPHA
                healthy["pref"] = True
                if multi_alpha_leaf:
                    healthy["pref_backup"] = True
                healthy["primary_alt"] = True
                healthy["reserve"] = True
                react_out = run_ucode(activate_script)
                react_res = json.loads(react_out.strip().splitlines()[-1])
                self.assertEqual("preferred", react_res["data_path"])
                chain5 = trace()
                self.assertIn("AI 出口 · 当前优选", chain5, f"Skipped preferred after recovery: {chain5} | groups={debug_groups()}")
                self.assertIn(chain5[-1], ("JP ALPHA", "JP ALPHA 2"))
            finally:
                proc.terminate()
                proc.communicate(timeout=5)

    def test_four_stage_escalation_with_shared_probe(self):
        self._run_fail_open_scenario(probe_mode="shared")

    def test_four_stage_escalation_with_query_param_guard_probe(self):
        self._run_fail_open_scenario(probe_mode="query_param")

    def test_four_stage_escalation_with_separate_guard_endpoint_and_multi_leaf(self):
        self._run_fail_open_scenario(probe_mode="separate_endpoint", multi_alpha_leaf=True)


if __name__ == "__main__":
    unittest.main()
