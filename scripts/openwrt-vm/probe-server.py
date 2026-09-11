"""TLS fixtures run on the host; never installed in the OpenWrt guest."""
import http.server
import hashlib
import json
import ssl
import sys
import time
from urllib.parse import urlsplit, parse_qs


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        if not self.path.startswith('/compat-wire/echo'):
            self.send_error(404)
            return
        digest, size = hashlib.sha256(), 0
        chunked = self.headers.get('Transfer-Encoding', '').lower() == 'chunked'
        remaining = int(self.headers.get('Content-Length', '0'))
        while chunked or remaining:
            if chunked:
                remaining = int(self.rfile.readline(128).split(b';')[0], 16)
                if remaining == 0:
                    while self.rfile.readline(8192).strip():
                        pass
                    break
            while remaining:
                data = self.rfile.read(min(65536, remaining))
                if not data:
                    return
                digest.update(data)
                size += len(data)
                remaining -= len(data)
                if size > 32 * 1024 * 1024:
                    self.send_error(413)
                    return
            if chunked and self.rfile.read(2) != b'\r\n':
                return
        body = json.dumps({'bytes': size, 'sha256': digest.hexdigest(), 'path': self.path,
                           'content_type': self.headers.get('Content-Type'), 'method': self.command}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    # Mihomo URLTest uses HEAD; curl business probes use GET.
    def do_HEAD(self):
        self.send_response(204)
        self.end_headers()

    def do_GET(self):
        url = urlsplit(self.path)
        if url.path == '/native-workload/payload':
            size = 8 * 1024 * 1024
            self.send_response(200)
            self.send_header('Content-Length', str(size))
            self.end_headers()
            block = b'N' * 65536
            for _ in range(size // len(block)):
                self.wfile.write(block)
            return
        if url.path == '/native-workload/events':
            events = [f'data: {number}\n\n'.encode() for number in range(30)]
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            # This finite fixture must finish at an HTTP boundary. An abrupt TLS
            # EOF is not a successful stream completion for OpenWrt's mbedTLS curl.
            self.send_header('Content-Length', str(sum(map(len, events))))
            self.end_headers()
            for event in events:
                self.wfile.write(event)
                self.wfile.flush()
                time.sleep(1)
            return
        if url.path in ('/compat-wire/events', '/compat-wire/drain-events'):
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Cache-Control', 'no-cache')
            self.end_headers()
            try:
                for number in range(30):
                    self.wfile.write(f'data: {number}\n\n'.encode())
                    self.wfile.flush()
                    time.sleep(0.5 if url.path.endswith('/drain-events') else 0.1)
            except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
                pass
            return
        if url.path in ('/compat-wire/401', '/compat-wire/429'):
            self.send_response(int(url.path.rsplit('/', 1)[1]))
            self.send_header('Retry-After', '7')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if url.path.startswith("/native-subscriptions/"):
            if parse_qs(url.query).get("token") != ["vm-only-credential"]:
                self.send_error(403)
                return
            kind = url.path.rsplit("/", 1)[-1]
            if kind == "redirect":
                self.send_response(302)
                self.send_header("Location", "http://127.0.0.1/blocked-downgrade")
                self.end_headers()
                return
            if kind == "missing":
                self.send_error(404)
                return
            body = json.dumps({"proxies": [{"name": "native-region-node", "type": "socks5",
                "server": "127.0.0.1", "port": 1081, "udp": True}],
                "dns": {"enable": True, "nameserver": ["udp://127.0.0.1:1054"]},
                "mixed-port": 1111, "rules": ["MATCH,REJECT"]}).encode()
            if kind == "setup":
                body = json.dumps({"proxies": [{"name": "JP Japan setup-node", "type": "socks5",
                    "server": "198.18.1.2", "port": 1081, "udp": True}],
                    "proxy-groups": [{"name": "Outbound", "type": "select", "proxies": ["JP Japan setup-node"]}],
                    "rules": ["MATCH,Outbound"]}).encode()
            elif kind == "invalid":
                body = b"proxies: [not valid yaml"
            elif kind == "bad-node":
                body = b'{"proxies":[{"name":"bad","type":"not-a-proxy"}]}'
            elif kind == "empty":
                body = b'{"proxies":[]}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Subscription-Userinfo", "upload=1024; download=2048; total=104857600; expire=0")
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(204)
        self.end_headers()

    def log_message(self, _format, *_args):
        pass


class TLSServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 128

    def process_request_thread(self, request, client_address):
        try:
            tls_request = self.context.wrap_socket(request, server_side=True)
        except (ssl.SSLError, OSError):
            self.shutdown_request(request)
            return
        super().process_request_thread(tls_request, client_address)


server = TLSServer(("0.0.0.0", int(sys.argv[3])), Handler)
server.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
server.context.load_cert_chain(sys.argv[1], sys.argv[2])
server.serve_forever()
