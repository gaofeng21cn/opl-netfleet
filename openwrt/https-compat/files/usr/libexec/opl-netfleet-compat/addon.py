import asyncio
from collections import Counter, deque
import errno
import hashlib
import json
import os
from pathlib import Path
import ssl
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
        self.client_devices = {}
        self.failures = deque(maxlen=100)
        self.failed_tls_clients = set()
        self.connection_errors = {}
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
        self.server = await asyncio.start_unix_server(self.health, path=str(self.socket_path), limit=65536)
        os.chmod(self.socket_path, 0o600)
        if ctx.options.netfleet_local_probe:
            self.probe = LocalProbe(ctx.options.confdir)
            await self.probe.start()

    async def health(self, reader, writer):
        try:
            command = await asyncio.wait_for(reader.readline(), 1)
            valid = self.refresh()
            if command.startswith(b"{"):
                request = json.loads(command)
                probes = await self.probe_upstreams(request) if valid else {}
                writer.write(json.dumps({"service": "netfleet-https-compat", "revision": self.revision,
                                         "probes": probes}).encode() + b"\n")
                await writer.drain()
                return
            processing, transparent = (await asyncio.gather(self.probe.check(), self.probe.transparent_check())
                                       if self.probe and command == b"probe\n" else (None, None))
            clients = {identity for identity, rule in self.selected.items() if rule["id"] != "_health"}
            writer.write(json.dumps({"service": "netfleet-https-compat", "pid": os.getpid(), "ready": valid,
                                     "revision": self.revision, "active_requests": sum(client in clients for client in self.active.values()),
                                     "active_connections": len(self.clients), "processing_chain": processing,
                                     "transparent_chain": transparent,
                                     "clients_by_address": dict(Counter(self.clients.values())),
                                     "clients_by_device": dict(Counter(self.client_devices.values())),
                                     "unassigned_connections": len(self.clients.keys() - self.client_devices.keys()),
                                     "failure_events": list(self.failures),
                                     "observed": self.observed,
                                     "rules": {key: value for key, value in self.results.items() if key != "_health"}}).encode() + b"\n")
            await writer.drain()
        except (OSError, ValueError, asyncio.TimeoutError):
            pass
        finally:
            writer.close()
            try:
                await writer.wait_closed()
            except OSError:
                pass

    async def probe_upstreams(self, request):
        if request.get("command") != "probe_upstreams" or request.get("revision") != self.revision:
            return {}
        rules = request.get("rules")
        if not isinstance(rules, list):
            return {}
        configured = {rule["id"]: rule for rule in self.config["rules"] if rule["enabled"]}
        for rule in rules:
            if not isinstance(rule, dict):
                return {}
            target = configured.get(rule.get("id"))
            host = rule.get("domain")
            if (not target or not isinstance(host, str) or rule.get("port") != target["port"]
                    or not (host == target["domain"] or target["match"] == "suffix" and host.endswith("." + target["domain"]))
                    or not isinstance(rule.get("address", host), str)):
                return {}
        # Run in the engine's cgroup: the lifecycle controller is excluded from Mihomo.
        context = ssl.create_default_context(cafile=ctx.options.ssl_verify_upstream_trusted_ca)
        context.set_alpn_protocols(["h2"])
        async def check(rule):
            writer, started = None, time.monotonic()
            result = {"ok": False, "at": int(time.time()), "timeout_ms": 700}
            try:
                async with asyncio.timeout(0.7):
                    _, writer = await asyncio.open_connection(rule.get("address", rule["domain"]), rule["port"],
                                                              ssl=context, server_hostname=rule["domain"])
                    protocol = writer.get_extra_info("ssl_object").selected_alpn_protocol()
                    result.update(ok=protocol == "h2", protocol=protocol,
                                  reason=None if protocol == "h2" else "upstream_h2_not_negotiated")
            except asyncio.TimeoutError:
                result["reason"] = "upstream_probe_timeout"
            except ssl.SSLCertVerificationError:
                result["reason"] = "upstream_certificate_failed"
            except ssl.SSLError:
                result["reason"] = "upstream_tls_failed"
            except OSError:
                result["reason"] = "upstream_connect_failed"
            finally:
                if writer:
                    writer.close()
            result["duration_ms"] = round((time.monotonic() - started) * 1000)
            return rule["id"], result
        return dict(await asyncio.gather(*(check(rule) for rule in rules)))

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
        # Inbound validation can reject a request before its headers hook runs.
        flow.metadata["netfleet_client_invalid"] = flow.error is not None

    def tls_start_server(self, data):
        protocols = self.protocols.get(data.context.client.id)
        if protocols:
            # HTTP's connection pool may replace flow.server_conn after requestheaders.
            data.conn.alpn_offers = protocols
            if data.ssl_conn is not None:
                data.ssl_conn.set_alpn_protos(list(protocols))

    def server_connect(self, data):
        self.connection_errors.pop(data.client.id, None)
        internal = self.probe and data.client.peername[0] in ("127.0.0.1", "::1") and data.server.address[1] == TLS_PORT
        if ctx.options.netfleet_preserve_source_port and not internal:
            # An unavailable source port must fail the connection, never silently change its route.
            # asyncio resolves a None local host as loopback, not a wildcard bind.
            bind = ctx.options.connect_addr or ("::" if ":" in data.server.address[0] else "0.0.0.0")
            data.server.sockname = (bind, data.client.peername[1])

    def server_connect_error(self, data):
        message = str(data.server.error or "").lower()
        reason = ("client_cancelled" if message == "connection cancelled" else
                  "source_port_unavailable" if "address already in use" in message or f"[errno {errno.EADDRINUSE}]" in message else
                  "upstream_bind_failed" if "error while attempting to bind" in message else
                  "upstream_dns_failed" if any(text in message for text in
                      ("name or service not known", "name resolution", "nodename nor servname")) else
                  "upstream_connection_refused" if "refused" in message or f"[errno {errno.ECONNREFUSED}]" in message else
                  "upstream_unreachable" if "unreachable" in message or any(f"[errno {code}]" in message for code in (errno.ENETUNREACH, errno.EHOSTUNREACH)) else
                  "upstream_timeout" if "timed out" in message or "timeout" in message else
                  "upstream_connect_failed")
        self.connection_errors[data.client.id] = reason

    def tls_established_server(self, data):
        if self.protocols.get(data.context.client.id) == (b"h2",) and data.conn.alpn != b"h2":
            self.tls_failure(data, "upstream_h2_not_negotiated")
            data.ssl_conn.shutdown()

    def responseheaders(self, flow):
        flow.response.stream = True
        identity = flow.metadata.get("netfleet_rule")
        if identity:
            # h2 delimits streams itself. Without h1 framing, each streamed response
            # forces EOF and another pair of TCP/TLS handshakes on the next request.
            if (flow.request.http_version == "HTTP/1.1" and flow.response.is_http2
                    and flow.request.method.upper() not in ("HEAD", "CONNECT")
                    and flow.response.status_code >= 200 and flow.response.status_code not in (204, 304)
                    and "content-length" not in flow.response.headers):
                flow.response.headers["transfer-encoding"] = "chunked"
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
            # A client's trust or handshake failure does not establish an upstream outage.
            if reason != "client_tls_failed":
                self.record_failure(rule["id"], reason)
            self.failed_tls_clients.add(data.context.client.id)

    def record_failure(self, identity, reason, protocol=None, status=None):
        if identity != "_health":
            self.failures.append({"id": time.monotonic_ns(), "rule": identity, "at": time.monotonic(),
                                  "time": int(time.time()), "reason": reason,
                                  "upstream_protocol": protocol, "http_status": status})

    def response(self, flow):
        if flow.response.status_code != 101:
            self.active.pop(flow.id, None)

    def websocket_end(self, flow):
        self.active.pop(flow.id, None)

    def error(self, flow):
        self.active.pop(flow.id, None)
        identity = flow.metadata.get("netfleet_rule") or self.selected.get(flow.client_conn.id, {}).get("id")
        if identity:
            # The error hook may precede the connection-state transition.
            message = str(flow.error.msg if flow.error else "").lower()
            connection_error = self.connection_errors.pop(flow.client_conn.id, None)
            cancelled = (not flow.client_conn.connected or message == "connection cancelled"
                         or message.startswith(("client disconnected", "client closed")))
            reason = ("client_cancelled" if cancelled else
                      "client_request_invalid" if flow.metadata.get("netfleet_client_invalid") else
                      connection_error if connection_error else
                      "upstream_timeout" if "timed out" in message or "timeout" in message else
                      "upstream_connection_reset" if "reset" in message else "upstream_transport_failed")
            connection_only = reason in ("client_cancelled", "client_request_invalid", "source_port_unavailable")
            if not connection_only and flow.client_conn.id not in self.failed_tls_clients:
                protocol = flow.server_conn.alpn.decode("ascii") if flow.server_conn.alpn else None
                self.record_failure(identity, reason, protocol, flow.response.status_code if flow.response else None)
            self.results[identity] = {**self.results.get(identity, {}), "at": int(time.time()),
                                      "event": time.monotonic_ns(),
                                      "transport_error": not cancelled, "client_cancelled": cancelled, "reason": reason}

    def client_connected(self, client):
        internal = client.peername[0] in ("127.0.0.1", "::1") and client.sockname[1] in (18444, TLS_PORT)
        if not internal:
            self.clients[client.id] = client.peername[0]
            if self.refresh():
                devices = [device["id"] for device in self.config["devices"] if client.peername[0] in device["addresses"]]
                if len(devices) == 1:
                    self.client_devices[client.id] = devices[0]

    def client_disconnected(self, client):
        self.clients.pop(client.id, None)
        self.client_devices.pop(client.id, None)
        self.failed_tls_clients.discard(client.id)
        self.connection_errors.pop(client.id, None)
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
