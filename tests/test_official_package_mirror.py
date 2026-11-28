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
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={'poll_interval': 0.01}, daemon=True)
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
        pending_at_reply = []
        send_error = mirror.Handler.send_error

        def record_error(handler, *args):
            pending_at_reply.extend(self.server.cache_root.rglob('.download-*'))
            return send_error(handler, *args)

        with (mock.patch.object(mirror.request, 'urlopen', return_value=origin),
              mock.patch.object(mirror.Handler, 'send_error', record_error)):
            self.assertEqual(self.read(path)[0], 502)
        self.assertEqual(list(self.server.cache_root.rglob('*adb')), [])
        self.assertEqual(pending_at_reply, [])

    def test_origin_failure_is_not_cached(self):
        with mock.patch.object(mirror.request, 'urlopen', side_effect=OSError('unavailable')):
            self.assertEqual(self.read('/releases/25.12.5/base/packages.adb')[0], 502)
        self.assertEqual(list(self.server.cache_root.rglob('packages.adb')), [])

    def test_relays_24_10_opkg_indexes_and_ipk_packages(self):
        self.server.release_prefix = '/releases/24.10.2/'
        samples = {
            '/releases/24.10.2/packages/aarch64_generic/base/Packages.gz': b'gz-index',
            '/releases/24.10.2/packages/aarch64_generic/base/Packages.sig': b'untrusted comment: sig\nAAAA\n',
            '/releases/24.10.2/packages/aarch64_generic/base/Packages': b'Package: usign\n',
            '/releases/24.10.2/packages/aarch64_generic/base/usign_2020-05-23-f1f65026-1_aarch64_generic.ipk': b'ipk-bytes',
        }
        def fake_urlopen(url, timeout=120):
            for path, payload in samples.items():
                if url.endswith(path):
                    obj = io.BytesIO(payload)
                    obj.headers = {'Content-Length': str(len(payload))}
                    return obj
            raise AssertionError(f'unexpected url {url}')

        with mock.patch.object(mirror.request, 'urlopen', side_effect=fake_urlopen):
            for path, payload in samples.items():
                self.assertEqual(self.read(path), (200, payload))


if __name__ == '__main__':
    unittest.main()
