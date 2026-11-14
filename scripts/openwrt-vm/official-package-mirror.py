#!/usr/bin/env python3
"""Relay official OpenWrt packages to disposable guests; APK verifies signatures."""
import argparse
from http.client import HTTPException
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import re
import shutil
import tempfile
from urllib import request


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/healthz':
            self.send_response(200)
            self.send_header('Content-Length', '2')
            self.end_headers()
            self.wfile.write(b'OK')
            return
        if (not self.path.startswith(self.server.release_prefix)
                or not re.fullmatch(r'/releases/[0-9]+\.[0-9]+\.[0-9]+/(?:[A-Za-z0-9._+~-]+/)*[A-Za-z0-9._+~-]+\.(?:adb|apk)', self.path)
                or '..' in self.path.split('/')):
            self.send_error(404)
            return
        target = self.server.cache_root / self.path.lstrip('/')
        temporary = None
        try:
            if not target.is_file():
                target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                with request.urlopen('https://downloads.openwrt.org' + self.path, timeout=120) as origin:
                    with tempfile.NamedTemporaryFile(dir=target.parent, prefix='.download-', delete=False) as output:
                        temporary = Path(output.name)
                        shutil.copyfileobj(origin, output)
                    expected = origin.headers.get('Content-Length')
                    if expected is not None and temporary.stat().st_size != int(expected):
                        raise OSError('Incomplete official package download')
                os.replace(temporary, target)
                temporary = None
        except (OSError, ValueError, HTTPException):
            self.send_error(502, 'Official package download failed')
            return
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)
        with target.open('rb') as package:
            self.send_response(200)
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Length', str(os.fstat(package.fileno()).st_size))
            self.end_headers()
            shutil.copyfileobj(package, self.wfile)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('cache', type=Path)
    parser.add_argument('port', type=int)
    parser.add_argument('version')
    args = parser.parse_args()
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', args.version):
        parser.error('version must select an official OpenWrt release')
    args.cache.mkdir(parents=True, exist_ok=True, mode=0o700)
    server = ThreadingHTTPServer(('127.0.0.1', args.port), Handler)
    server.cache_root = args.cache.resolve()
    server.release_prefix = f'/releases/{args.version}/'
    server.serve_forever()


if __name__ == '__main__':
    main()
