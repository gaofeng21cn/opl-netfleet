"""Exercise the shipped in-process health reader against real UDP sockets."""
import os
import http.server
import json
from pathlib import Path
import shutil
import socket
import subprocess
import threading
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / "plugins/mihomo/lib/health.uc"
UCODE = os.environ.get("UCODE") or shutil.which("ucode")


@unittest.skipUnless(UCODE, "ucode required (also exercised by OpenWrt qualification)")
class BackendHealthTests(unittest.TestCase):
    def test_gateway_batches_route_reads_and_rejects_partial_or_failed_observations(self):
        source = (ROOT / 'plugins/mihomo/lib/gateway.uc').read_text()
        implementation = source[source.index('routes_present = function('):source.index('readiness = function(')]
        with tempfile.TemporaryDirectory() as directory:
            fake_ip = Path(directory) / 'ip'
            for failure in ['', '-4 rule', '-6 route', 'error']:
                with self.subTest(failure=failure):
                    fake_ip.write_text('#!/bin/sh\n'
                        f'case "$1 $2" in "{failure}") exit 0 ;; esac\n'
                        'case "$2" in rule) echo "100: from all lookup 11900" ;; '
                        'route) echo "local default dev lo" ;; esac\n'
                        + ('exit 1\n' if failure == 'error' else 'exit 0\n'))
                    fake_ip.chmod(0o700)
                    code = '''let routes_present, calls = 0;
                        function shell_quote(value) { return "'" + replace(value, "'", "'\\\\''") + "'"; }
                        function capture_process(command, seconds) {
                            calls++; assert(seconds == 5);
                            return {status: system('PATH=' + shell_quote(DIRECTORY) + ':"$PATH" /bin/sh -c ' + shell_quote(command))};
                        }
                    '''.replace('DIRECTORY', json.dumps(directory))
                    result = json.loads(self.run_ucode(code + implementation + '''
                        printf('%J', {ok: routes_present({table: '11900', families: [4, 6]}), calls});
                    ''', health=False))
                    self.assertEqual(result, {'ok': not failure, 'calls': 1})

    def test_terse_nft_snapshot_preserves_rules_and_rejects_failed_reads(self):
        expressions = [
            {"match": {"left": {"meta": {"key": "nfproto"}}, "op": "==", "right": "ipv6"}},
            {"tproxy": {"port": 7893}}, {"redirect": {"port": 1053}},
            {"match": {"left": {"payload": {"protocol": "ip", "field": "saddr"}},
                       "op": "in", "right": "@devices"}},
        ]
        records = [{"table": {"family": "inet", "name": "fixture"}},
                   {"chain": {"name": "forward"}},
                   {"rule": {"chain": "forward", "expr": expressions}},
                   {"set": {"name": "devices", "type": "ipv4_addr"}}]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload, args = root / 'snapshot.json', root / 'args'
            command = root / 'nft'
            env = dict(os.environ, PATH=directory + os.pathsep + os.environ['PATH'])
            for data, status, expected in [
                (json.dumps({"nftables": records}), 0,
                 {"present": True, "chains": {"forward": expressions}}),
                (json.dumps({"nftables": records[:2]}), 0,
                 {"present": True, "chains": {"forward": []}}),
                (json.dumps({"nftables": []}), 0, {"present": False, "chains": {}}),
                ('broken', 0, {"present": False, "chains": {}}),
                (json.dumps({"nftables": records}), 1, {"present": False, "chains": {}}),
            ]:
                with self.subTest(status=status, data=data):
                    payload.write_text(data)
                    command.write_text('#!/bin/sh\n' +
                                       f'echo "$*" > "{args}"\ncat "{payload}"\nexit {status}\n')
                    command.chmod(0o700)
                    result = json.loads(self.run_ucode(
                        'printf("%J", h.rule_snapshot("fixture"));', env=env))
                    self.assertEqual(result, expected)
                    self.assertEqual(args.read_text().strip(), '-j -t list table inet fixture')

    def test_candidate_reset_retries_only_transient_failures_and_keeps_diagnostics(self):
        module = ROOT / 'plugins/mihomo/lib/controller.uc'
        for replies, expected, attempts in [([204], True, 1), ([503, 204], True, 2),
                                            ([None, 204], True, 2), ([404], False, 1),
                                            ([401], False, 1), ([503, 503], False, 2)]:
            with self.subTest(replies=replies):
                seen = []

                class Handler(http.server.BaseHTTPRequestHandler):
                    def do_DELETE(self):
                        seen.append(self.path)
                        status = replies[len(seen) - 1]
                        if status is not None:
                            self.send_response(status)
                            self.end_headers()
                            self.wfile.write(b'private-response-must-not-leak')
                        self.close_connection = True

                    def log_message(self, *_args):
                        pass

                server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
                worker = threading.Thread(target=server.serve_forever, kwargs={'poll_interval': 0.01}, daemon=True)
                worker.start()
                try:
                    result = json.loads(self.run_ucode(f'''
                        const factory = loadfile({json.dumps(str(module))})();
                        const api = factory({{ use: name => name == "platform.runtime"
                          ? {{ API: "http://127.0.0.1:{server.server_port}", RUN_DIR: "/tmp" }}
                          : name == "platform.process" ? {{ shell_quote: value => sprintf("%J", value) }} : {{}} }});
                        const detail = {{}};
                        printf("%J", {{ ok: api.unfix("fixture", "candidate/group", detail), detail }});
                    ''', health=False))
                    self.assertEqual(result['ok'], expected)
                    self.assertEqual(result['detail']['attempts'], attempts)
                    self.assertEqual(result['detail']['http_status'], replies[-1])
                    self.assertEqual(seen, ['/proxies/candidate%2Fgroup'] * attempts)
                    self.assertNotIn('private-response', json.dumps(result))
                finally:
                    server.shutdown()
                    server.server_close()
                    worker.join()

    def run_ucode(self, body, health=True, env=None):
        args = [UCODE]
        if os.environ.get("UCODE_LIB"):
            args += ["-L", os.environ["UCODE_LIB"]]
        prefix = f'import * as h from "{MODULE}"; ' if health else ''
        result = subprocess.run(args + ["-e", prefix + body],
                                text=True, capture_output=True, timeout=4, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def probe(self, response, timeout_ms=None):
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
                args = f'{server.getsockname()[1]}, {timeout_ms}' if timeout_ms else f'{server.getsockname()[1]}'
                result = self.run_ucode(f'print(h.dns_ready({args}));')
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
        result, elapsed = self.probe(lambda q: None, timeout_ms=150)
        self.assertEqual(result, "false")
        self.assertGreaterEqual(elapsed, 0.12)
        self.assertLess(elapsed, 1.5)

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

    def test_native_http_handles_json_chunked_unix_limits_and_concurrent_providers(self):
        http_module = ROOT / 'plugins/mihomo/lib/http.uc'
        controller_module = ROOT / 'plugins/mihomo/lib/controller.uc'
        latency_module = ROOT / 'plugins/mihomo/lib/latency.uc'
        seen = []
        state = {'seq': 0}

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def do_GET(self):
                seen.append(('GET', self.path, self.headers.get('Authorization')))
                try:
                    if self.path == '/chunked':
                        body = json.dumps({"ok": True, "label": "香港节点"}).encode('utf-8')
                        self.send_response(200)
                        self.send_header('Transfer-Encoding', 'chunked')
                        self.send_header('Connection', 'close')
                        self.end_headers()
                        self.wfile.write(f"{len(body):x}\r\n".encode('ascii') + body + b"\r\n0\r\n\r\n")
                    elif self.path == '/large':
                        body = b'x' * 4096
                        self.send_response(200)
                        self.send_header('Content-Length', str(len(body)))
                        self.send_header('Connection', 'close')
                        self.end_headers()
                        self.wfile.write(body)
                    elif self.path == '/slow':
                        time.sleep(0.15)
                        self.send_response(204)
                        self.send_header('Connection', 'close')
                        self.end_headers()
                    elif self.path.startswith('/providers/proxies/'):
                        if 'fail' in self.path:
                            self.send_response(503)
                            self.send_header('Connection', 'close')
                            self.end_headers()
                        else:
                            time.sleep(0.04)
                            self.send_response(204)
                            self.send_header('Connection', 'close')
                            self.end_headers()
                    elif self.path.startswith('/group/') and '/delay?' in self.path:
                        group_name = self.path[len('/group/'):].split('/delay?', 1)[0]
                        if group_name == 'fail-group':
                            self.send_response(503)
                            body = b'{"message":"down"}\n'
                        else:
                            body = json.dumps({group_name: 42, f"{group_name}-leaf": 37}).encode('utf-8')
                            self.send_response(200)
                        self.send_header('Content-Length', str(len(body)))
                        self.send_header('Connection', 'close')
                        self.end_headers()
                        self.wfile.write(body)
                    elif self.path.startswith('/proxies/preferred-') and '/delay?' in self.path:
                        state['seq'] += 1
                        if self.path.startswith('/proxies/preferred-down/'):
                            self.send_response(503)
                            body = b'{"message":"down"}\n'
                        elif self.path.startswith('/proxies/preferred-zero/'):
                            # Mihomo can round a real fast URLTest to zero delay and still return 503.
                            self.send_response(503)
                            body = b''
                        elif self.path.startswith('/proxies/preferred-method/'):
                            if 'expected=404' in self.path:
                                state['method_alive'] = True
                                self.send_response(200)
                                body = b'{"delay":1}\n'
                            else:
                                state['method_alive'] = False
                                self.send_response(503)
                                body = b'{"message":"status mismatch"}\n'
                        else:
                            self.send_response(200)
                            body = b'{"delay":1}\n'
                        self.send_header('Content-Length', str(len(body)))
                        self.send_header('Connection', 'close')
                        self.end_headers()
                        if body:
                            self.wfile.write(body)
                    elif self.path.startswith('/proxies/preferred-'):
                        group = self.path.rsplit('/', 1)[-1]
                        alive = group == 'preferred-1024' or group == 'preferred-zero' or (group == 'preferred-method' and state.get('method_alive'))
                        value = {
                            'extra': {'https://probe.invalid/health': {
                                'alive': alive,
                                'history': [{'time': f'2026-11-24T00:00:{state["seq"]:02d}Z', 'delay': 0}] if alive else []
                            }},
                            'padding': ''
                        }
                        if group == 'preferred-1024':
                            body = json.dumps(value)
                            value['padding'] = 'a' * (1024 - len(body.encode('utf-8')))
                            raw = json.dumps(value).encode('utf-8')
                            assert len(raw) == 1024
                        else:
                            raw = json.dumps(value).encode('utf-8')
                        self.send_response(200)
                        self.send_header('Content-Length', str(len(raw) + 1))
                        self.send_header('Connection', 'close')
                        self.end_headers()
                        self.wfile.write(raw + b'\n')
                    else:
                        body = b'{"version":"1.19.30"}'
                        self.send_response(200)
                        self.send_header('Content-Length', str(len(body)))
                        self.send_header('Connection', 'close')
                        self.end_headers()
                        self.wfile.write(body)
                except BrokenPipeError:
                    pass
                self.close_connection = True

            def do_PUT(self):
                length = int(self.headers.get('Content-Length', '0'))
                payload = self.rfile.read(length).decode('utf-8')
                seen.append(('PUT', self.path, json.loads(payload)))
                self.send_response(204)
                self.send_header('Connection', 'close')
                self.end_headers()
                self.close_connection = True

            def log_message(self, *_args):
                pass

        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        worker = threading.Thread(target=server.serve_forever, kwargs={'poll_interval': 0.01}, daemon=True)
        worker.start()

        with tempfile.TemporaryDirectory(prefix='nf-unix-', dir='/tmp') as sock_dir:
            sock_path = Path(sock_dir) / 'ctrl.sock'

            def serve_unix():
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as srv:
                    srv.bind(str(sock_path))
                    srv.listen(4)
                    conn, _ = srv.accept()
                    with conn:
                        conn.recv(1024)
                        body = b'{"version":"unix-ok"}'
                        conn.sendall(
                            b'HTTP/1.1 200 OK\r\nContent-Length: ' + str(len(body)).encode('ascii') +
                            b'\r\nConnection: close\r\n\r\n' + body
                        )

            unix_thread = threading.Thread(target=serve_unix, daemon=True)
            unix_thread.start()
            try:
                base = f"http://127.0.0.1:{server.server_port}"
                result = json.loads(self.run_ucode(f'''
                    import {{ request as http_request }} from {json.dumps(str(http_module))};
                    const ctrl_factory = loadfile({json.dumps(str(controller_module))})();
                    const lat_factory = loadfile({json.dumps(str(latency_module))})();
                    const services = {{
                        "platform.runtime": {{ API: {json.dumps(base)}, RUN_DIR: "/tmp" }},
                        "platform.process": {{ shell_quote: v => sprintf("%J", v) }},
                        "platform.credentials": {{ api_secret: () => "sec", proxy_authentication: () => null }}
                    }};
                    const ctrl = ctrl_factory({{ use: name => services[name] }});
                    services["mihomo.controller"] = ctrl;
                    const lat = lat_factory({{ use: name => services[name] }});

                    const path_down = ctrl.test_group_path("sec", "preferred-down", {{ latency: {{ url: "https://probe.invalid/health", timeout_ms: 1000, expected_status: 200 }} }});
                    const path_1024 = ctrl.test_group_path("sec", "preferred-1024", {{ latency: {{ url: "https://probe.invalid/health", timeout_ms: 1000, expected_status: 200 }} }});
                    const path_zero = ctrl.test_group_path("sec", "preferred-zero", {{ latency: {{ url: "https://probe.invalid/health", timeout_ms: 1000, expected_status: 200 }} }});
                    const path_404 = ctrl.test_group_path("sec", "preferred-method", {{ latency: {{ url: "https://probe.invalid/health", timeout_ms: 1000, expected_status: 404 }} }});
                    const path_200_mismatch = ctrl.test_group_path("sec", "preferred-method", {{ latency: {{ url: "https://probe.invalid/health", timeout_ms: 1000, expected_status: 200 }} }});

                    const ver = ctrl.controller_version("sec", 2);
                    const chunked = json(http_request({json.dumps(base)}, {{ path: "/chunked" }}).body);
                    const sel = ctrl.select("sec", "海外 出口", "香港");
                    const unix_ver = json(http_request({{ unix_path: {json.dumps(str(sock_path))} }}, {{ path: "/version" }}).body).version;
                    const oversized = http_request({json.dumps(base)}, {{ path: "/large", max_bytes: 512 }});
                    const timed = http_request({json.dumps(base)}, {{ path: "/slow", timeout_ms: 60 }});
                    const ok_all = lat.measure_providers("sec", ["alpha", "beta", "gamma"], {{ provider_healthcheck_timeout_ms: 2000 }});
                    const partial = lat.measure_providers("sec", ["alpha", "fail_src", "beta"], {{ provider_healthcheck_timeout_ms: 2000 }});
                    const group_single = lat.measure("sec", "selector-main", {{
                        provider_healthcheck_timeout_ms: 20000,
                        latency: {{ method: "mihomo_delay", url: "https://probe.invalid/204", timeout_ms: 1500, expected_status: 204 }}
                    }});
                    const group_batch = lat.measure_groups("sec", ["g1", "g2", "g3", "fail-group", "g4", "g5"], {{
                        provider_healthcheck_timeout_ms: 20000,
                        latency: {{ method: "mihomo_delay", url: "https://probe.invalid/204", timeout_ms: 1500, expected_status: 204 }}
                    }});
                    const budget_20s = lat.controller_timeout_seconds(20000);
                    const budget_cap = lat.controller_timeout_seconds(60000);
                    printf("%J", {{ path_down, path_1024, path_zero, path_404, path_200_mismatch, ver, chunked, sel, unix_ver, oversized: oversized.transport_error, timed: timed.transport_error, ok_all, partial, group_single, group_batch, budget_20s, budget_cap }});
                ''', health=False))
                self.assertFalse(result['path_down'])
                self.assertTrue(result['path_1024'])
                self.assertTrue(result['path_zero'])
                self.assertTrue(result['path_404'])
                self.assertFalse(result['path_200_mismatch'])
                self.assertEqual(result['ver'], '1.19.30')
                self.assertEqual(result['chunked'], {'ok': True, 'label': '香港节点'})
                self.assertTrue(result['sel'])
                self.assertEqual(result['unix_ver'], 'unix-ok')
                self.assertEqual(result['oversized'], 'response_too_large')
                self.assertEqual(result['timed'], 'timeout')
                self.assertTrue(result['ok_all'])
                self.assertFalse(result['partial'])
                self.assertEqual(result['budget_20s'], 23)
                self.assertEqual(result['budget_cap'], 45)
                self.assertEqual(result['group_single']['results']['selector-main-leaf']['delay_ms'], 37)
                self.assertEqual(result['group_batch']['status'], 'ok')
                for g in ('g1', 'g2', 'g3', 'g4', 'g5'):
                    self.assertEqual(result['group_batch']['results'][g]['delay_ms'], 42)
                self.assertNotIn('fail-group', result['group_batch']['results'])
                self.assertIn(('GET', '/group/selector-main/delay?url=https%3A%2F%2Fprobe.invalid%2F204&timeout=1500&expected=204', 'Bearer sec'), seen)
                self.assertIn(('PUT', '/proxies/%E6%B5%B7%E5%A4%96%20%E5%87%BA%E5%8F%A3', {'name': '香港'}), seen)
                self.assertIn(('GET', '/providers/proxies/gamma/healthcheck', 'Bearer sec'), seen)
            finally:
                server.shutdown()
                server.server_close()
                worker.join()
                unix_thread.join(timeout=2)
