"""HAProxy wire checks against a disposable TLS origin; dependencies belong only to tests."""

import asyncio
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID
from hypercorn.asyncio import serve
from hypercorn.config import Config
import httpx
from wsproto import WSConnection, ConnectionType
from wsproto.events import Request, AcceptConnection, TextMessage, CloseConnection


ROOT = Path(__file__).resolve().parents[1]
ENGINE = ROOT / "openwrt/https-compat/files/usr/libexec/opl-netfleet-compat/haproxy.py"
if not ENGINE.exists():
    ENGINE = Path('/usr/libexec/opl-netfleet-compat/haproxy.py')
sys.path.insert(0, str(ENGINE.parent))
import haproxy
BINARY = os.environ.get('NETFLEET_HAPROXY_BINARY', haproxy.BINARY)


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def certificate(directory):
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, f"NetFleet test {x509.random_serial_number():x}")])
    now = datetime.now(timezone.utc)
    cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
            .public_key(key.public_key()).serial_number(x509.random_serial_number())
            .not_valid_before(now - timedelta(minutes=1)).not_valid_after(now + timedelta(days=1))
            .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
            .add_extension(x509.SubjectAlternativeName([x509.DNSName("localhost"), x509.DNSName("wire.example"), x509.DNSName("other.example")]), critical=False)
            .sign(key, hashes.SHA256()))
    (directory / "upstream.pem").write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    (directory / "upstream.key").write_bytes(key.private_bytes(serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))


