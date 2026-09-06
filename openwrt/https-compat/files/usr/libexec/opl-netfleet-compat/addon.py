import asyncio
from collections import Counter, deque
import hashlib
import json
import os
from pathlib import Path
import sys
import time

from mitmproxy import ctx
from mitmproxy.proxy import layers
from mitmproxy.proxy.layers.tls import starts_like_tls_record
from mitmproxy.proxy.mode_specs import TransparentMode

sys.path.insert(0, str(Path(__file__).parent))
from policy import select, validate
from local_probe import LocalProbe, TLS_PORT


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
        self.probe = None
        self.clients = {}
        self.failures = deque(maxlen=100)
        self.failed_tls_clients = set()
        self.observed = {}

    def load(self, loader):
        loader.add_option("netfleet_config", str, "/etc/opl-netfleet/compatibility.json", "NetFleet compatibility configuration")
        loader.add_option("netfleet_socket", str, "/var/run/opl-netfleet-compat/engine.sock", "Private health socket")
        loader.add_option("netfleet_preserve_source_port", bool, False, "Preserve TCP source port for transparent routing")
        loader.add_option("netfleet_local_probe", bool, False, "Enable the private TLS and HTTP processing probe")

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
        if ctx.options.netfleet_local_probe:
            self.probe = LocalProbe(ctx.options.confdir)
            await self.probe.start()

    async def health(self, reader, writer):
        try:
            command = await asyncio.wait_for(reader.readline(), 1)
            valid = self.refresh()
            processing, transparent = (await asyncio.gather(self.probe.check(), self.probe.transparent_check())
                                       if self.probe and command == b"probe\n" else (None, None))
            clients = {identity for identity, rule in self.selected.items() if rule["id"] != "_health"}
            writer.write(json.dumps({"service": "netfleet-https-compat", "pid": os.getpid(), "ready": valid,
                                     "revision": self.revision, "active_requests": sum(client in clients for client in self.active.values()),
                                     "active_connections": len(self.clients), "processing_chain": processing,
                                     "transparent_chain": transparent,
                                     "clients_by_address": dict(Counter(self.clients.values())),
                                     "failure_events": list(self.failures),
                                     "observed": self.observed,
                                     "rules": {key: value for key, value in self.results.items() if key != "_health"}}).encode() + b"\n")
            await writer.drain()
        finally:
            writer.close()
            await writer.wait_closed()

    def tls_clienthello(self, data):
        context = data.context
        host = data.client_hello.sni
        address = context.client.peername[0]
        port = context.server.address[1]
        if any(kind == 0xFE0D for kind, _ in data.client_hello.extensions):
            data.ignore_connection = True
            return
        internal = self.probe and address in ("127.0.0.1", "::1") and host == "localhost" and port == TLS_PORT
        rule = {"id": "_health", "strategy": "h2"} if internal else (select(self.config, address, host, port) if self.refresh() else None)
        if rule is None or rule["strategy"] == "bypass" or (not internal and b"h2" in data.client_hello.alpn_protocols):
            data.ignore_connection = True
            return
        self.selected[context.client.id] = rule
        if not internal:
            self.observed[rule["id"]] = {"domain": host, "address": context.server.address[0], "port": port}
        data.establish_server_tls_first = False

    def next_layer(self, data):
        # Candidate ports may also carry plaintext or unknown protocols.
        if (isinstance(data.context.client.proxy_mode, TransparentMode)
                and data.context.client.id not in self.selected and len(data.data_client()) >= 3
                and not starts_like_tls_record(data.data_client())):
            data.layer = layers.TCPLayer(data.context, ignore=True)

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
        flow.metadata["netfleet_websocket"] = websocket

    def tls_start_server(self, data):
        protocols = self.protocols.get(data.context.client.id)
        if protocols:
            # HTTP's connection pool may replace flow.server_conn after requestheaders.
            data.conn.alpn_offers = protocols
            if data.ssl_conn is not None:
                data.ssl_conn.set_alpn_protos(list(protocols))

    def server_connect(self, data):
        internal = self.probe and data.client.peername[0] in ("127.0.0.1", "::1") and data.server.address[1] == TLS_PORT
        if ctx.options.netfleet_preserve_source_port and not internal:
            # An unavailable source port must fail the connection, never silently change its route.
            # asyncio resolves a None local host as loopback, not a wildcard bind.
            bind = ctx.options.connect_addr or ("::" if ":" in data.server.address[0] else "0.0.0.0")
            data.server.sockname = (bind, data.client.peername[1])

    def tls_established_server(self, data):
        if self.protocols.get(data.context.client.id) == (b"h2",) and data.conn.alpn != b"h2":
            self.tls_failure(data, "upstream_h2_not_negotiated")
            data.ssl_conn.shutdown()

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
        if rule and data.context.client.id not in self.failed_tls_clients:
            self.results[rule["id"]] = {"at": int(time.time()), "event": time.monotonic_ns(), "transport_error": True, "reason": reason}
            self.record_failure(rule["id"])
            self.failed_tls_clients.add(data.context.client.id)

    def record_failure(self, identity):
        if identity != "_health":
            self.failures.append({"id": time.monotonic_ns(), "rule": identity, "at": time.monotonic()})

    def response(self, flow):
        if flow.response.status_code != 101:
            self.active.pop(flow.id, None)

    def websocket_end(self, flow):
        self.active.pop(flow.id, None)

    def error(self, flow):
        self.active.pop(flow.id, None)
        identity = flow.metadata.get("netfleet_rule") or self.selected.get(flow.client_conn.id, {}).get("id")
        if identity:
            cancelled = not flow.client_conn.connected
            if not cancelled and flow.client_conn.id not in self.failed_tls_clients:
                self.record_failure(identity)
            self.results[identity] = {**self.results.get(identity, {}), "at": int(time.time()),
                                      "event": time.monotonic_ns(),
                                      "transport_error": not cancelled, "client_cancelled": cancelled}

    def client_connected(self, client):
        internal = client.peername[0] in ("127.0.0.1", "::1") and client.sockname[1] in (18444, TLS_PORT)
        if not internal:
            self.clients[client.id] = client.peername[0]

    def client_disconnected(self, client):
        self.clients.pop(client.id, None)
        self.failed_tls_clients.discard(client.id)
        self.selected.pop(client.id, None)
        self.protocols.pop(client.id, None)
        for identity in [key for key, value in self.active.items() if value == client.id]:
            self.active.pop(identity, None)

    def done(self):
        if self.probe:
            self.probe.close()
        if self.server:
            self.server.close()
        if self.socket_path:
            self.socket_path.unlink(missing_ok=True)


addons = [Compatibility()]
