import http.client
import importlib.util
import io
from pathlib import Path
import tempfile
import threading
import unittest
from unittest import mock


MODULE = Path(__file__).resolve().parents[1] / 'scripts/openwrt-vm/official-package-mirror.py'
spec = importlib.util.spec_from_file_location('official_package_mirror', MODULE)
mirror = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mirror)


class MirrorTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.server = mirror.ThreadingHTTPServer(('127.0.0.1', 0), mirror.Handler)
        self.server.cache_root = Path(self.directory.name)
        self.server.release_prefix = '/releases/25.12.5/'
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=3)
        self.directory.cleanup()

    def read(self, path):
        connection = http.client.HTTPConnection(*self.server.server_address, timeout=3)
        try:
            connection.request('GET', path)
            response = connection.getresponse()
            return response.status, response.read()
        finally:
            connection.close()

    def test_preserves_official_bytes_and_reuses_the_complete_download(self):
        payload = b'APK\x00signed-package\xff'
        origin = io.BytesIO(payload)
        origin.headers = {'Content-Length': str(len(payload))}
        path = '/releases/25.12.5/packages/aarch64_generic/base/package-1.0-r1.apk'
        with mock.patch.object(mirror.request, 'urlopen', return_value=origin) as fetch:
            self.assertEqual(self.read(path), (200, payload))
            self.assertEqual(self.read(path), (200, payload))
        fetch.assert_called_once_with('https://downloads.openwrt.org' + path, timeout=120)

    def test_limits_the_origin_paths(self):
        with mock.patch.object(mirror.request, 'urlopen') as fetch:
            for path in ('/etc/passwd', '/releases/25.12.6/base/package.apk', '/releases/25.12.5/../secret.apk',
                         '/releases/25.12.5/%2e%2e/secret.apk',
                         '/releases/25.12.5/base/package.apk?origin=other'):
                self.assertEqual(self.read(path)[0], 404)
        fetch.assert_not_called()

    def test_incomplete_origin_response_is_not_cached(self):
        origin = io.BytesIO(b'partial')
        origin.headers = {'Content-Length': '100'}
        path = '/releases/25.12.5/packages/aarch64_generic/base/packages.adb'
        with mock.patch.object(mirror.request, 'urlopen', return_value=origin):
            self.assertEqual(self.read(path)[0], 502)
        self.assertEqual(list(self.server.cache_root.rglob('*adb')), [])
        self.assertEqual(list(self.server.cache_root.rglob('.download-*')), [])

    def test_origin_failure_is_not_cached(self):
        with mock.patch.object(mirror.request, 'urlopen', side_effect=OSError('unavailable')):
            self.assertEqual(self.read('/releases/25.12.5/base/packages.adb')[0], 502)
        self.assertEqual(list(self.server.cache_root.rglob('packages.adb')), [])


if __name__ == '__main__':
    unittest.main()
