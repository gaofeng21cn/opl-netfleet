"""Exercise the shipped controller against a real, isolated Mihomo core."""
import argparse
import http.server
import json
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time
import urllib.request

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--mihomo', required=True)
parser.add_argument('--ucode', required=True)
args = parser.parse_args()
healthy = False


class Handler(http.server.BaseHTTPRequestHandler):
    def do_HEAD(self):
        self.send_response(404 if self.path == '/method' else 200 if healthy else 503)
        self.end_headers()

    def do_GET(self):
        self.send_response(200 if healthy else 503)
        self.end_headers()

    def log_message(self, *_args):
        pass


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    port = sock.getsockname()[1]
api = f'http://127.0.0.1:{port}'
probe = f'http://127.0.0.1:{server.server_port}'
with tempfile.TemporaryDirectory(prefix='netfleet-path-health-') as directory:
    work = Path(directory)
    config = {'external-controller': f'127.0.0.1:{port}', 'log-level': 'silent',
              'proxies': [{'name': 'leaf', 'type': 'direct'}],
              'proxy-groups': [{'name': 'preferred', 'type': 'select', 'proxies': ['leaf']}],
              'rules': ['MATCH,DIRECT']}
    (work / 'config.json').write_text(json.dumps(config))
    with (work / 'core.log').open('w') as log:
        core = subprocess.Popen([args.mihomo, '-d', directory, '-f', str(work / 'config.json')],
                                stdout=log, stderr=log)
        try:
            for _ in range(50):
                try:
                    with urllib.request.urlopen(api + '/version', timeout=1):
                        break
                except OSError:
                    time.sleep(.1)
            else:
                raise RuntimeError('isolated Mihomo did not start')

            def check(path, expected, passed):
                subprocess.run([args.ucode, str(Path(__file__).with_name('path_controller_device.uc')),
                                api, probe + path, str(passed).lower(), str(expected)], check=True)

            check('/health', 200, False)
            healthy = True
            # No artificial response delay: a valid URLTest may round to zero
            # and the real core may return 503 while recording healthy=true.
            for _ in range(5):
                check('/health', 200, True)
            check('/method', 200, False)
            check('/method', 404, True)
            with urllib.request.urlopen(probe + '/method') as response:
                assert response.status == 200
            healthy = False
            check('/health', 200, False)
        finally:
            core.terminate()
            core.wait(timeout=10)
            server.shutdown()
            server.server_close()
# Controller JSON can end exactly at ucode's 1024-byte stream boundary.
# The newline belongs to the same valid response, not a second JSON value.
class BoundaryHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        if '/delay?' in self.path:
            self.wfile.write(b'{"delay":1}\n')
            return
        value = {'extra': {probe: {'alive': True, 'history': []}}, 'padding': ''}
        body = json.dumps(value)
        value['padding'] = 'a' * (1024 - len(body.encode()))
        body = json.dumps(value).encode()
        assert len(body) == 1024
        self.wfile.write(body + b'\n')

    def log_message(self, *_args):
        pass

boundary = http.server.ThreadingHTTPServer(('127.0.0.1', 0), BoundaryHandler)
threading.Thread(target=boundary.serve_forever, daemon=True).start()
try:
    subprocess.run([args.ucode, str(Path(__file__).with_name('path_controller_device.uc')),
                    f'http://127.0.0.1:{boundary.server_port}', probe, 'true'], check=True)
finally:
    boundary.shutdown()
    boundary.server_close()
print('real Mihomo probe method and sub-millisecond health checks passed')
