import asyncio
import hashlib
import json
import os
from pathlib import Path
import sys
import time

from mitmproxy import ctx

sys.path.insert(0, str(Path(__file__).parent))
from policy import select, validate


class Compatibility:
    def __init__(self):
        self.config = None
        self.revision = None
        self.selected = {}
        self.protocols = {}
        self.active = {}
        self.results = {}
        self.server = None
        self.socket_path = None

    def load(self, loader):
        loader.add_option("netfleet_config", str, "/etc/opl-netfleet/compatibility.json", "NetFleet compatibility configuration")
        loader.add_option("netfleet_socket", str, "/var/run/opl-netfleet-compat/engine.sock", "Private health socket")

    def configure(self, updated):
        if ctx.options.ssl_insecure or ctx.options.upstream_cert or ctx.options.connection_strategy != "lazy":
            raise ValueError("NetFleet requires upstream verification, upstream_cert=false and connection_strategy=lazy")

    def refresh(self):
        try:
            raw = Path(ctx.options.netfleet_config).read_bytes()
            revision = hashlib.sha256(raw).hexdigest()
            if revision != self.revision:
                self.config = validate(json.loads(raw))
                self.revision = revision
            return True
        except (OSError, ValueError, TypeError, KeyError):
            self.config = None
            return False

    async def running(self):
        self.refresh()
        self.socket_path = Path(ctx.options.netfleet_socket)
        self.socket_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.socket_path.unlink(missing_ok=True)
        self.server = await asyncio.start_unix_server(self.health, path=str(self.socket_path), limit=1024)
        os.chmod(self.socket_path, 0o600)

    async def health(self, reader, writer):
        try:
            await asyncio.wait_for(reader.readline(), 1)
            valid = self.refresh()
            writer.write(json.dumps({"service": "netfleet-https-compat", "pid": os.getpid(), "ready": valid,
                                     "revision": self.revision, "active_requests": len(self.active),
                                     "rules": self.results}).encode() + b"\n")
            await writer.drain()
        finally:
            writer.close()
            await writer.wait_closed()

    def tls_clienthello(self, data):
        context = data.context
        host = data.client_hello.sni
        address = context.client.peername[0]
        port = context.server.address[1]
        rule = select(self.config, address, host, port) if self.refresh() else None
        if rule is None or rule["strategy"] == "bypass":
            data.ignore_connection = True
            return
        self.selected[context.client.id] = rule
        data.establish_server_tls_first = False

    def requestheaders(self, flow):
        rule = self.selected.get(flow.client_conn.id)
        if rule is None:
            return
        # Delay upstream TLS until the request type is known; never send an HTTP/1 Upgrade over h2.
        websocket = flow.request.headers.get("upgrade", "").lower() == "websocket"
        self.protocols[flow.client_conn.id] = (b"http/1.1",) if websocket else (b"h2",)
        flow.request.stream = True
        flow.metadata["netfleet_rule"] = rule["id"]
        self.active[flow.id] = flow.client_conn.id

    def tls_start_server(self, data):
        protocols = self.protocols.get(data.context.client.id)
        if protocols:
            # HTTP's connection pool may replace flow.server_conn after requestheaders.
            data.conn.alpn_offers = protocols
            if data.ssl_conn is not None:
                data.ssl_conn.set_alpn_protos(list(protocols))

    def responseheaders(self, flow):
        flow.response.stream = True
        identity = flow.metadata.get("netfleet_rule")
        if identity:
            self.results[identity] = {"at": int(time.time()), "upstream_protocol": flow.server_conn.alpn.decode("ascii") if flow.server_conn.alpn else None,
                                      "http_status": flow.response.status_code,
                                      "transport_error": self.protocols.get(flow.client_conn.id) == (b"h2",) and flow.server_conn.alpn != b"h2"}

    def tls_failed_client(self, data):
        self.tls_failure(data, "client_tls_failed")

    def tls_failed_server(self, data):
        self.tls_failure(data, "upstream_tls_failed")

    def tls_failure(self, data, reason):
        rule = self.selected.get(data.context.client.id)
        if rule:
            self.results[rule["id"]] = {"at": int(time.time()), "transport_error": True, "reason": reason}

    def response(self, flow):
        self.active.pop(flow.id, None)

    def error(self, flow):
        self.active.pop(flow.id, None)
        identity = flow.metadata.get("netfleet_rule") or self.selected.get(flow.client_conn.id, {}).get("id")
        if identity:
            cancelled = not flow.client_conn.connected
            self.results[identity] = {**self.results.get(identity, {}), "at": int(time.time()),
                                      "transport_error": not cancelled, "client_cancelled": cancelled}

    def client_disconnected(self, client):
        self.selected.pop(client.id, None)
        self.protocols.pop(client.id, None)
        for identity in [key for key, value in self.active.items() if value == client.id]:
            self.active.pop(identity, None)

    def done(self):
        if self.server:
            self.server.close()
        if self.socket_path:
            self.socket_path.unlink(missing_ok=True)


addons = [Compatibility()]