class Protocol(unittest.IsolatedAsyncioTestCase):
    BIND = "127.0.0.1"
    DEVICE = "127.0.0.1"
    MODE = "regular"
    PROXY_PORT = None
    ORIGIN_PORT = None

    async def asyncSetUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="netfleet-compat-test-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        certificate(self.directory)
        self.received = []
        self.first_upload = asyncio.Event()
        self.finish_sse = asyncio.Event()
        self.shutdown = asyncio.Event()
        self.upstream_port, self.proxy_port = self.ORIGIN_PORT or free_port(), self.PROXY_PORT or free_port()
        config = Config()
        config.bind = [f"{'[' + self.BIND + ']' if ':' in self.BIND else self.BIND}:{self.upstream_port}"]
        config.certfile = str(self.directory / "upstream.pem")
        config.keyfile = str(self.directory / "upstream.key")
        config.alpn_protocols = ["h2", "http/1.1"]
        if self._testMethodName in ("test_h2_required_upstream_h1_is_not_replayed", "test_upstream_recovery_rejects_h1"):
            config.alpn_protocols = ["http/1.1"]
        config.accesslog = None
        config.errorlog = None
        config.graceful_timeout = 0.2
        self.upstream = asyncio.create_task(serve(self.application, config, shutdown_trigger=self.shutdown.wait))
        self.addAsyncCleanup(self.stop_upstream)
        policy = {"schema": 1, "enabled": True,
                  "devices": [{"id": "mac", "name": "Test Mac", "addresses": [self.DEVICE]}],
                  "rules": [{"id": "test", "name": "Wire test", "enabled": True, "devices": ["mac"],
                             "domain": "localhost", "match": "exact", "port": self.upstream_port, "strategy": "h2"}]}
        self.log = (self.directory / "proxy.log").open("wb")
        self.addCleanup(self.log.close)
        (self.directory / 'engine').mkdir()
        haproxy.prepare_ca(self.directory / 'ca', self.directory / 'upstream.pem')
        if self._testMethodName == 'test_disabled_policy_tunnels_without_decrypting':
            policy['enabled'] = False
        if self._testMethodName == 'test_invalid_upstream_certificate_is_rejected':
            (self.directory / 'ca/upstream-trust.pem').write_bytes((self.directory / 'ca/mitmproxy-ca-cert.pem').read_bytes())
        self.engine_port = self.proxy_port if self.MODE == 'transparent' else free_port()
        if hasattr(self, 'egress'):
            policy['egress'] = self.egress
        if self._testMethodName == 'test_wildcard_source_binds_configured_port_range':
            lower, upper = map(int, Path('/proc/sys/net/ipv4/ip_local_port_range').read_text().split())
            self.source_range = [lower + 128, min(lower + 255, upper)]
            policy['egress'] = {'port_range': self.source_range}
        if self._testMethodName == 'test_generated_certificate_uses_current_tls_security_level':
            policy['rules'][0]['domain'] = 'wire.example'
        (self.directory / 'config.json').write_text(json.dumps(policy))
        text, mapping = haproxy.configuration(policy, self.directory, 'a' * 64, port=self.engine_port)
        (self.directory / 'haproxy.cfg').write_text(text)
        (self.directory / 'haproxy-rules.json').write_text(json.dumps(mapping))
        haproxy.write_rule_map(self.directory, policy, mapping)
        self.proxy = await asyncio.create_subprocess_exec(BINARY, '-db', '-f', str(self.directory / 'haproxy.cfg'),
                                                          stdout=self.log, stderr=self.log)
        self.addAsyncCleanup(self.stop_proxy)
        for _ in range(100):
            if (self.directory / 'engine/engine.sock').exists():
                break
            if self.proxy.returncode is not None:
                self.fail((self.directory / 'proxy.log').read_text())
            await asyncio.sleep(0.05)
        else:
            self.fail('proxy health socket not ready')
        if self.MODE == 'regular':
            # Test-only CONNECT adapter supplies original metadata to the private ingress.
            # Production receives that metadata from Linux NAT, tested by Kernel below.
            self.adapter = await asyncio.start_server(self.tunnel, '127.0.0.1', self.proxy_port)
            self.addAsyncCleanup(self.stop_adapter)
        context = ssl.create_default_context(cafile=str(self.directory / "ca/mitmproxy-ca-cert.pem"))
        context.load_verify_locations(cafile=str(self.directory / "upstream.pem"))
        self.client_context = context
        self.client = httpx.AsyncClient(proxy=f"http://127.0.0.1:{self.proxy_port}", verify=context,
                                       http2=False, timeout=10, trust_env=False)
        self.addAsyncCleanup(self.client.aclose)
        self.url = f"https://localhost:{self.upstream_port}"

    async def stop_proxy(self):
        if self.proxy.returncode is None:
            self.proxy.terminate()
            try:
                await asyncio.wait_for(self.proxy.wait(), 3)
            except asyncio.TimeoutError:
                self.proxy.kill()
                await self.proxy.wait()
        log = (self.directory / "proxy.log").read_text()
        self.assertNotIn("Addon error", log, log)

    async def stop_upstream(self):
        self.finish_sse.set()
        self.shutdown.set()
        await asyncio.wait_for(self.upstream, 3)

    async def stop_adapter(self):
        self.adapter.close()
        await self.adapter.wait_closed()

    async def tunnel(self, reader, writer):
        other = None
        tasks = []
        try:
            header = await reader.readuntil(b'\r\n\r\n')
            self.assertTrue(header.startswith(b'CONNECT '))
            upstream, other = await asyncio.open_unix_connection(str(self.directory / 'engine/probe.sock'))
            other.write(f'PROXY TCP4 127.0.0.1 127.0.0.1 12345 {self.upstream_port}\r\n'.encode())
            await other.drain()
            writer.write(b'HTTP/1.1 200 Connection established\r\n\r\n')
            await writer.drain()
            async def copy(source, destination):
                while data := await source.read(65536):
                    destination.write(data)
                    await destination.drain()
            tasks = [asyncio.create_task(copy(reader, other)), asyncio.create_task(copy(upstream, writer))]
            await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        except (OSError, asyncio.IncompleteReadError):
            pass
        finally:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            if other:
                other.close()
            writer.close()

    async def health(self, probe=False):
        result = await asyncio.to_thread(haproxy.health, self.directory)
        if probe:
            result['local_probes'] = {'private_ingress': await asyncio.to_thread(haproxy.probe, self.directory)}
            result['processing_chain'] = True
        return result

    async def test_upstream_probe_requires_h2_without_business_request(self):
        context = ssl.create_default_context(cafile=str(self.directory / 'upstream.pem'))
        with patch.object(haproxy.ssl, 'create_default_context', return_value=context):
            result = await haproxy.probe_upstreams({'rules': [{'id': 'test', 'domain': 'localhost', 'port': self.upstream_port}]})
        self.assertTrue(result['test']['ok'], result)
        self.assertEqual(self.received, [])

    async def test_upstream_recovery_rejects_h1(self):
        context = ssl.create_default_context(cafile=str(self.directory / 'upstream.pem'))
        with patch.object(haproxy.ssl, 'create_default_context', return_value=context):
            result = await haproxy.probe_upstreams({'rules': [{'id': 'test', 'domain': 'localhost', 'port': self.upstream_port}]})
        self.assertFalse(result['test']['ok'], result)
        self.assertEqual(result['test']['reason'], 'upstream_h2_not_negotiated')
        self.assertEqual(self.received, [])

    async def test_wildcard_source_binds_configured_port_range(self):
        # Conversion and passthrough share the kernel's tuple allocation;
        # independent server port pools can select the same occupied tuple.
        for _ in range(4):
            for host, protocol in (('localhost', '2'), ('other.example', '1.1')):
                response = await self.client.get(f'https://{host}:{self.upstream_port}/source-range')
                self.assertEqual(response.status_code, 200)
                self.assertEqual(self.received[-1]['version'], protocol)
                self.assertTrue(self.source_range[0] <= self.received[-1]['source_port'] <= self.source_range[1], self.received[-1])

    async def test_certificate_renewal_drains_and_preserves_root(self):
        import control
        ca = self.directory / 'ca'
        private, public = (ca / 'mitmproxy-ca.pem').read_bytes(), (ca / 'mitmproxy-ca-cert.pem').read_bytes()
        root = x509.load_pem_x509_certificate(public)
        root_key = serialization.load_pem_private_key(private, password=None)
        leaf = x509.load_pem_x509_certificate((ca / 'probe-cert.pem').read_bytes())
        now = datetime.now(timezone.utc)
        expiring = (x509.CertificateBuilder().subject_name(leaf.subject).issuer_name(root.subject)
                    .public_key(leaf.public_key()).serial_number(x509.random_serial_number())
                    .not_valid_before(now - timedelta(days=1)).not_valid_after(now + timedelta(days=1))
                    .sign(root_key, hashes.SHA256()))
        (ca / 'probe-cert.pem').write_bytes(expiring.public_bytes(serialization.Encoding.PEM))
        real_run, signals = subprocess.run, []
        def execute(args, **kwargs):
            if args[0] == 'ubus':
                signals.append(json.loads(args[-1]))
                return subprocess.CompletedProcess(args, 0)
            return real_run(args, **kwargs)
        effective = self.directory / 'config.json'
        health = {'ready': True, 'pid': self.proxy.pid, 'active_connections': 1,
                  'revision': haproxy.configuration_revision(json.loads(effective.read_bytes()))}
        with patch.multiple(control, CA=ca, EFFECTIVE=effective, _certificate_check=None), \
             patch.object(control.gateway, 'bypass') as bypass, \
             patch.object(control.subprocess, 'run', side_effect=execute):
            self.assertTrue(control.reconcile_engine(health))
            bypass.assert_called_once()
            self.assertEqual(signals, [])
            health['active_connections'] = 0
            self.assertTrue(control.reconcile_engine(health))
            self.assertEqual(signals, [{'name': 'opl-netfleet-compat', 'instance': 'engine', 'signal': 15}])
            haproxy.prepare_ca(ca, self.directory / 'upstream.pem')
            self.assertFalse(control.certificate_refresh_required({**health, 'pid': health['pid'] + 1}))
        self.assertEqual((ca / 'mitmproxy-ca.pem').read_bytes(), private)
        self.assertEqual((ca / 'mitmproxy-ca-cert.pem').read_bytes(), public)

    async def test_generated_certificate_uses_current_tls_security_level(self):
        # localhost uses the configured probe leaf; a new SNI exercises the
        # generated SSL context, including the platform's OpenSSL policy.
        response = await self.client.get(f'https://wire.example:{self.upstream_port}/generated')
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.headers['x-upstream-protocol'], '2')

    async def test_rule_bypass_and_recovery_preserve_engine_and_active_stream(self):
        effective = json.loads((self.directory / 'config.json').read_bytes())
        original_revision = haproxy.configuration_revision(effective)
        health = await self.health()
        async with self.client.stream('GET', self.url + '/sse') as stream:
            chunks = stream.aiter_raw()
            self.assertEqual(await anext(chunks), b'data: first\n\n')
            for blocked, expected_protocol in ((['test'], '1.1'), ([], '2')):
                effective['blocked_rules'] = blocked
                self.assertEqual(haproxy.configuration_revision(effective), original_revision)
                haproxy.sync_rule_switches(self.directory, effective, health)
                async with httpx.AsyncClient(proxy=f'http://127.0.0.1:{self.proxy_port}',
                                             verify=self.client_context, trust_env=False) as client:
                    response = await client.get(self.url + '/rule-switch')
                    self.assertEqual(response.headers['x-upstream-protocol'], expected_protocol)
                self.assertEqual((await self.health())['pid'], health['pid'])
            self.finish_sse.set()
            self.assertEqual(await anext(chunks), b'data: done\n\n')

    async def application(self, scope, receive, send):
        if scope["type"] == "websocket":
            await receive()
            await send({"type": "websocket.accept"})
            message = await receive()
            if message["type"] == "websocket.receive":
                await send({"type": "websocket.send", "text": message["text"]})
                await receive()
            return
        if scope["type"] != "http":
            return
        body = bytearray()
        while True:
            message = await receive()
            if message["type"] == "http.disconnect":
                return
            body.extend(message.get("body", b""))
            if message.get("body"):
                self.first_upload.set()
            if not message.get("more_body"):
                break
        self.received.append({"version": scope["http_version"], "path": scope["path"],
                              "source_port": scope["client"][1],
                              "query": scope["query_string"].decode(), "method": scope["method"],
                              "headers": dict(scope["headers"]), "body": bytes(body)})
        status = int(scope["path"].split("/")[-1]) if scope["path"].startswith("/status/") else 200
        await send({"type": "http.response.start", "status": status,
                    "headers": [(b"content-type", b"text/event-stream" if scope["path"] in ("/sse", "/sse-error") else b"application/json"),
                                (b"x-upstream-protocol", scope["http_version"].encode()), (b"retry-after", b"7")]})
        if scope["path"] == "/sse-error":
            await send({"type": "http.response.body", "body": b'event: response.failed\ndata: {"error":{"code":"server_error","message":"Our servers are currently overloaded. Please try again later."}}\n\n'})
        elif scope["path"] == "/sse":
            await send({"type": "http.response.body", "body": b"data: first\n\n", "more_body": True})
            await self.finish_sse.wait()
            await send({"type": "http.response.body", "body": b"data: done\n\n"})
        else:
            await send({"type": "http.response.body", "body": json.dumps({"bytes": len(body),
                        "sha256": hashlib.sha256(body).hexdigest()}).encode()})

    async def test_status_fingerprint_uses_system_tls_without_signing_imports(self):
        pem = self.directory / "ca/mitmproxy-ca-cert.pem"
        expected = x509.load_pem_x509_certificate(pem.read_bytes()).fingerprint(hashes.SHA256()).hex()
        code = """import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import control
control.CA = Path(sys.argv[2])
print(control.ca_fingerprint())
assert 'cryptography' not in sys.modules
assert 'asyncio' not in sys.modules
assert 'tarfile' not in sys.modules
"""
        def fingerprint():
            result = subprocess.run([sys.executable, "-B", "-c", code, str(ENGINE.parent), str(pem.parent)],
                                    capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            return result.stdout.strip()
        self.assertEqual(fingerprint(), expected)
        original = pem.read_bytes()
        try:
            for damaged in (b"", b"not a certificate", b"-----BEGIN CERTIFICATE-----\nYWJj\n-----END CERTIFICATE-----\n"):
                pem.write_bytes(damaged)
                self.assertEqual(fingerprint(), "None")
        finally:
            pem.write_bytes(original)
        self.assertEqual(fingerprint(), expected)

    async def test_h1_to_h2_upload_errors_and_stream(self):
        body = b"netfleet-test\x00" * (1024 * 1024)
        async def upload():
            yield body[:65536]
            # Upstream must receive data before the caller finishes uploading.
            await asyncio.wait_for(self.first_upload.wait(), 3)
            yield body[65536:]
        response = await self.client.post(self.url + "/arbitrary/images?size=original", content=upload(),
                                          headers={"authorization": "Bearer isolated-test", "x-test": "kept"})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.http_version, "HTTP/1.1")
        self.assertEqual(response.headers["x-upstream-protocol"], "2")
        self.assertEqual(response.json(), {"bytes": len(body), "sha256": hashlib.sha256(body).hexdigest()})
        self.assertEqual(self.received[-1]["query"], "size=original")
        self.assertEqual(self.received[-1]["headers"][b"authorization"], b"Bearer isolated-test")
        for status in (401, 429, 500, 503):
            response = await self.client.get(self.url + f"/status/{status}")
            self.assertEqual(response.status_code, status)
            self.assertEqual(response.headers["retry-after"], "7")
            self.assertFalse((await self.health())["failure_events"])
        response = await self.client.post(self.url + "/image/upload", files={"image": ("image.png", b"\x89PNG\x00image", "image/png")})
        self.assertEqual(response.status_code, 200)
        self.assertIn(b"\x89PNG\x00image", self.received[-1]["body"])
        async with self.client.stream("GET", self.url + "/sse") as stream:
            iterator = stream.aiter_raw()
            first = await asyncio.wait_for(anext(iterator), 2)
            self.assertEqual(first, b"data: first\n\n")
            self.assertFalse(self.finish_sse.is_set())
            self.assertEqual((await self.health())["active_requests"], 1)
        for _ in range(40):
            if (await self.health())["active_requests"] == 0:
                break
            await asyncio.sleep(0.05)
        self.assertEqual((await self.health())["active_requests"], 0)
        self.assertEqual((await self.health())["rules"]["test"]["upstream_protocol"], "h2")
        self.assertEqual((await self.health())["failure_events"], [])

    async def test_application_stream_error_is_forwarded_without_transport_failure(self):
        response = await self.client.get(self.url + "/sse-error")
        self.assertEqual(response.status_code, 200)
        self.assertIn(b"event: response.failed", response.content)
        self.assertIn(b"Our servers are currently overloaded.", response.content)
        health = await self.health()
        self.assertEqual(health["failure_events"], [])
        self.assertFalse(health["failure_events"])

    async def test_streamed_responses_reuse_connections_without_buffering(self):
        self.finish_sse.set()
        for path in ("/download", "/sse", "/status/503", "/download"):
            response = await self.client.get(self.url + path)
            self.assertEqual(response.headers["transfer-encoding"], "chunked")
            self.assertNotIn("content-length", response.headers)
        self.assertEqual(len({request["source_port"] for request in self.received}), 1)
        self.assertEqual((await self.health())["active_connections"], 1)
        for method, path in (("HEAD", "/download"), ("GET", "/status/204"), ("GET", "/status/304")):
            response = await self.client.request(method, self.url + path)
            self.assertNotIn("transfer-encoding", response.headers)
            self.assertEqual(response.content, b"")
        self.assertEqual((await self.client.get(self.url + "/download")).status_code, 200)

    async def test_address_rotation_keeps_old_connection_drain_accounting(self):
        async with self.client.stream("GET", self.url + "/sse") as stream:
            iterator = stream.aiter_raw()
            self.assertEqual(await anext(iterator), b"data: first\n\n")
            config_path = self.directory / "config.json"
            policy = json.loads(config_path.read_text())
            policy["devices"][0]["addresses"] = ["192.0.2.99"]
            config_path.write_text(json.dumps(policy))
            health = await self.health()
            self.assertEqual(health["active_connections"], 1)
            self.assertEqual(health["unassigned_connections"], 1)
            self.assertEqual(health["active_requests"], 1)
            self.finish_sse.set()
            self.assertEqual(await anext(iterator), b"data: done\n\n")
        await self.client.aclose()
        for _ in range(40):
            health = await self.health()
            if health["active_connections"] == 0:
                break
            await asyncio.sleep(0.05)
        self.assertEqual(health["active_connections"], 0)

    async def test_websocket_uses_h1(self):
        reader, writer = await asyncio.open_connection("127.0.0.1", self.proxy_port)
        try:
            host = f"localhost:{self.upstream_port}"
            writer.write(f"CONNECT {host} HTTP/1.1\r\nHost: {host}\r\n\r\n".encode())
            await writer.drain()
            self.assertIn(b"200", await reader.readuntil(b"\r\n\r\n"))
            await writer.start_tls(self.client_context, server_hostname="localhost")
            ws = WSConnection(ConnectionType.CLIENT)
            writer.write(ws.send(Request(host=host, target="/ws")))
            await writer.drain()
            accepted, echoed, closed = False, False, False
            while not closed:
                data = await asyncio.wait_for(reader.read(4096), 3)
                self.assertTrue(data)
                ws.receive_data(data)
                for event in ws.events():
                    if isinstance(event, AcceptConnection):
                        accepted = True
                        writer.write(ws.send(TextMessage(data="wire-check")))
                        await writer.drain()
                    elif isinstance(event, TextMessage):
                        self.assertEqual(event.data, "wire-check")
                        echoed = True
                        writer.write(ws.send(CloseConnection(code=1000)))
                        await writer.drain()
                    elif isinstance(event, CloseConnection):
                        closed = True
            self.assertTrue(accepted)
            self.assertTrue(echoed)
            self.assertEqual((await self.health())['failure_events'], [])
        finally:
            writer.close()
            await writer.wait_closed()

    async def test_client_tls_rejections_do_not_count_as_upstream_outages(self):
        async with httpx.AsyncClient(proxy=f"http://127.0.0.1:{self.proxy_port}",
                                     http2=False, timeout=5, trust_env=False) as untrusted:
            for _ in range(4):
                with self.assertRaises(httpx.ConnectError):
                    await untrusted.get(self.url + "/untrusted-client")
        self.assertEqual(self.received, [])
        health = await self.health()
        self.assertEqual(health["failure_events"], [])
        response = await self.client.get(self.url + "/trusted-client")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.headers["x-upstream-protocol"], "2")

    async def test_invalid_upstream_certificate_is_rejected(self):
        response = await self.client.post(self.url + '/never-upload', content=b'private-body')
        self.assertIn(response.status_code, (502, 503))
        self.assertEqual(self.received, [])
        self.assertTrue((await self.health())['failure_events'])

    async def test_invalid_client_request_does_not_bypass_target(self):
        reader, writer = await asyncio.open_connection("127.0.0.1", self.proxy_port)
        try:
            host = f"localhost:{self.upstream_port}"
            writer.write(f"CONNECT {host} HTTP/1.1\r\nHost: {host}\r\n\r\n".encode())
            await writer.drain()
            self.assertIn(b"200", await reader.readuntil(b"\r\n\r\n"))
            await writer.start_tls(self.client_context, server_hostname="localhost")
            writer.write(f"GET /invalid HTTP/1.1\r\nHost: {host}\r\nContent-Length: invalid\r\nTransfer-Encoding: chunked\r\n\r\n".encode())
            await writer.drain()
            self.assertIn(b"400", await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 3))
        finally:
            writer.close()
            try:
                await writer.wait_closed()
            except ConnectionResetError:
                pass  # Invalid framing may end with a TCP reset after the 400 response.
        self.assertEqual(self.received, [])
        health = await self.health()
        self.assertEqual(health["failure_events"], [])
        self.assertEqual((await self.client.get(self.url + "/valid")).status_code, 200)

    async def test_connect_failure_is_classified_before_tls(self):
        await self.stop_upstream()
        response = await self.client.post(self.url + "/not-replayed", content=b"private-body")
        self.assertIn(response.status_code, (502, 503))
        health = await self.health()
        self.assertEqual(health["failure_events"][-1]["reason"], "upstream_transport_failed")
        self.assertEqual(len(health["failure_events"]), 1)

    async def test_client_source_port_does_not_constrain_egress(self):
        # This client owns its loopback port; a forced wildcard bind would fail.
        response = await self.client.post(self.url + "/once", content=b"private-body")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(len(self.received), 1)
        self.assertEqual(response.headers["x-upstream-protocol"], "2")
        health = await self.health()
        self.assertEqual(health["failure_events"], [])

    async def test_disabled_policy_tunnels_without_decrypting(self):
        path = self.directory / "config.json"
        policy = json.loads(path.read_text())
        policy["enabled"] = False
        path.write_text(json.dumps(policy))
        response = await self.client.get(self.url + "/bypass")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.headers["x-upstream-protocol"], "1.1")
        self.assertEqual((await self.health())['failure_events'], [])

    async def test_h2_capable_client_keeps_origin_certificate(self):
        context = ssl.create_default_context(cafile=str(self.directory / "upstream.pem"))
        async with httpx.AsyncClient(proxy=f"http://127.0.0.1:{self.proxy_port}", verify=context,
                                     http2=True, timeout=10, trust_env=False) as client:
            response = await client.post(self.url + "/already-h2", content=b"native-h2")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.http_version, "HTTP/2")
        self.assertEqual(response.headers["x-upstream-protocol"], "2")
        self.assertEqual((await self.health())['failure_events'], [])

    @unittest.skipUnless(hasattr(socket, "SO_PRIORITY"), "requires Linux socket priority")
    async def test_local_processing_probe(self):
        result = await asyncio.wait_for(self.health(probe=True), 2)
        self.assertTrue(result["processing_chain"])
        self.assertTrue(result['local_probes']['private_ingress']['ok'])
        self.assertEqual(result['active_connections'], 0)

    async def test_h2_required_upstream_h1_is_not_replayed(self):
        response = await self.client.post(self.url + "/no-replay", content=b"must-not-be-replayed")
        self.assertIn(response.status_code, (502, 503))
        self.assertEqual(self.received, [])
        self.assertEqual(len((await self.health())["failure_events"]), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
