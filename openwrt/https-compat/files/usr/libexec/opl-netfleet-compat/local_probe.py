import asyncio
from pathlib import Path
import secrets
import socket
import ssl

from h2.config import H2Configuration
from h2.connection import H2Connection
from h2.events import RequestReceived


PROXY_PORT = 18444
TLS_PORT = 18445


class LocalProbe:
    def __init__(self, ca_dir):
        self.ca_dir = Path(ca_dir)
        self.server = None

    async def start(self):
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(self.ca_dir / "probe-cert.pem", self.ca_dir / "probe-key.pem")
        context.set_alpn_protocols(["h2"])
        self.server = await asyncio.start_server(self.serve, "", TLS_PORT, ssl=context)

    async def serve(self, reader, writer):
        try:
            connection = H2Connection(config=H2Configuration(client_side=False))
            connection.initiate_connection()
            writer.write(connection.data_to_send())
            await writer.drain()
            while data := await asyncio.wait_for(reader.read(16384), 2):
                for event in connection.receive_data(data):
                    if isinstance(event, RequestReceived):
                        headers = dict(event.headers)
                        body = headers.get(b":path", b"").removeprefix(b"/")
                        if len(body) != 32:
                            return
                        connection.send_headers(event.stream_id, [(b":status", b"200"),
                            (b"content-length", b"32"), (b"x-netfleet-protocol", b"h2")])
                        connection.send_data(event.stream_id, body, end_stream=True)
                writer.write(connection.data_to_send())
                await writer.drain()
        except (OSError, ValueError, asyncio.TimeoutError):
            pass
        finally:
            writer.close()
            try:
                await writer.wait_closed()
            except OSError:
                pass

    async def check(self, family=None):
        writer = None
        sock = None
        try:
            async with asyncio.timeout(1.4):
                host = "::1" if family == socket.AF_INET6 else "127.0.0.1"
                authority = f"[{host}]:{TLS_PORT}" if family == socket.AF_INET6 else f"{host}:{TLS_PORT}"
                if family is None:
                    reader, writer = await asyncio.open_connection(host, PROXY_PORT)
                    writer.write(f"CONNECT {authority} HTTP/1.1\r\nHost: {authority}\r\n\r\n".encode())
                    await writer.drain()
                    if not (await reader.readuntil(b"\r\n\r\n")).startswith(b"HTTP/1.1 200 "):
                        return False
                else:
                    sock = socket.socket(family, socket.SOCK_STREAM)
                    sock.setblocking(False)
                    sock.setsockopt(socket.SOL_SOCKET, getattr(socket, "SO_MARK", 36), 0x02000000)
                    await asyncio.get_running_loop().sock_connect(sock, (host, TLS_PORT))
                    reader, writer = await asyncio.open_connection(sock=sock)
                    sock = None  # StreamWriter owns the socket now.
                context = ssl.create_default_context(cafile=str(self.ca_dir / "mitmproxy-ca-cert.pem"))
                context.set_alpn_protocols(["http/1.1"])
                await writer.start_tls(context, server_hostname="localhost")
                nonce = secrets.token_hex(16).encode()
                writer.write(b"GET /" + nonce + f" HTTP/1.1\r\nHost: {authority}\r\nConnection: close\r\n\r\n".encode())
                await writer.drain()
                headers = await reader.readuntil(b"\r\n\r\n")
                body = await reader.readexactly(32)
                return headers.startswith(b"HTTP/1.1 200 ") and b"x-netfleet-protocol: h2\r\n" in headers.lower() and body == nonce
        except (OSError, ValueError, asyncio.TimeoutError, asyncio.IncompleteReadError):
            return False
        finally:
            if sock:
                sock.close()
            if writer:
                writer.close()

    async def transparent_check(self):
        return all(await asyncio.gather(self.check(socket.AF_INET), self.check(socket.AF_INET6)))

    def close(self):
        if self.server:
            self.server.close()
