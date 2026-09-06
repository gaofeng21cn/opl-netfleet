"""Isolated wire checks; run with uv run --with mitmproxy==12.2.3 --with hypercorn --with httpx python tests/https_compat_protocol.py."""

import asyncio
from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path
import shutil
import socket
import ssl
import tempfile
import time
import unittest

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
ADDON = ROOT / "openwrt/https-compat/files/usr/libexec/opl-netfleet-compat/addon.py"


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
            .add_extension(x509.SubjectAlternativeName([x509.DNSName("localhost"), x509.DNSName("other.example")]), critical=False)
            .sign(key, hashes.SHA256()))
    (directory / "upstream.pem").write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    (directory / "upstream.key").write_bytes(key.private_bytes(serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))


class Protocol(unittest.IsolatedAsyncioTestCase):
    BIND = "127.0.0.1"
    DEVICE = "127.0.0.1"
    MODE = "regular"
    PROXY_PORT = None
    PRESERVE_SOURCE_PORT = False

    async def asyncSetUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="netfleet-compat-test-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        certificate(self.directory)
        self.received = []
        self.first_upload = asyncio.Event()
        self.finish_sse = asyncio.Event()
        self.shutdown = asyncio.Event()
        self.upstream_port, self.proxy_port = free_port(), self.PROXY_PORT or free_port()
        config = Config()
        config.bind = [f"{'[' + self.BIND + ']' if ':' in self.BIND else self.BIND}:{self.upstream_port}"]
        config.certfile = str(self.directory / "upstream.pem")
        config.keyfile = str(self.directory / "upstream.key")
        config.alpn_protocols = ["h2", "http/1.1"]
        if self._testMethodName == "test_h2_required_upstream_h1_is_not_replayed":
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
        (self.directory / "config.json").write_text(json.dumps(policy))
        self.log = (self.directory / "proxy.log").open("wb")
        self.addCleanup(self.log.close)
        extra = []
        trusted_ca = self.directory / "upstream.pem"
        if self._testMethodName == "test_local_processing_probe":
            from mitmproxy.certs import CertStore
            store = CertStore.from_store(self.directory / "ca", "mitmproxy", 2048)
            entry = store.get_cert("localhost", [x509.DNSName("localhost")])
            (self.directory / "ca/probe-cert.pem").write_bytes(entry.cert.to_pem())
            (self.directory / "ca/probe-key.pem").write_bytes(entry.privatekey.private_bytes(serialization.Encoding.PEM,
                serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
            trusted_ca = self.directory / "trusted.pem"
            trusted_ca.write_bytes((self.directory / "upstream.pem").read_bytes() + (self.directory / "ca/mitmproxy-ca-cert.pem").read_bytes())
            extra = ["--mode", "regular@127.0.0.1:18444", "--set", "netfleet_local_probe=true"]
        self.proxy = await asyncio.create_subprocess_exec(shutil.which("mitmdump"),
            "--listen-host", self.BIND, "--listen-port", str(self.proxy_port), "--mode", self.MODE,
            "-s", str(ADDON), "--set", "upstream_cert=false", "--set", "connection_strategy=lazy",
            "--set", f"netfleet_preserve_source_port={str(self.PRESERVE_SOURCE_PORT).lower()}",
            "--set", f"confdir={self.directory / 'ca'}", "--set", "flow_detail=0",
            "--set", f"ssl_verify_upstream_trusted_ca={trusted_ca}",
            "--set", f"netfleet_config={self.directory / 'config.json'}",
            "--set", f"netfleet_socket={self.directory / 'engine.sock'}",
            *extra,
            stdout=self.log, stderr=self.log)
        self.addAsyncCleanup(self.stop_proxy)
        for _ in range(100):
            if (self.directory / "engine.sock").exists():
                break
            if self.proxy.returncode is not None:
                self.fail((self.directory / "proxy.log").read_text())
            await asyncio.sleep(0.05)
        else:
            self.fail("proxy health socket not ready")
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

    async def health(self, probe=False):
        reader, writer = await asyncio.open_unix_connection(str(self.directory / "engine.sock"))
        writer.write(b"probe\n" if probe else b"status\n")
        await writer.drain()
        data = json.loads(await reader.readline())
        writer.close()
        await writer.wait_closed()
        return data

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
                    "headers": [(b"content-type", b"text/event-stream" if scope["path"] == "/sse" else b"application/json"),
                                (b"x-upstream-protocol", scope["http_version"].encode()), (b"retry-after", b"7")]})
        if scope["path"] == "/sse":
            await send({"type": "http.response.body", "body": b"data: first\n\n", "more_body": True})
            await self.finish_sse.wait()
            await send({"type": "http.response.body", "body": b"data: done\n\n"})
        else:
            await send({"type": "http.response.body", "body": json.dumps({"bytes": len(body),
                        "sha256": hashlib.sha256(body).hexdigest()}).encode()})

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
        for status in (401, 429, 500):
            response = await self.client.get(self.url + f"/status/{status}")
            self.assertEqual(response.status_code, status)
            self.assertEqual(response.headers["retry-after"], "7")
            self.assertFalse((await self.health())["rules"]["test"]["transport_error"])
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
            self.assertEqual((await self.health())["rules"]["test"]["upstream_protocol"], "http/1.1")
        finally:
            writer.close()
            await writer.wait_closed()

    async def test_invalid_upstream_certificate_is_rejected(self):
        # The server has already loaded its certificate; change only the proxy's trust anchor.
        await asyncio.sleep(0.05)
        (self.directory / "upstream.pem").write_bytes((self.directory / "ca/mitmproxy-ca-cert.pem").read_bytes())
        response = await self.client.post(self.url + "/never-upload", content=b"private-body")
        self.assertEqual(response.status_code, 502)
        self.assertEqual(self.received, [])
        self.assertTrue((await self.health())["rules"]["test"]["transport_error"])

    async def test_disabled_policy_tunnels_without_decrypting(self):
        path = self.directory / "config.json"
        policy = json.loads(path.read_text())
        policy["enabled"] = False
        path.write_text(json.dumps(policy))
        response = await self.client.get(self.url + "/bypass")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.headers["x-upstream-protocol"], "1.1")
        self.assertEqual((await self.health())["rules"], {})

    async def test_local_processing_probe(self):
        result = await asyncio.wait_for(self.health(probe=True), 2)
        self.assertTrue(result["processing_chain"])
        self.assertEqual(result["active_connections"], 0)
        self.assertEqual(result["rules"], {})

    async def test_h2_required_upstream_h1_is_not_replayed(self):
        response = await self.client.post(self.url + "/no-replay", content=b"must-not-be-replayed")
        self.assertEqual(response.status_code, 502)
        self.assertEqual(self.received, [])
        self.assertEqual(len((await self.health())["failure_events"]), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
