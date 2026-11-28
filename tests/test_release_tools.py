import hashlib
import importlib.util
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path
from urllib.error import HTTPError

ROOT = Path(__file__).parents[1]
PACKAGER = ROOT / 'scripts/netfleet-package-build.sh'
PREPARER = ROOT / 'scripts/prepare-openwrt-sdk.sh'
VERIFIER = ROOT / 'scripts/verify-netfleet-release.py'
PUBLISHER = ROOT / 'scripts/publish-netfleet-release.sh'
WORKFLOW = ROOT / '.github/workflows/netfleet-openwrt-candidate.yml'
FEED_BUILDER = ROOT / 'scripts/netfleet-feed-build.sh'
INSTALLER = ROOT / 'scripts/install-netfleet.sh'


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_release(directory: Path, commit: str, tree: str, version: str = '0.4.5') -> None:
    packages = {
        'opl-netfleet': f'opl-netfleet-{version}-r1.apk',
        'opl-netfleet-kernel': f'opl-netfleet-kernel-{version}-r1.apk',
        'opl-netfleet-plugin-models': f'opl-netfleet-plugin-models-{version}-r1.apk',
        'luci-app-netfleet': f'luci-app-netfleet-{version}-r1.apk',
    }
    artifacts = []
    for package, name in packages.items():
        path = directory / name
        path.write_text(f'{package}\n')
        artifacts.append({
            'package': package,
            'name': name,
            'sha256': sha256(path),
            'size': path.stat().st_size,
        })
    files_manifest = directory / 'FILES.sha256'
    files_manifest.write_text('0' * 64 + '  usr/libexec/opl-netfleet/main.uc\n')
    public_key = directory / 'opl-netfleet-apk.pem'
    public_key.write_text('fixture-public-key\n')
    feed_index = directory / 'packages.adb'
    feed_index.write_bytes(b'fixture-feed-index\n')
    bootstrap = directory / 'install-netfleet.sh'
    bootstrap.write_text('#!/bin/sh\nexit 0\n')
    manifest = {
        'schema': 'opl-netfleet-package-manifest.v2',
        'source_commit': commit,
        'source_tree': tree,
        'package_version': version,
        'package_release': '1',
        'package_format': 'apk',
        'package_arch': 'noarch',
        'build_target_arch': 'aarch64_generic',
        'policy_schema': 2,
        'runtime_payload_sha256': '1' * 64,
        'files_manifest': {'name': files_manifest.name, 'sha256': sha256(files_manifest)},
        'artifacts': artifacts,
        'artifact_files': packages,
        'apk_public_key': {'name': public_key.name, 'sha256': sha256(public_key)},
        'feed_index': {'name': feed_index.name, 'sha256': sha256(feed_index)},
        'feed_bootstrap': {'name': bootstrap.name, 'sha256': sha256(bootstrap)},
    }
    (directory / 'manifest.json').write_text(json.dumps(manifest, sort_keys=True) + '\n')

class ReleaseToolsTests(unittest.TestCase):
    def test_transaction_downloader_implements_apk_wget_protocol_without_insecure_options(self):
        downloader = ROOT / 'plugins/components/lib/apk-fetch/wget'
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            curl = root / 'curl'
            curl.write_text('#!' + sys.executable + '\nimport json,os,sys\n'
                            'open(os.environ["CURL_ARGS"],"w").write(json.dumps(sys.argv[1:]))\n'
                            'sys.stdout.buffer.write(b"signed-index-bytes")\n')
            curl.chmod(0o755)
            env = {**os.environ, 'PATH': str(root) + os.pathsep + os.environ['PATH'],
                   'CURL_ARGS': str(root / 'args.json')}
            result = subprocess.run([str(downloader), '-q', '-T', '30',
                                     'https://example.invalid/packages.adb', '-O', '-'],
                                    env=env, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, b'signed-index-bytes')
            arguments = json.loads((root / 'args.json').read_text())
            self.assertEqual(arguments[0], '-q')
            self.assertIn('-fsSL', arguments)
            self.assertEqual(arguments[arguments.index('--max-time') + 1], '30')
            self.assertNotIn('-k', arguments)
            (root / 'args.json').unlink()
            refused = subprocess.run([str(downloader), '--no-check-certificate',
                                      'https://example.invalid/packages.adb'], env=env, capture_output=True)
            self.assertNotEqual(refused.returncode, 0)
            self.assertFalse((root / 'args.json').exists())

    def test_native_receipt_binds_all_artifacts_without_breaking_old_releases(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location('release_verifier', VERIFIER)
        verifier = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(verifier)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            commit, tree = 'a' * 40, 'b' * 40
            write_release(root, commit, tree)
            self.assertTrue(verifier.verify(root, commit, tree)['ok'])
            manifest = json.loads((root / 'manifest.json').read_text())
            packages = [{'package': item['package'], 'artifact': item['name'], 'sha256': item['sha256']}
                        for item in manifest['artifacts']]
            def receipt(entries):
                path = root / 'native-runtime.json'
                path.write_text(json.dumps({'ok': True, 'packages': entries}))
                manifest['native_runtime'] = {'name': path.name, 'sha256': sha256(path)}
                (root / 'manifest.json').write_text(json.dumps(manifest))
            receipt(packages)
            self.assertTrue(verifier.verify(root, commit, tree)['ok'])
            receipt(packages[:-1])
            with self.assertRaisesRegex(ValueError, 'cover'):
                verifier.verify(root, commit, tree)
            receipt([packages[0], *packages[:-1]])
            with self.assertRaisesRegex(ValueError, 'identity'):
                verifier.verify(root, commit, tree)
            receipt([{**packages[0], 'sha256': '0' * 64}, *packages[1:]])
            with self.assertRaisesRegex(ValueError, 'bytes differ'):
                verifier.verify(root, commit, tree)

    def test_numeric_package_identity_and_old_rollback_identity(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location('numeric_release_verifier', VERIFIER)
        verifier = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(verifier)
        self.assertEqual(verifier.artifact_version({'version': '0.6.1'}), '0.6.1')
        self.assertEqual(verifier.artifact_version({'version': '0.6.0', 'release': '1'}), '0.6.0-r1')
        for item in ({'version': '0.6.1-r1'}, {'version': '0.6.1', 'release': ''},
                     {'version': '0.6.1', 'release': '1;bad'}):
            with self.subTest(item=item), self.assertRaises(ValueError):
                verifier.artifact_version(item)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_release(root, 'a' * 40, 'b' * 40)
            manifest = json.loads((root / 'manifest.json').read_text())
            del manifest['package_release']
            for artifact in manifest['artifacts']:
                name = artifact['name'].replace('-r1.apk', '.apk')
                (root / artifact['name']).rename(root / name)
                artifact.update(name=name, version=manifest['package_version'])
                manifest['artifact_files'][artifact['package']] = name
            (root / 'manifest.json').write_text(json.dumps(manifest))
            self.assertTrue(verifier.verify(root, 'a' * 40, 'b' * 40)['ok'])

    def test_update_fixtures_exercise_old_revision_to_numeric_upgrade(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location('numeric_fixtures', ROOT / 'scripts/openwrt-vm/component-fixtures.py')
        fixtures = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(fixtures)
        self.assertEqual(fixtures.fixture_versions('0.6.1'), ('0.6.0-r1', '0.6.2', '0.6.3'))
        self.assertEqual(fixtures.fixture_versions('1.19.30-r1'), ('1.19.30-r0', '1.19.30-r2', '1.19.30-r3'))
        with self.assertRaises(ValueError):
            fixtures.fixture_versions('bad')
        self.assertEqual(fixtures.prior_dependencies(
            ['models>=0.7.12', 'models>=0.7.6', 'models', 'libc', 'external>=1.0'],
            {'models': '0.7.12'}),
            ['models>=0.7.11-r1', 'models>=0.7.6', 'models', 'libc', 'external>=1.0'])
        self.assertEqual(fixtures.prior_dependencies(
            ['!opl-netfleet<0.9.10', '!network<0.8.5', 'mihomo>=0.9.11',
             '!external<0.8.5', '!network<0.8.1', 'network<0.8.5'],
            {'opl-netfleet': '0.9.10', 'network': '0.8.5', 'mihomo': '0.9.11'}),
            ['!opl-netfleet<0.9.9-r1', '!network<0.8.4-r1', 'mihomo>=0.9.10-r1',
             '!external<0.8.5', '!network<0.8.1', 'network<0.8.5'])


    def test_luci_release_versions_all_shell_modules_without_cross_version_urls(self):
        package = ROOT / 'openwrt/luci-app-netfleet'
        with tempfile.TemporaryDirectory() as directory:
            namespaces = []
            for version in ('v0_5_1', 'v0_5_2'):
                resources = Path(directory) / version
                shutil.copytree(package / 'htdocs/luci-static/resources', resources)
                subprocess.run(['sh', str(package / 'stage-assets.sh'), str(resources), version], check=True)
                view = resources / f'view/netfleet/overview-{version}.js'
                visited = set()
                pending = [view]
                while pending:
                    module = pending.pop()
                    if module in visited:
                        continue
                    visited.add(module)
                    self.assertTrue(module.is_file(), str(module))
                    for dependency in re.findall(r"'require (netfleet\.[\w.]+)(?: as \w+)?';", module.read_text()):
                        self.assertTrue(dependency.startswith(f'netfleet.{version}.'), dependency)
                        pending.append(resources / (dependency.replace('.', '/') + '.js'))
                    for dependency in re.findall(r"L\.resource\('(netfleet/[^']+\.js)'\)", module.read_text()):
                        self.assertTrue(dependency.startswith(f'netfleet/{version}/'), dependency)
                        pending.append(resources / dependency)
                self.assertEqual({resources / f'netfleet/{version}/api.js', resources / f'netfleet/{version}/plugin-host.js', view}, visited)
                namespaces.append({str(path.relative_to(resources)) for path in visited})
                for name in ('api.js', 'plugin-host.js'):
                    self.assertEqual((resources / f'netfleet/{version}/{name}').read_bytes(), (package / f'htdocs/luci-static/resources/netfleet/{name}').read_bytes())
                    self.assertFalse((resources / f'netfleet/{name}').exists())
                self.assertFalse((resources / 'netfleet/managed.js').exists())
                self.assertFalse((resources / 'netfleet/native.css').exists())
                self.assertFalse((resources / 'view/netfleet/overview.js').exists())
            self.assertFalse(namespaces[0] & namespaces[1])

    def test_sdk_preparer_generates_build_configuration_without_feeds(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sdk = root / 'sdk'
            sdk.mkdir()
            (sdk / 'Makefile').write_text('all:\n\t@true\n')
            fake_make = root / 'make'
            fake_make.write_text(
                '#!/bin/sh\n'
                'sdk=\n'
                'while [ "$#" -gt 0 ]; do\n'
                '  if [ "$1" = -C ]; then sdk=$2; shift 2; else shift; fi\n'
                'done\n'
                'if [ ! -f "$sdk/.config" ]; then printf "CONFIG_USE_APK=y\\n" > "$sdk/.config"; fi\n'
                'printf "aarch64_generic\\n"\n'
            )
            fake_make.chmod(0o755)
            result = subprocess.run(
                [str(PREPARER), '--sdk', str(sdk)],
                env={
                    **os.environ,
                    'MAKE': str(fake_make),
                },
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertTrue((sdk / '.config').is_file())
            self.assertIn('package_arch=aarch64_generic', result.stdout)

    def test_batch_package_metadata_preserves_versions_and_dependency_solver_inputs(self):
        script = ROOT / 'openwrt/plugin-packages.py'
        def query(*args):
            return subprocess.check_output([sys.executable, str(script), *args], text=True).split()
        tokens = query('metadata')
        def field(name):
            return [token.split('=', 1)[1] for token in tokens if token.startswith(name + '=')]
        self.assertEqual(field('id'), query('ids'))
        self.assertEqual(field('default'), query('default-ids'))
        identities = field('id')
        self.assertGreater(len(identities), 0)
        self.assertEqual(field('version.' + identities[0]), query('version', identities[0]))
        self.assertEqual(field('depends.' + identities[0]), query('dependencies', identities[0]))
        spec = importlib.util.spec_from_file_location('plugin_packages', script)
        package_mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(package_mod)
        plugins, _, graph = package_mod.composition()
        for identity in identities:
            self.assertEqual(field('version.' + identity), [plugins[identity]['version']])
            deps = sorted({*plugins[identity].get('package_dependencies', []), *(plugins[req]['package'] for req in graph[identity])})
            self.assertEqual(field('depends.' + identity), [f'+{name}' for name in deps])
        self.assertNotIn('define Package/opl-netfleet-kernel', (ROOT / 'openwrt/Makefile').read_text())

    def test_batch_package_metadata_rejects_invalid_composition(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            shutil.copy2(ROOT / 'openwrt/plugin-packages.py', directory)
            plugins = directory / 'plugins'
            shutil.copytree(ROOT / 'plugins', plugins)
            path = sorted(plugins.glob('*/manifest.json'))[0]
            manifest = json.loads(path.read_text())
            manifest['package_dependencies'] = ['bad$(shell command)']
            path.write_text(json.dumps(manifest))
            result = subprocess.run([sys.executable, str(directory / 'plugin-packages.py'), 'metadata'],
                                    text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, '')
            self.assertIn('invalid system package dependency', result.stderr)

    def test_packager_rejects_unbounded_jobs_before_sdk_access(self):
        for jobs in ('0', '-1', '17', 'all', '1;true'):
            with self.subTest(jobs=jobs), tempfile.TemporaryDirectory() as temp:
                output = Path(temp) / 'candidate'
                result = subprocess.run([str(PACKAGER), '--jobs', jobs, '--output', str(output)],
                                        text=True, capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('--jobs must be an integer', result.stderr)
                self.assertFalse(output.exists())

    def test_packager_requires_sdk_without_creating_artifacts(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'out'
            result = subprocess.run([str(PACKAGER), '--output', str(output)], text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(output.exists())

    def test_product_version_matches_openwrt_and_macos_release_metadata(self):
        product_version = json.loads((ROOT / 'product-version.json').read_text())['version']
        openwrt_makefile = (ROOT / 'openwrt/Makefile').read_text()
        openwrt_version = re.search(r'^PKG_VERSION:=(\S+)$', openwrt_makefile, re.M)
        macos_info = plistlib.loads((ROOT / 'desktop/app/Info.plist').read_bytes())
        self.assertIsNotNone(openwrt_version, 'OpenWrt product version is missing')
        self.assertEqual(openwrt_version.group(1), product_version, 'OpenWrt product version')
        self.assertEqual(macos_info['CFBundleShortVersionString'], product_version, 'macOS product version')

    def test_package_sources_are_versioned_and_do_not_embed_instance_inputs(self):
        runtime = (ROOT / 'openwrt/Makefile').read_text()
        luci = (ROOT / 'openwrt/luci-app-netfleet/Makefile').read_text()
        version = re.search(r'^PKG_VERSION:=(\d+\.\d+\.\d+)$', runtime, re.M).group(1)
        self.assertRegex(runtime, r'(?m)^PKG_RELEASE:=$')
        self.assertIn('PKG_LICENSE:=GPL-3.0-only', runtime)
        self.assertIn('PKG_MAINTAINER:=OPL NetFleet', runtime)
        self.assertIn('PKGARCH:=all', runtime)
        self.assertRegex(luci, r'(?m)^PKG_VERSION:=\d+\.\d+\.\d+$')
        self.assertIn('PKGARCH:=all', luci)
        self.assertIn('include $(INCLUDE_DIR)/package.mk', luci)
        self.assertNotIn('feeds/luci/luci.mk', luci)
        self.assertIn('Package/luci-app-netfleet/install', luci)
        self.assertIn('Package/luci-app-netfleet/postinst', luci)
        self.assertIn('sh ./stage-assets.sh $(1)/www/luci-static/resources $(NETFLEET_VIEW_VERSION)', luci)
        self.assertIn("uci set 'rpcd.@rpcd[0].timeout=300'", luci)
        self.assertIn("uci set 'uhttpd.main.script_timeout=300'", luci)
        self.assertIn('[ "$$rpcd_timeout" -ge 300 ]', luci)
        self.assertIn('/etc/init.d/rpcd restart', luci)
        self.assertIn('/etc/init.d/uhttpd restart', luci)
        packager = PACKAGER.read_text()
        self.assertIn('opl-netfleet-package-manifest.v2', packager)
        self.assertNotIn('CONFIG_SIGN_EACH_PACKAGE', packager)
        self.assertIn('adbsign --allow-untrusted --reset-signatures', packager)
        self.assertNotIn('add --allow-untrusted', packager)
        self.assertIn('verify --keys-dir "$trusted_dir"', packager)
        self.assertIn('apk" mkndx', packager)
        self.assertIn('opl-netfleet-package-build.v1', packager)
        self.assertIn('/usr/share/opl-netfleet/build.json', runtime)
        self.assertIn('Package/opl-netfleet/postinst', runtime)
        self.assertIn('Package/opl-netfleet/preinst', runtime)
        self.assertIn('/tmp/opl-netfleet-package-upgrade-state', runtime)
        self.assertIn('$${PKG_UPGRADE:-0}', runtime)
        self.assertIn('/etc/init.d/opl-netfleet disable', runtime)
        self.assertIn('/etc/init.d/opl-netfleet stop', runtime)
        self.assertIn('stop_netfleet()', runtime)
        self.assertIn('/etc/init.d/opl-netfleet running', runtime)
        init = (ROOT / 'openwrt/files/etc/init.d/opl-netfleet').read_text()
        self.assertIn('[ -s /etc/opl-netfleet/policy.json ] || return 0', init)
        self.assertIn('"$$path.apk-new"', runtime)
        self.assertIn('./files/etc/opl-netfleet/rulesets.lock.json', runtime)
        self.assertNotIn('/etc/opl-netfleet/policy.json', runtime)
        self.assertIn("'runtime_payload_sha256':runtime_payload_sha256", packager)
        self.assertIn("'package_arch':package_arch", packager)
        self.assertIn("'build_target_arch':build_target_arch", packager)
        self.assertIn("manifest['feed_bootstrap']={'name':'install-netfleet.sh'", packager)
        self.assertIn('${package_name}-${artifact_version}.apk', packager)
        for path in (ROOT / 'scripts/netfleet-package-build.sh', ROOT / 'openwrt/Makefile', ROOT / 'openwrt/luci-app-netfleet/Makefile'):
            text = path.read_text()
            self.assertNotIn('subscriptions.json', text)
            self.assertNotIn('nikki-mixin.yaml', text)

    def test_packager_uses_the_frozen_ref_for_version_and_restores_sdk_keys(self):
        text = PACKAGER.read_text()
        self.assertIn('version=$(awk', text)
        self.assertIn('"$work/openwrt/Makefile"', text)
        self.assertIn('for name in .config private-key.pem public-key.pem', text)
        self.assertIn("APK builds require --apk-private-key", text)

    def test_packager_rejects_old_make_before_mutating_sdk(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            sdk = root / 'sdk'; sdk.mkdir()
            (sdk / 'Makefile').write_text('fixture')
            (sdk / '.config').write_text('original config')
            commands = root / 'bin'; commands.mkdir()
            uname = commands / 'uname'
            uname.write_text('#!/bin/sh\ncase "$1" in -s) echo Linux;; -m) echo x86_64;; esac\n')
            uname.chmod(0o755)
            make = commands / 'old-make'
            make.write_text('#!/bin/sh\necho "GNU Make 3.81"\n')
            make.chmod(0o755)
            result = subprocess.run(['bash', str(PACKAGER), '--sdk', str(sdk), '--preflight'],
                                    env={**os.environ, 'PATH': str(commands) + ':' + os.environ['PATH'],
                                         'MAKE': str(make)}, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('GNU Make 4 or newer', result.stderr)
            self.assertEqual((sdk / '.config').read_text(), 'original config')
            self.assertEqual(sorted(p.name for p in sdk.iterdir()), ['.config', 'Makefile'])

    def test_feed_builder_uses_verified_manifest_packages(self):
        source = FEED_BUILDER.read_text()
        self.assertIn('verify-netfleet-release.py', source)
        self.assertIn('dependency_artifacts', source)
        self.assertIn('apk_tool" mkndx', source)
        self.assertIn('--sign ', source)

    def test_prebuilt_core_has_no_go_build_and_single_source_lock(self):
        source = json.loads((ROOT / 'openwrt/mihomo-meta/source.json').read_text())
        makefile = (ROOT / 'openwrt/mihomo-meta/Makefile').read_text()
        self.assertEqual(source['architecture'], 'aarch64_generic')
        self.assertRegex(source['sha256'], r'^[0-9a-f]{64}$')
        self.assertRegex(source['source_commit'], r'^[0-9a-f]{40}$')
        self.assertIn('PROVIDES:=mihomo', makefile)
        self.assertIn('ALTERNATIVES:=300:/usr/bin/mihomo:/usr/libexec/mihomo', makefile)
        self.assertNotIn('golang/host', makefile)
        self.assertIn('gzip -dc', makefile)

    def test_release_verifier_validates_core_dependency_identity(self):
        for failure in (None, 'bytes', 'arch', 'source'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as temp:
                release = Path(temp)
                write_release(release, 'a' * 40, 'b' * 40)
                manifest_path = release / 'manifest.json'
                manifest = json.loads(manifest_path.read_text())
                upstream = json.loads((ROOT / 'openwrt/mihomo-meta/source.json').read_text())
                core = release / f'mihomo-meta-{upstream["version"]}-r1.apk'
                core.write_bytes(b'fixture core package')
                dependency = {'package': 'mihomo-meta', 'name': core.name,
                              'size': core.stat().st_size, 'sha256': sha256(core),
                              'package_arch': manifest['build_target_arch'],
                              'version': upstream['version'], 'upstream': upstream}
                if failure == 'bytes':
                    core.write_bytes(b'changed package')
                elif failure == 'arch':
                    dependency['package_arch'] = 'x86_64'
                elif failure == 'source':
                    upstream.pop('source_url')
                manifest['dependency_artifacts'] = [dependency]
                manifest_path.write_text(json.dumps(manifest))
                result = subprocess.run([sys.executable, str(VERIFIER), '--directory', str(release),
                                         '--source-commit', 'a' * 40, '--source-tree', 'b' * 40],
                                        text=True, capture_output=True)
                self.assertEqual(result.returncode, 0 if failure is None else 1, result.stderr)
                if failure is None:
                    self.assertEqual(json.loads(result.stdout)['source_commit'], 'a' * 40)
                    with tempfile.TemporaryDirectory() as feed_temp:
                        feed_root = Path(feed_temp)
                        apk_tool = feed_root / 'apk'
                        index_rows = [{'name': item['package'], 'version': item['name'][len(item['package'])+1:-4],
                                       'arch': item.get('package_arch', 'noarch')}
                                      for item in manifest['artifacts'] + manifest['dependency_artifacts']]
                        apk_tool.write_text('#!/bin/sh\nif [ "$1" = adbdump ]; then\ncat <<\'JSON\'\n'
                                            + json.dumps({'packages':index_rows}) + '\nJSON\nexit 0\nfi\n'
                                            'while [ "$#" -gt 0 ]; do\n'
                                            '  if [ "$1" = --output ]; then shift; output=$1; fi\n'
                                            '  case "$1" in *.apk) packages="$packages $1";; esac\n'
                                            '  shift\ndone\nprintf "%s\\n" "$packages" >"$output"\n')
                        apk_tool.chmod(0o755)
                        feed = feed_root / 'feed'
                        built = subprocess.run([str(FEED_BUILDER), '--packages', str(release),
                                                '--apk', str(apk_tool), '--sign-key', str(release / 'opl-netfleet-apk.pem'),
                                                '--output', str(feed)], text=True, capture_output=True)
                        self.assertEqual(built.returncode, 0, built.stderr)
                        self.assertEqual(len(list(feed.glob('*.apk'))), 5)
                        self.assertIn(core.name, (feed / 'packages.adb').read_text())

    def test_release_verifier_accepts_exact_source_and_public_readback(self):
        commit = 'a' * 40
        tree = 'b' * 40
        with tempfile.TemporaryDirectory() as first, tempfile.TemporaryDirectory() as second:
            built = Path(first)
            readback = Path(second)
            write_release(built, commit, tree)
            write_release(readback, commit, tree)
            result = subprocess.run(
                [
                    str(VERIFIER),
                    '--directory', str(readback),
                    '--expected-directory', str(built),
                    '--source-commit', commit,
                    '--source-tree', tree,
                ],
                text=True,
                capture_output=True,
                check=False,
            )
        self.assertEqual(0, result.returncode, result.stderr)
        receipt = json.loads(result.stdout)
        self.assertTrue(receipt['ok'])
        self.assertTrue(receipt['matches_expected_directory'])
        self.assertEqual(9, receipt['file_count'])

    def test_release_verifier_rejects_source_identity_drift(self):
        with tempfile.TemporaryDirectory() as directory:
            release = Path(directory)
            write_release(release, 'a' * 40, 'b' * 40)
            result = subprocess.run(
                [
                    str(VERIFIER),
                    '--directory', str(release),
                    '--source-commit', 'c' * 40,
                    '--source-tree', 'b' * 40,
                ],
                text=True,
                capture_output=True,
                check=False,
            )
        self.assertNotEqual(0, result.returncode)
        self.assertIn('source identity does not match', result.stderr)

    def test_release_verifier_rejects_public_byte_drift(self):
        commit = 'a' * 40
        tree = 'b' * 40
        with tempfile.TemporaryDirectory() as first, tempfile.TemporaryDirectory() as second:
            built = Path(first)
            readback = Path(second)
            write_release(built, commit, tree)
            write_release(readback, commit, tree)
            (readback / 'opl-netfleet-0.4.5-r1.apk').write_text('changed\n')
            result = subprocess.run(
                [
                    str(VERIFIER),
                    '--directory', str(readback),
                    '--expected-directory', str(built),
                    '--source-commit', commit,
                    '--source-tree', tree,
                ],
                text=True,
                capture_output=True,
                check=False,
            )
        self.assertNotEqual(0, result.returncode)
        self.assertIn('bytes do not match manifest', result.stderr)

    def test_release_verifier_rejects_missing_feed_index_for_new_release(self):
        with tempfile.TemporaryDirectory() as directory:
            release = Path(directory)
            write_release(release, 'a' * 40, 'b' * 40)
            manifest = json.loads((release / 'manifest.json').read_text())
            manifest['package_version'] = '0.3.1'
            (release / 'manifest.json').write_text(json.dumps(manifest) + '\n')
            (release / 'packages.adb').unlink()
            result = subprocess.run(
                [str(VERIFIER), '--directory', str(release), '--source-commit', 'a' * 40, '--source-tree', 'b' * 40],
                text=True, capture_output=True, check=False,
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('packages.adb', result.stderr)

    def test_release_verifier_keeps_legacy_release_compatible_without_feed_index(self):
        with tempfile.TemporaryDirectory() as directory:
            release = Path(directory)
            write_release(release, 'a' * 40, 'b' * 40, version='0.3.0')
            (release / 'packages.adb').unlink()
            (release / 'install-netfleet.sh').unlink()
            manifest = json.loads((release / 'manifest.json').read_text())
            manifest.pop('feed_index', None)
            manifest.pop('feed_bootstrap', None)
            (release / 'manifest.json').write_text(json.dumps(manifest) + '\n')
            result = subprocess.run([str(VERIFIER), '--directory', str(release), '--source-commit', 'a' * 40, '--source-tree', 'b' * 40], text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_release_verifier_rejects_current_release_without_build_target(self):
        with tempfile.TemporaryDirectory() as directory:
            release = Path(directory)
            write_release(release, 'a' * 40, 'b' * 40)
            manifest = json.loads((release / 'manifest.json').read_text())
            manifest.pop('build_target_arch')
            (release / 'manifest.json').write_text(json.dumps(manifest) + '\n')
            result = subprocess.run(
                [str(VERIFIER), '--directory', str(release), '--source-commit', 'a' * 40, '--source-tree', 'b' * 40],
                text=True, capture_output=True, check=False,
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('build target architecture is missing', result.stderr)

    def test_release_verifier_rejects_current_native_arch_apk(self):
        with tempfile.TemporaryDirectory() as directory:
            release = Path(directory)
            write_release(release, 'a' * 40, 'b' * 40)
            manifest = json.loads((release / 'manifest.json').read_text())
            manifest['package_arch'] = 'aarch64_generic'
            (release / 'manifest.json').write_text(json.dumps(manifest) + '\n')
            result = subprocess.run(
                [str(VERIFIER), '--directory', str(release), '--source-commit', 'a' * 40, '--source-tree', 'b' * 40],
                text=True, capture_output=True, check=False,
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('APK architecture must be noarch', result.stderr)

    def test_release_verifier_rejects_missing_or_changed_feed_bootstrap(self):
        for mutation in ('missing', 'changed'):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                release = Path(directory)
                write_release(release, 'a' * 40, 'b' * 40)
                bootstrap = release / 'install-netfleet.sh'
                if mutation == 'missing':
                    bootstrap.unlink()
                else:
                    bootstrap.write_text('#!/bin/sh\nexit 1\n')
                result = subprocess.run(
                    [str(VERIFIER), '--directory', str(release), '--source-commit', 'a' * 40, '--source-tree', 'b' * 40],
                    text=True, capture_output=True, check=False,
                )
            self.assertNotEqual(0, result.returncode)
            self.assertIn('feed bootstrap', result.stderr)

    def test_feed_bootstrap_upgrades_complete_product_without_system_dependencies(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            feed = root / 'feed'
            bin_dir = root / 'bin'
            keys = root / 'keys'
            repository = root / 'repositories.d' / 'opl-netfleet.list'
            feed.mkdir()
            bin_dir.mkdir()
            (feed / 'opl-netfleet-apk.pem').write_text(
                '-----BEGIN PUBLIC KEY-----\nfixture\n-----END PUBLIC KEY-----\n'
            )
            (feed / 'product.json').write_text(json.dumps([{'depends': [
                'libc', 'opl-netfleet-kernel', 'opl-netfleet-plugin-dashboard>=0.7.0',
                'opl-netfleet-plugin-selection', 'mihomo', 'yq',
            ]}]))
            fetcher = bin_dir / 'uclient-fetch'
            fetcher.write_text(
                '#!/bin/sh\n'
                'destination=\nurl=\n'
                'while [ "$#" -gt 0 ]; do\n'
                '  case "$1" in -q) shift ;; -O) destination=$2; shift 2 ;; *) url=$1; shift ;; esac\n'
                'done\n'
                'cp "$NETFLEET_FIXTURE_FEED/${url##*/}" "$destination"\n'
            )
            fetcher.chmod(0o755)
            curl = bin_dir / 'curl'
            curl.write_text(
                '#!/bin/sh\n'
                'destination=\nurl=\n'
                'while [ "$#" -gt 0 ]; do\n'
                '  case "$1" in --output|-o) destination=$2; shift 2 ;; --*) shift ;; *) url=$1; shift ;; esac\n'
                'done\n'
                'cp "$NETFLEET_FIXTURE_FEED/${url##*/}" "$destination"\n'
            )
            curl.chmod(0o755)
            apk = bin_dir / 'apk'
            apk.write_text(
                '#!/bin/sh\n'
                'if [ "$1" = info ]; then\n'
                '  case " $NETFLEET_INSTALLED " in *" $3 "*) exit 0 ;; *) exit 1 ;; esac\n'
                'fi\n'
                'printf "%s\\n" "$*" >>"$NETFLEET_APK_LOG"\n'
                'if [ "$*" = "--timeout 300 update" ]; then\n'
                '  attempts=$(grep -c -- "--timeout 300 update" "$NETFLEET_APK_LOG")\n'
                '  [ "$attempts" -gt "${NETFLEET_INDEX_FAILURES:-0}" ] || exit 1\n'
                'fi\n'
                'case " $* " in *" query "*) cat "$NETFLEET_FIXTURE_FEED/product.json" ;; esac\n'
            )
            apk.chmod(0o755)
            uci = bin_dir / 'uci'
            uci.write_text('#!/bin/sh\nprintf "%s\\n" "subscription:fixture"\n')
            uci.chmod(0o755)
            jsonfilter = bin_dir / 'jsonfilter'
            jsonfilter.write_text('#!/bin/sh\ntr \'"\' \'\\n\' <"$2" | awk \'NR%2==0 && $0!="depends"\'\n')
            jsonfilter.chmod(0o755)
            ucode = bin_dir / 'ucode'
            ucode.write_text('#!/bin/sh\ncat >/dev/null\nprintf \"management-load\\n\" >>\"$NETFLEET_APK_LOG\"\n')
            ucode.chmod(0o755)
            sleeper = bin_dir / 'sleep'
            sleeper.write_text('#!/bin/sh\nexit 0\n')
            sleeper.chmod(0o755)
            log = root / 'apk.log'
            env = {
                    **os.environ,
                    'PATH': f'{bin_dir}:{os.environ["PATH"]}',
                    'NETFLEET_INSTALL_TESTING': '1',
                    'NETFLEET_FEED_BASE': 'https://fixture.invalid/release',
                    'NETFLEET_FIXTURE_FEED': str(feed),
                    'NETFLEET_APK_KEYS_DIR': str(keys),
                    'NETFLEET_APK_REPOSITORY_FILE': str(repository),
                    'NETFLEET_APK_LOG': str(log),
                }
            for installed in ('', 'opl-netfleet', 'luci-app-netfleet', 'opl-netfleet opl-netfleet-kernel',
                              'opl-netfleet luci-app-netfleet opl-netfleet-kernel'):
                with self.subTest(installed=installed):
                    log.write_text('')
                    result = subprocess.run(
                        [str(INSTALLER)], env={**env, 'NETFLEET_INSTALLED': installed},
                        text=True, capture_output=True, check=False,
                    )
                    if installed == 'opl-netfleet':
                        self.assertNotEqual(0, result.returncode)
                        self.assertIn('legacy monolith migration requires', result.stderr)
                        self.assertEqual('', log.read_text())
                        continue
                    self.assertEqual(0, result.returncode, result.stderr)
                    expected = ['--timeout 300 update',
                                '--no-network query --from none -X https://fixture.invalid/release/packages.adb '
                                '--format json --fields depends,provides opl-netfleet']
                    if 'luci-app-netfleet' not in installed or 'opl-netfleet ' not in installed:
                        expected.append('--timeout 300 add opl-netfleet luci-app-netfleet '
                                        'opl-netfleet-kernel opl-netfleet-plugin-dashboard opl-netfleet-plugin-selection')
                    expected.append('--timeout 300 upgrade opl-netfleet luci-app-netfleet '
                                    'opl-netfleet-kernel opl-netfleet-plugin-dashboard opl-netfleet-plugin-selection')
                    self.assertEqual(expected, log.read_text().splitlines())
            self.assertEqual((feed / 'opl-netfleet-apk.pem').read_bytes(), (keys / 'opl-netfleet-apk.pem').read_bytes())
            self.assertEqual('https://fixture.invalid/release/packages.adb\n', repository.read_text())
            for failures in (1, 3):
                with self.subTest(index_failures=failures):
                    log.write_text('')
                    result = subprocess.run(
                        [str(INSTALLER)], env={**env, 'NETFLEET_INSTALLED': '',
                                             'NETFLEET_INDEX_FAILURES': str(failures)},
                        text=True, capture_output=True, check=False,
                    )
                    commands = log.read_text().splitlines()
                    self.assertEqual(min(failures + 1, 3), commands.count('--timeout 300 update'))
                    if failures == 1:
                        self.assertEqual(0, result.returncode, result.stderr)
                        self.assertEqual(1, commands.count(
                            '--timeout 300 add opl-netfleet luci-app-netfleet '
                            'opl-netfleet-kernel opl-netfleet-plugin-dashboard opl-netfleet-plugin-selection'
                        ))
                        self.assertEqual(1, sum(' upgrade ' in item for item in commands))
                    else:
                        self.assertNotEqual(0, result.returncode)
                        self.assertIn('package indexes unavailable', result.stderr)
                        self.assertEqual(['--timeout 300 update'] * 3, commands)

    def test_feed_bootstrap_thin_shell_preserves_existing_mihomo_meta_and_nikki(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            feed = root / 'feed'
            bin_dir = root / 'bin'
            keys = root / 'keys'
            repository = root / 'repositories.d' / 'opl-netfleet.list'
            feed.mkdir()
            bin_dir.mkdir()
            (feed / 'opl-netfleet-apk.pem').write_text(
                '-----BEGIN PUBLIC KEY-----\nfixture\n-----END PUBLIC KEY-----\n'
            )
            (feed / 'product.json').write_text(json.dumps([{'depends': ['libc'], 'provides': ['netfleet-plugin-api-v1']}]))
            fetcher = bin_dir / 'uclient-fetch'
            fetcher.write_text(
                '#!/bin/sh\n'
                'destination=\nurl=\n'
                'while [ "$#" -gt 0 ]; do case "$1" in -q) shift ;; -O) destination=$2; shift 2 ;; *) url=$1; shift ;; esac; done\n'
                'cp "$NETFLEET_FIXTURE_FEED/${url##*/}" "$destination"\n'
            )
            fetcher.chmod(0o755)
            curl = bin_dir / 'curl'
            curl.write_text(
                '#!/bin/sh\n'
                'destination=\nurl=\n'
                'while [ "$#" -gt 0 ]; do case "$1" in --output|-o) destination=$2; shift 2 ;; --*) shift ;; *) url=$1; shift ;; esac; done\n'
                'cp "$NETFLEET_FIXTURE_FEED/${url##*/}" "$destination"\n'
            )
            curl.chmod(0o755)
            apk = bin_dir / 'apk'
            apk.write_text(
                '#!/bin/sh\n'
                'if [ "$1" = info ]; then\n'
                '  case " $NETFLEET_INSTALLED " in *" $3 "*) exit 0 ;; *) exit 1 ;; esac\n'
                'fi\n'
                'printf "%s\\n" "$*" >>"$NETFLEET_APK_LOG"\n'
                'case " $* " in *" query "*) cat "$NETFLEET_FIXTURE_FEED/product.json" ;; esac\n'
            )
            apk.chmod(0o755)
            uci = bin_dir / 'uci'
            uci.write_text('#!/bin/sh\nexit 0\n')
            uci.chmod(0o755)
            jsonfilter = bin_dir / 'jsonfilter'
            jsonfilter.write_text(
                '#!/bin/sh\n'
                'if printf "%s" "$*" | grep -Fq "provides"; then printf "netfleet-plugin-api-v1\\n"; else printf "libc\\n"; fi\n'
            )
            jsonfilter.chmod(0o755)
            missing_nikki = root / 'missing-nikki'
            present_nikki = root / 'present-nikki'
            present_nikki.write_text('#!/bin/sh\nexit 0\n')
            missing_shell = root / 'missing-shell.json'
            present_shell = root / 'shell.json'
            present_shell.write_text('{}\n')
            clean_path = os.pathsep.join(p for p in os.environ['PATH'].split(os.pathsep) if not (Path(p) / 'mihomo').exists())
            log = root / 'apk.log'
            base_env = {
                **os.environ,
                'PATH': f'{bin_dir}:{clean_path}',
                'NETFLEET_INSTALL_TESTING': '1',
                'NETFLEET_FEED_BASE': 'https://fixture.invalid/release',
                'NETFLEET_FIXTURE_FEED': str(feed),
                'NETFLEET_APK_KEYS_DIR': str(keys),
                'NETFLEET_APK_REPOSITORY_FILE': str(repository),
                'NETFLEET_APK_LOG': str(log),
            }
            cases = [
                ('fresh_native', '', missing_shell, missing_nikki, 'opl-netfleet luci-app-netfleet mihomo-meta', True),
                ('existing_mihomo', 'opl-netfleet luci-app-netfleet mihomo-meta', present_shell, missing_nikki, 'opl-netfleet luci-app-netfleet', False),
                ('existing_mihomo_only', 'mihomo-meta', missing_shell, missing_nikki, 'opl-netfleet luci-app-netfleet', True),
                ('nikki_present', '', missing_shell, present_nikki, 'opl-netfleet luci-app-netfleet', True),
            ]
            for label, installed, shell_file, nikki_init, expected_pkgs, expect_add in cases:
                with self.subTest(thin_shell=label):
                    log.write_text('')
                    res = subprocess.run(
                        [str(INSTALLER)],
                        env={**base_env, 'NETFLEET_INSTALLED': installed, 'NETFLEET_SHELL_MANIFEST': str(shell_file), 'NETFLEET_NIKKI_INIT': str(nikki_init)},
                        text=True, capture_output=True, check=False,
                    )
                    self.assertEqual(0, res.returncode, res.stderr)
                    lines = log.read_text().splitlines()
                    if expect_add:
                        self.assertIn(f'--timeout 300 add {expected_pkgs}', lines)
                    else:
                        self.assertFalse(any(' add ' in item for item in lines))
                    self.assertIn(f'--timeout 300 upgrade {expected_pkgs}', lines)

    def test_feed_bootstrap_rejects_invalid_key_before_package_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            feed = root / 'feed'
            bin_dir = root / 'bin'
            feed.mkdir()
            bin_dir.mkdir()
            (feed / 'opl-netfleet-apk.pem').write_text('not-a-key\n')
            fetcher = bin_dir / 'uclient-fetch'
            fetcher.write_text(
                '#!/bin/sh\n'
                'while [ "$#" -gt 0 ]; do case "$1" in -q) shift ;; -O) destination=$2; shift 2 ;; *) url=$1; shift ;; esac; done\n'
                'cp "$NETFLEET_FIXTURE_FEED/${url##*/}" "$destination"\n'
            )
            fetcher.chmod(0o755)
            curl = bin_dir / 'curl'
            curl.write_text('#!/bin/sh\nwhile [ "$#" -gt 0 ]; do case "$1" in -o) destination=$2; shift 2 ;; *) url=$1; shift ;; esac; done\ncp "$NETFLEET_FIXTURE_FEED/${url##*/}" "$destination"\n')
            curl.chmod(0o755)
            apk = bin_dir / 'apk'
            apk.write_text('#!/bin/sh\n[ "$1" != info ] || exit 1\nprintf called >>"$NETFLEET_APK_LOG"\n')
            apk.chmod(0o755)
            uci = bin_dir / 'uci'
            uci.write_text('#!/bin/sh\nprintf "%s\\n" "subscription:fixture"\n')
            uci.chmod(0o755)
            jsonfilter = bin_dir / 'jsonfilter'
            jsonfilter.write_text('#!/bin/sh\nexit 1\n')
            jsonfilter.chmod(0o755)
            log = root / 'apk.log'
            result = subprocess.run(
                [str(INSTALLER)],
                env={
                    **os.environ,
                    'PATH': f'{bin_dir}:{os.environ["PATH"]}',
                    'NETFLEET_INSTALL_TESTING': '1',
                    'NETFLEET_FEED_BASE': 'https://fixture.invalid/release',
                    'NETFLEET_FIXTURE_FEED': str(feed),
                    'NETFLEET_APK_KEYS_DIR': str(root / 'keys'),
                    'NETFLEET_APK_REPOSITORY_FILE': str(root / 'repositories.d/opl-netfleet.list'),
                    'NETFLEET_APK_LOG': str(log),
                },
                text=True, capture_output=True, check=False,
            )
            self.assertNotEqual(0, result.returncode)
            self.assertIn('public key is invalid', result.stderr)
            self.assertFalse(log.exists())

    def test_feed_bootstrap_rejects_missing_uci_before_feed_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bin_dir = root / 'bin'
            bin_dir.mkdir()
            apk = bin_dir / 'apk'
            apk.write_text('#!/bin/sh\nprintf called >>"$NETFLEET_APK_LOG"\n')
            apk.chmod(0o755)
            log = root / 'apk.log'
            repository = root / 'repositories.d' / 'opl-netfleet.list'
            result = subprocess.run(
                [str(INSTALLER)],
                env={
                    **os.environ,
                    'PATH': str(bin_dir),
                    'NETFLEET_INSTALL_TESTING': '1',
                    'NETFLEET_APK_REPOSITORY_FILE': str(repository),
                    'NETFLEET_APK_LOG': str(log),
                },
                text=True, capture_output=True, check=False,
            )
            self.assertNotEqual(0, result.returncode)
            self.assertIn('OpenWrt UCI is required', result.stderr)
            self.assertFalse(repository.exists())
            self.assertFalse(log.exists())

    def test_release_workflow_builds_a_candidate_without_publishing(self):
        workflow = WORKFLOW.read_text()
        self.assertIn('fetch-depth: 0', workflow)
        self.assertIn("source_commit=$(git rev-parse 'HEAD^{commit}')", workflow)
        self.assertIn('--ref "$NETFLEET_SOURCE_COMMIT"', workflow)
        self.assertNotIn('--ref "${GITHUB_SHA}"', workflow)
        self.assertIn('actions/cache@v4', workflow)
        self.assertIn('${{ inputs.sdk_sha256 }}', workflow)
        self.assertIn('if [ ! -f "$RUNNER_TEMP/sdk.tar" ]', workflow)
        self.assertIn('actions/upload-artifact@v4', workflow)
        self.assertIn('packages.adb', workflow)
        self.assertIn('install-netfleet.sh', workflow)
        self.assertIn('candidate_name=netfleet-openwrt-candidate-%s-%s', workflow)
        self.assertIn('name: ${{ steps.identity.outputs.candidate_name }}', workflow)
        self.assertNotIn('gh release create', workflow)
        self.assertNotIn('contents: write', workflow)
        self.assertIn('scripts/prepare-openwrt-sdk.sh --sdk "$sdk"', workflow)
        self.assertEqual(1, workflow.count('scripts/verify-netfleet-release.py'))

    def test_publisher_requires_canonical_source_and_package_vm_receipt(self):
        result = subprocess.run([str(PUBLISHER), '--help'], text=True, capture_output=True, check=False)
        self.assertEqual(0, result.returncode, result.stderr)
        source = PUBLISHER.read_text()
        self.assertIn('opl-netfleet-openwrt-vm-qualification.v2', source)
        self.assertIn('package.get("manifest_sha256")', source)
        self.assertIn("remote_main", source)
        self.assertIn('release already exists and is immutable', source)
        self.assertIn('gh release download', source)
        self.assertEqual(2, source.count('verify-netfleet-release.py'))

class PublisherSourceAdmissionTests(unittest.TestCase):
    def test_recovery_requires_same_repository_run_successful_build_and_exact_artifact(self):
        spec = importlib.util.spec_from_file_location(
            "recover_candidate", ROOT / "scripts/openwrt-vm/recover-candidate.py")
        recovery = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(recovery)
        repo, tag, source = "example/test", "v0.4.5", "a" * 40
        run_id, artifact_id, digest = "10", "20", "sha256:" + "b" * 64
        repository = {"id": 30, "full_name": repo}
        run = {"id": 10, "path": ".github/workflows/release.yml", "event": "push",
               "head_branch": tag, "head_sha": source, "repository": repository, "head_repository": repository}
        jobs = {"jobs": [{"name": "candidate / build", "status": "completed", "conclusion": "success"}]}
        artifact = {"id": 20, "expired": False, "name": f"netfleet-openwrt-candidate-{source}", "digest": digest,
                    "workflow_run": {"id": 10, "head_branch": tag, "head_sha": source,
                                     "repository_id": 30, "head_repository_id": 30}}
        for failure in (None, "release", "fork", "failed-build", "digest", "artifact-run"):
            with self.subTest(failure=failure):
                def request(path):
                    if "/releases/tags/" in path:
                        if failure == "release":
                            return {"id": 40}
                        raise HTTPError(path, 404, "missing", None, None)
                    if "/jobs?" in path:
                        return {"jobs": []} if failure == "failed-build" else jobs
                    if "/actions/runs/" in path:
                        return {**run, "head_repository": {}} if failure == "fork" else run
                    if failure == "digest":
                        return {**artifact, "digest": "sha256:" + "c" * 64}
                    if failure == "artifact-run":
                        return {**artifact, "workflow_run": {**artifact["workflow_run"], "id": 11}}
                    return {**artifact, "name": artifact["name"] + "-1"}

                args = (repo, tag, source, run_id, artifact_id, digest, request)
                if failure:
                    with self.assertRaises(ValueError):
                        recovery.verify_candidate(*args)
                else:
                    self.assertEqual(recovery.verify_candidate(*args), "")

    def test_frozen_main_candidate_survives_main_advance_but_unmerged_source_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repo = root / "repo"
            repo.mkdir()
            def git(*args):
                return subprocess.check_output(["git", "-C", str(repo), *args], text=True, stderr=subprocess.DEVNULL).strip()
            git("init", "-q", "-b", "main")
            git("config", "user.email", "test@example.invalid")
            git("config", "user.name", "Test")
            scripts = repo / "scripts"
            scripts.mkdir()
            for source in (PUBLISHER, VERIFIER):
                shutil.copy2(source, scripts / source.name)
            git("add", ".")
            git("commit", "-qm", "qualified candidate")
            qualified = git("rev-parse", "HEAD")
            remote = root / "remote.git"
            subprocess.run(["git", "clone", "--bare", str(repo), str(remote)], check=True, capture_output=True)
            git("remote", "add", "origin", str(remote))
            (repo / "macos-change").write_text("unrelated platform change")
            git("add", ".")
            git("commit", "-qm", "advance main")
            git("push", "origin", "main")
            git("checkout", "-qb", "unmerged")
            (repo / "unmerged").write_text("not admitted")
            git("add", ".")
            git("commit", "-qm", "unmerged source")
            unmerged = git("rev-parse", "HEAD")
            git("checkout", "main")
            bin_dir = root / "bin"
            bin_dir.mkdir()
            gh = bin_dir / "gh"
            # Stop after source admission, before any tag or release mutation.
            gh.write_text('''#!/bin/sh
[ "$1 $2" = "release view" ] || exit 90
echo '{"tagName":"v0.4.5"}'
''')
            gh.chmod(0o755)
            for commit, expected in ((qualified, "release already exists and is immutable"),
                                     (unmerged, "has not been absorbed into canonical main")):
                with self.subTest(commit=commit):
                    candidate = root / commit
                    candidate.mkdir()
                    tree = git("rev-parse", commit + "^{tree}")
                    write_release(candidate, commit, tree)
                    receipt = root / (commit + ".json")
                    receipt.write_text(json.dumps({"schema": "opl-netfleet-openwrt-vm-qualification.v2",
                        "qualified": True, "package_qualified": True, "source_commit": commit,
                        "source_tree": tree, "package": {"manifest_sha256": sha256(candidate / "manifest.json")}}))
                    result = subprocess.run([str(scripts / PUBLISHER.name), "--repo", "example/test",
                        "--tag", "v0.4.5", "--candidate", str(candidate), "--qualification", str(receipt)],
                        env={**os.environ, "PATH": str(bin_dir) + os.pathsep + os.environ["PATH"]},
                        capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(expected, result.stderr)
                    self.assertEqual(git("tag"), "")

    def test_bundle_qualification_requires_all_four_gates_and_matching_release_bundle(self):
        usign_spec = importlib.util.spec_from_file_location("netfleet_usign", ROOT / "scripts/netfleet_usign.py")
        usign = importlib.util.module_from_spec(usign_spec)
        usign_spec.loader.exec_module(usign)
        bundle_spec = importlib.util.spec_from_file_location(
            "netfleet_bundle_build", ROOT / "scripts/netfleet-bundle-build.py"
        )
        bundle_mod = importlib.util.module_from_spec(bundle_spec)
        bundle_spec.loader.exec_module(bundle_mod)

        def write_bundle_candidate(directory: Path, commit: str, tree: str, version: str = "0.4.5") -> None:
            key = directory.parent / f"bundle-sign-{directory.name}.pem"
            usign.generate_private_key(key)
            bundle_summary = bundle_mod.build_bundle(
                ROOT, directory, version=version, source_commit=commit, source_tree=tree, sign_key=key
            )
            packages = {
                "opl-netfleet": f"opl-netfleet-{version}-r1.apk",
                "luci-app-netfleet": f"luci-app-netfleet-{version}-r1.apk",
            }
            artifacts = []
            for package, name in packages.items():
                path = directory / name
                path.write_text(f"{package}\n")
                artifacts.append({
                    "package": package,
                    "version": version,
                    "release": "1",
                    "name": name,
                    "sha256": sha256(path),
                    "size": path.stat().st_size,
                })
            files_manifest = directory / "FILES.sha256"
            files_manifest.write_text("0" * 64 + "  runtime/main.uc\n")
            public_key = directory / "opl-netfleet-apk.pem"
            public_key.write_text("fixture-public-key\n")
            feed_index = directory / "packages.adb"
            feed_index.write_bytes(b"fixture-feed-index\n")
            feed_meta = directory / "index.json"
            feed_meta.write_text(json.dumps({
                "version": 2,
                "architecture": "aarch64_generic",
                "packages": {"opl-netfleet": f"{version}-r1", "luci-app-netfleet": f"{version}-r1"},
            }))
            bootstrap = directory / "install-netfleet.sh"
            bootstrap.write_text("#!/bin/sh\nexit 0\n")
            manifest = {
                "schema": "opl-netfleet-package-manifest.v2",
                "delivery_model": "release-bundle",
                "source_commit": commit,
                "source_tree": tree,
                "package_version": version,
                "package_release": "1",
                "package_format": "apk",
                "package_arch": "noarch",
                "build_target_arch": "aarch64_generic",
                "policy_schema": 2,
                "runtime_payload_sha256": bundle_summary["runtime_payload_sha256"],
                "files_manifest": {"name": files_manifest.name, "sha256": sha256(files_manifest)},
                "artifacts": artifacts,
                "artifact_files": packages,
                "apk_public_key": {"name": public_key.name, "sha256": sha256(public_key)},
                "feed_index": {"name": feed_index.name, "sha256": sha256(feed_index)},
                "feed_metadata": {"name": feed_meta.name, "sha256": sha256(feed_meta)},
                "feed_bootstrap": {"name": bootstrap.name, "sha256": sha256(bootstrap)},
                "release_bundle": {
                    "archive": bundle_summary["archive"],
                    "archive_sha256": bundle_summary["archive_sha256"],
                    "archive_size": bundle_summary["archive_size"],
                    "manifest": "release-manifest.json",
                    "manifest_sha256": bundle_summary["manifest_sha256"],
                    "manifest_sig": "release-manifest.json.sig",
                    "manifest_sig_sha256": bundle_summary["manifest_sig_sha256"],
                    "public_key": "opl-netfleet-bundle.pub",
                },
            }
            (directory / "manifest.json").write_text(json.dumps(manifest, sort_keys=True) + "\n")

        def write_diag(path: Path, ver: str, lane: str, commit: str, tree: str, manifest_sha: str) -> None:
            path.write_text(json.dumps({
                "schema": "opl-netfleet-openwrt-vm-diagnostic.v1",
                "diagnostic_passed": True,
                "diagnostic_lane": lane,
                "openwrt_version": ver,
                "source_commit": commit,
                "source_tree": tree,
                "checks": {"boot": True, "ssh": True, "var_symlink": True, "ubus": True},
                "lanes": {
                    lane: {
                        "ok": True,
                        "source_commit": commit,
                        "source_tree": tree,
                        "manifest_sha256": manifest_sha,
                        "checks": {"gate": True},
                    }
                },
            }))

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repo = root / "repo"
            repo.mkdir()

            def git(*args):
                return subprocess.check_output(
                    ["git", "-C", str(repo), *args], text=True, stderr=subprocess.DEVNULL
                ).strip()

            git("init", "-q", "-b", "main")
            git("config", "user.email", "test@example.invalid")
            git("config", "user.name", "Test")
            scripts = repo / "scripts"
            scripts.mkdir()
            for source in (PUBLISHER, VERIFIER, ROOT / "scripts/netfleet_usign.py"):
                shutil.copy2(source, scripts / source.name)
            git("add", ".")
            git("commit", "-qm", "qualified release-bundle candidate")
            commit = git("rev-parse", "HEAD")
            tree = git("rev-parse", f"{commit}^{{tree}}")
            remote = root / "remote.git"
            subprocess.run(["git", "clone", "--bare", str(repo), str(remote)], check=True, capture_output=True)
            git("remote", "add", "origin", str(remote))

            bin_dir = root / "bin"
            bin_dir.mkdir()
            gh = bin_dir / "gh"
            gh.write_text('''#!/bin/sh
[ "$1 $2" = "release view" ] || exit 90
echo '{"tagName":"v0.4.5"}'
''')
            gh.chmod(0o755)
            env = {**os.environ, "PATH": str(bin_dir) + os.pathsep + os.environ["PATH"]}

            bundle_dir = root / "bundle-candidate"
            bundle_dir.mkdir()
            write_bundle_candidate(bundle_dir, commit, tree)
            bundle_sha = sha256(bundle_dir / "manifest.json")
            gates = [("24.10.2", "opkg"), ("24.10.2", "bundle"), ("25.12.5", "bundle"), ("25.12.5", "migrate-bundle")]
            receipts = []
            for idx, (ver, lane) in enumerate(gates):
                p = root / f"diag-{idx}.json"
                write_diag(p, ver, lane, commit, tree, bundle_sha)
                receipts.append(p)

            args_ok = [str(scripts / PUBLISHER.name), "--repo", "example/test", "--tag", "v0.4.5",
                       "--candidate", str(bundle_dir)]
            for r in receipts:
                args_ok.extend(["--bundle-qualification", str(r)])
            res_ok = subprocess.run(args_ok, env=env, capture_output=True, text=True)
            self.assertNotEqual(res_ok.returncode, 0)
            self.assertIn("release already exists and is immutable", res_ok.stderr)

            args_missing = [str(scripts / PUBLISHER.name), "--repo", "example/test", "--tag", "v0.4.5",
                            "--candidate", str(bundle_dir)]
            for r in receipts[:-1]:
                args_missing.extend(["--bundle-qualification", str(r)])
            res_missing = subprocess.run(args_missing, env=env, capture_output=True, text=True)
            self.assertNotEqual(res_missing.returncode, 0)
            self.assertIn("missing required gates", res_missing.stderr)

            bad_sha = root / "bad-sha.json"
            write_diag(bad_sha, "25.12.5", "migrate-bundle", commit, tree, "f" * 64)
            args_bad_sha = [str(scripts / PUBLISHER.name), "--repo", "example/test", "--tag", "v0.4.5",
                            "--candidate", str(bundle_dir)]
            for r in receipts[:-1] + [bad_sha]:
                args_bad_sha.extend(["--bundle-qualification", str(r)])
            res_bad_sha = subprocess.run(args_bad_sha, env=env, capture_output=True, text=True)
            self.assertNotEqual(res_bad_sha.returncode, 0)
            self.assertIn("bundle VM diagnostic qualification invalid", res_bad_sha.stderr)

            legacy_dir = root / "legacy-candidate"
            legacy_dir.mkdir()
            write_release(legacy_dir, commit, tree)
            legacy_sha = sha256(legacy_dir / "manifest.json")
            legacy_receipts = []
            for idx, (ver, lane) in enumerate(gates):
                p = root / f"legacy-diag-{idx}.json"
                write_diag(p, ver, lane, commit, tree, legacy_sha)
                legacy_receipts.append(p)
            args_legacy = [str(scripts / PUBLISHER.name), "--repo", "example/test", "--tag", "v0.4.5",
                           "--candidate", str(legacy_dir)]
            for r in legacy_receipts:
                args_legacy.extend(["--bundle-qualification", str(r)])
            res_legacy = subprocess.run(args_legacy, env=env, capture_output=True, text=True)
            self.assertNotEqual(res_legacy.returncode, 0)
            self.assertIn("--bundle-qualification requires a release-bundle candidate", res_legacy.stderr)


class PackageLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for path in ('bin', 'etc/init.d', 'etc/config', 'etc/opl-netfleet',
                     'usr/libexec/opl-netfleet', 'tmp', 'mock-state'):
            (self.root / path).mkdir(parents=True, exist_ok=True)
        self.state_dir = self.root / 'mock-state'
        self._write_state_file('backend', 'native-mihomo')
        self._write_state_file('nikki_profile', 'file:OPL-NetFleet.json')
        self._write_state_file('not_ready', '0')
        self._write_state_file('dirty', '0')
        self._write_state_file('calls.log', '')
        for svc in ('opl-netfleet', 'opl-netfleet-core'):
            self._write_state_file(f'{svc}.enabled', '1')
            self._write_state_file(f'{svc}.running', '1')
            self._write_state_file(f'{svc}.generation', '1')
        (self.root / 'etc/opl-netfleet/backend.json').write_text('{"kind":"native-mihomo"}')
        (self.root / 'etc/config/nikki').write_text('fixture')
        (self.root / 'usr/libexec/opl-netfleet/main.uc').touch(mode=0o755)
        mock_sh = r'''#!/bin/sh
S="$NETFLEET_TEST_ROOT/mock-state"
name=${0##*/}
if [ "$#" -gt 0 ]; then
  line="$name"
  for a in "$@"; do line="$line	$a"; done
else
  line="$name"
fi
printf '%s\n' "$line" >>"$S/calls.log"
code=0
case "$name" in
  opl-netfleet|opl-netfleet-core)
    action=${1:-}
    case "$action" in
      running) [ "$(cat "$S/$name.running")" = 1 ] || code=1 ;;
      enabled) [ "$(cat "$S/$name.enabled")" = 1 ] || code=1 ;;
      stop) printf '0' >"$S/$name.running" ;;
      enable) printf '1' >"$S/$name.enabled" ;;
      disable) printf '0' >"$S/$name.enabled" ;;
      start|restart)
        if [ ! -e "$NETFLEET_TEST_ROOT/tmp/opl-netfleet-package-upgrade-state" ] || [ "${NETFLEET_PACKAGE_RESTORE:-}" = 1 ]; then
          printf '1' >"$S/$name.running"
          gen=$(cat "$S/$name.generation")
          printf '%s' "$((gen + 1))" >"$S/$name.generation"
        fi
        ;;
    esac
    ;;
  ucode)
    if [ "${1:-}" = -e ]; then
      cat "$S/backend"
      printf '\n'
    elif [ "${2:-}" = native-gateway-status ]; then
      run=$(cat "$S/opl-netfleet-core.running")
      nr=$(cat "$S/not_ready")
      dirty=$(cat "$S/dirty")
      [ "$run" = 1 ] && cr=true || cr=false
      [ "$run" = 1 ] && [ "$nr" = 0 ] && rd=true || rd=false
      [ "$run" = 0 ] && [ "$dirty" = 0 ] && cl=true || cl=false
      printf '{"ok":true,"result":{"core_running":%s,"ready":%s,"clean":%s}}\n' "$cr" "$rd" "$cl"
    elif [ "${2:-}" = disable ]; then
      printf 'subscription:recovery' >"$S/nikki_profile"
    elif [ "${2:-}" = package-cleanup ]; then
      :
    else
      code=1
    fi
    ;;
  jsonfilter)
    if [ "${1:-}" = -i ]; then
      src=$(cat "$2")
      expr=$4
    else
      src=$(cat)
      expr=$2
    fi
    key=${expr##*.}
    printf '%s' "$src" | tr -d '{}" \t\n\r' | tr ',' '\n' | awk -v k="$key" -F: '{ for (i=1; i<NF; i++) if ($i == k) { print $(i+1); exit } }'
    ;;
  uci)
    case " $* " in *" get "*) cat "$S/nikki_profile"; printf '\n' ;; esac
    ;;
esac
exit "$code"
'''
        for name in ('ucode', 'jsonfilter', 'uci', 'sleep'):
            target = self.root / 'bin' / name
            target.write_text(mock_sh)
            target.chmod(0o755)
        for name in ('opl-netfleet', 'opl-netfleet-core'):
            target = self.root / 'etc/init.d' / name
            target.write_text(mock_sh)
            target.chmod(0o755)
        self.env = {**os.environ, 'PATH': f'{self.root}/bin:{os.environ["PATH"]}',
                    'NETFLEET_TEST_ROOT': str(self.root), 'PKG_UPGRADE': '1'}

    def _write_state_file(self, name: str, value: str):
        (self.state_dir / name).write_text(value)

    def read_state(self):
        calls = [line.split('\t') for line in (self.state_dir / 'calls.log').read_text().splitlines() if line]
        result = {
            'backend': (self.state_dir / 'backend').read_text(),
            'calls': calls,
            'nikki_profile': (self.state_dir / 'nikki_profile').read_text(),
            'not_ready': (self.state_dir / 'not_ready').read_text() == '1',
            'dirty': (self.state_dir / 'dirty').read_text() == '1',
        }
        for svc in ('opl-netfleet', 'opl-netfleet-core'):
            result[svc] = {
                'enabled': (self.state_dir / f'{svc}.enabled').read_text() == '1',
                'running': (self.state_dir / f'{svc}.running').read_text() == '1',
                'generation': int((self.state_dir / f'{svc}.generation').read_text()),
            }
        return result

    def update_state(self, **changes):
        if 'backend' in changes:
            self._write_state_file('backend', str(changes['backend']))
            (self.root / 'etc/opl-netfleet/backend.json').write_text(json.dumps({'kind': changes['backend']}))
        if 'nikki_profile' in changes:
            self._write_state_file('nikki_profile', str(changes['nikki_profile']))
        if 'not_ready' in changes:
            self._write_state_file('not_ready', '1' if changes['not_ready'] else '0')
        if 'dirty' in changes:
            self._write_state_file('dirty', '1' if changes['dirty'] else '0')
        if 'calls' in changes:
            self._write_state_file('calls.log', ''.join('\t'.join(row) + '\n' for row in changes['calls']))
        for svc in ('opl-netfleet', 'opl-netfleet-core'):
            if svc in changes:
                info = changes[svc]
                self._write_state_file(f'{svc}.enabled', '1' if info['enabled'] else '0')
                self._write_state_file(f'{svc}.running', '1' if info['running'] else '0')
                self._write_state_file(f'{svc}.generation', str(info['generation']))

    def hook(self, name, **environment):
        source = (ROOT / 'openwrt/Makefile').read_text()
        body = source.split(f'define Package/opl-netfleet/{name}\n', 1)[1].split('\nendef', 1)[0]
        body = body.replace('$$', '$')
        for prefix in ('/etc/', '/usr/libexec/', '/tmp/opl-netfleet'):
            body = body.replace(prefix, f'{self.root}{prefix}')
        return subprocess.run(['sh', '-c', body], env={**self.env, **environment},
                              capture_output=True, text=True, check=False)

    def default_postinst(self):
        for name in ('opl-netfleet', 'opl-netfleet-core'):
            for action in ('enable', 'start'):
                subprocess.run([str(self.root / 'etc/init.d' / name), action],
                               env=self.env, check=True, capture_output=True)

    def test_native_upgrade_reloads_both_running_owners(self):
        before = self.read_state()
        result = self.hook('preinst')
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertFalse(self.read_state()['opl-netfleet-core']['running'])
        self.default_postinst()
        self.assertFalse(self.read_state()['opl-netfleet-core']['running'])
        result = self.hook('postinst')
        self.assertEqual(0, result.returncode, result.stderr)
        after = self.read_state()
        for name in ('opl-netfleet', 'opl-netfleet-core'):
            self.assertTrue(after[name]['running'])
            self.assertTrue(after[name]['enabled'])
            self.assertGreater(after[name]['generation'], before[name]['generation'])
        self.assertFalse((self.root / 'tmp/opl-netfleet-package-upgrade-state').exists())

    def test_upgrade_preserves_enabled_but_stopped_services(self):
        for enabled in (True, False):
            with self.subTest(enabled=enabled):
                self.update_state(**{name: {'enabled': enabled, 'running': False, 'generation': 1}
                                     for name in ('opl-netfleet', 'opl-netfleet-core')})
                self.assertEqual(0, self.hook('preinst').returncode)
                self.default_postinst()
                result = self.hook('postinst')
                self.assertEqual(0, result.returncode, result.stderr)
                for name in ('opl-netfleet', 'opl-netfleet-core'):
                    self.assertEqual({'enabled': enabled, 'running': False, 'generation': 1},
                                     self.read_state()[name])

    def test_nikki_upgrade_restarts_only_supervisor(self):
        self.update_state(backend='nikki-mihomo', **{
            'opl-netfleet-core': {'enabled': False, 'running': False, 'generation': 1}})
        self.assertEqual(0, self.hook('preinst').returncode)
        self.default_postinst()
        result = self.hook('postinst')
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertTrue(self.read_state()['opl-netfleet']['running'])
        self.assertEqual({'enabled': False, 'running': False, 'generation': 1},
                         self.read_state()['opl-netfleet-core'])

    def test_fresh_install_does_not_activate_either_service(self):
        result = self.hook('postinst', PKG_UPGRADE='0')
        self.assertEqual(0, result.returncode, result.stderr)
        for name in ('opl-netfleet', 'opl-netfleet-core'):
            self.assertFalse(self.read_state()[name]['running'])
            self.assertFalse(self.read_state()[name]['enabled'])

    def test_failed_native_readback_preserves_recovery_state(self):
        self.assertEqual(0, self.hook('preinst').returncode)
        self.update_state(not_ready=True)
        self.assertNotEqual(0, self.hook('postinst').returncode)
        self.assertTrue((self.root / 'tmp/opl-netfleet-package-upgrade-state').exists())
        self.assertFalse(self.read_state()['opl-netfleet']['running'])

    def test_preupgrade_refuses_unclean_native_dataplane(self):
        self.update_state(dirty=True)
        self.assertNotEqual(0, self.hook('preinst').returncode)
        self.assertTrue((self.root / 'tmp/opl-netfleet-package-upgrade-state').exists())

    def test_native_removal_requires_clean_dataplane(self):
        self.update_state(dirty=True)
        self.assertNotEqual(0, self.hook('prerm', PKG_UPGRADE='0').returncode)
        self.update_state(dirty=False)
        result = self.hook('prerm', PKG_UPGRADE='0')
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertFalse(self.read_state()['opl-netfleet-core']['running'])
        self.assertFalse(self.read_state()['opl-netfleet-core']['enabled'])
        self.assertNotIn('native-core-stop', json.dumps(self.read_state()['calls']))

    def test_nikki_removal_retains_existing_owner_cleanup(self):
        self.update_state(backend='nikki-mihomo')
        result = self.hook('prerm', PKG_UPGRADE='0')
        self.assertEqual(0, result.returncode, result.stderr)
        actions = [call[-1] for call in self.read_state()['calls'] if call[0] == 'ucode']
        self.assertIn('disable', actions)
        self.assertIn('package-cleanup', actions)


class DeliveryPreflightTests(unittest.TestCase):
    @staticmethod
    def _module():
        spec = importlib.util.spec_from_file_location(
            'delivery_preflight', ROOT / 'scripts/netfleet-delivery-preflight.py'
        )
        module = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(module)
        return module

    def test_source_contract_binds_components_to_platform_paths(self):
        module = self._module()
        result = module.source_contract(module.git('rev-parse', 'HEAD'))
        self.assertEqual(
            result,
            {
                'platform_paths_provider': True,
                'components_path_dependency': True,
                'path_shadowing': False,
            },
        )

    def test_fixture_inventory_rejects_editor_files_and_symlinks(self):
        module = self._module()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'cycle.json').write_text('{}\n')
            (root / '._cycle.json').write_text('temporary\n')
            with self.assertRaisesRegex(ValueError, 'temporary'):
                module.fixture_inventory(root)
            (root / '._cycle.json').unlink()
            (root / 'link').symlink_to(root / 'cycle.json')
            with self.assertRaisesRegex(ValueError, 'symlink'):
                module.fixture_inventory(root)

    def test_test_ref_path_policy_is_narrow(self):
        module = self._module()
        self.assertTrue(module.is_test_only_path('scripts/openwrt-vm/guest-qualify.sh'))
        self.assertTrue(module.is_test_only_path('tests/fixture.uc'))
        self.assertFalse(module.is_test_only_path('openwrt/files/usr/libexec/opl-netfleet/main.uc'))


class PrebuiltComponentFixtures(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('component_fixtures', ROOT / 'scripts/openwrt-vm/component-fixtures.py')
        self.fixtures = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.fixtures)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.candidate = self.root / 'candidate'
        self.output = self.root / 'fixtures'
        self.candidate.mkdir(); self.output.mkdir()
        self.manifest = {'source_commit': 'a' * 40, 'source_tree': 'b' * 40, 'package_version': '1.2.3'}
        (self.candidate / 'manifest.json').write_text(json.dumps(self.manifest))
        (self.output / 'fixture.json').write_text(json.dumps({'schema_version': 1, 'version': '1.2.3', **self.manifest}))
        (self.output / 'old').mkdir()
        (self.output / 'old/package.apk').write_bytes(b'synthetic update bytes')
        self.fixtures.seal_prebuilt(self.candidate, self.output)

    def test_frozen_candidate_and_complete_fixture_resources_are_reusable(self):
        self.fixtures.validate_prebuilt(self.candidate, self.output)
        for kind in ('changed', 'extra', 'symlink'):
            path = self.output / ('old/package.apk' if kind == 'changed' else kind)
            if kind == 'changed': path.write_bytes(b'different bytes')
            elif kind == 'extra': path.write_bytes(b'undeclared resource')
            else: path.symlink_to(self.candidate / 'manifest.json')
            with self.assertRaises(SystemExit): self.fixtures.validate_prebuilt(self.candidate, self.output)
            if kind == 'changed': path.write_bytes(b'synthetic update bytes')
            else: path.unlink()
        self.fixtures.validate_prebuilt(self.candidate, self.output)

    def test_other_candidate_bytes_cannot_reuse_the_fixture(self):
        (self.candidate / 'manifest.json').write_text(json.dumps({**self.manifest, 'package_version': '1.2.4'}))
        with self.assertRaises(SystemExit): self.fixtures.validate_prebuilt(self.candidate, self.output)
        (self.candidate / 'manifest.json').write_text(json.dumps(self.manifest))
        path = self.output / 'fixture.json'
        value = json.loads(path.read_text()); value['version'] = '9.9.9'
        path.write_text(json.dumps(value))
        with self.assertRaises(SystemExit): self.fixtures.validate_prebuilt(self.candidate, self.output)


class IncrementalPackagingTests(unittest.TestCase):
    def test_thin_shell_packager_requires_signing_keys_and_core_only_guard(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sdk = root / 'sdk'
            sdk.mkdir()
            (sdk / 'Makefile').write_text('all:\n\t@true\n')
            res1 = subprocess.run(
                [str(PACKAGER), '--sdk', str(sdk), '--core-arch', 'aarch64_generic'],
                text=True, capture_output=True, check=False,
            )
            self.assertNotEqual(res1.returncode, 0)
            self.assertIn('--core-only', res1.stderr)

    def test_feed_build_merge_feed_overlays_by_package_name(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            base_feed = root / 'base_feed'
            cand = root / 'cand'
            out = root / 'out'
            base_feed.mkdir(); cand.mkdir()
            sign_key = root / 'priv.pem'
            sign_key.write_text('dummy-key\n')
            pub_key = root / 'opl-netfleet-apk.pem'
            pub_key.write_text('-----BEGIN PUBLIC KEY-----\ndummy\n-----END PUBLIC KEY-----\n')
            (cand / 'opl-netfleet-apk.pem').write_text(pub_key.read_text())

            base_a = base_feed / 'opl-netfleet-plugin-compilation-0.9.0.apk'
            base_b = base_feed / 'opl-netfleet-plugin-models-0.8.0.apk'
            new_a = cand / 'opl-netfleet-plugin-compilation-0.9.1.apk'
            base_a.write_bytes(b'old-comp-apk')
            base_b.write_bytes(b'keep-models-apk')
            new_a.write_bytes(b'new-comp-apk')
            (cand / 'plugin-release.json').write_text(json.dumps({
                'schema': 'opl-netfleet-plugin-release.v1',
                'build_target_arch': 'aarch64_generic',
                'artifacts': [{
                    'package': 'opl-netfleet-plugin-compilation',
                    'name': new_a.name,
                    'sha256': sha256(new_a),
                    'size': new_a.stat().st_size,
                    'version': '0.9.1',
                }],
                'dependency_artifacts': [],
            }))

            fake_apk = root / 'apk'
            fake_apk.write_text('#!' + sys.executable + '''
import json, pathlib, re, sys
args = sys.argv[1:]
cmd = args[0]
def meta(p):
    m = re.fullmatch(r'(.+)-([0-9]+\\.[0-9]+\\.[0-9]+)\\.apk', pathlib.Path(p).name)
    return {'name': m.group(1), 'version': m.group(2), 'arch': 'noarch'}
if cmd == 'verify':
    sys.exit(0)
if cmd == 'adbdump':
    target = args[-1]
    if target.endswith('.adb'):
        print(pathlib.Path(target).read_text())
    else:
        print(json.dumps({'info': meta(target)}))
    sys.exit(0)
if cmd == 'mkndx':
    out_idx = args[args.index('--output') + 1]
    apks = [a for a in args if a.endswith('.apk')]
    pathlib.Path(out_idx).write_text(json.dumps({'packages': [meta(a) for a in apks]}))
    sys.exit(0)
raise SystemExit(f'unexpected apk cmd: {args}')
''')
            fake_apk.chmod(0o755)
            res = subprocess.run(
                [str(FEED_BUILDER), '--packages', str(cand), '--merge-feed', str(base_feed),
                 '--apk', str(fake_apk), '--sign-key', str(sign_key), '--output', str(out)],
                text=True, capture_output=True, check=False,
            )
            self.assertEqual(0, res.returncode, res.stderr)
            self.assertTrue((out / new_a.name).is_file())
            self.assertTrue((out / base_b.name).is_file())
            self.assertFalse((out / base_a.name).exists())
            idx = json.loads((out / 'index.json').read_text())
            self.assertEqual(idx['packages'], {
                'opl-netfleet-plugin-compilation': '0.9.1',
                'opl-netfleet-plugin-models': '0.8.0',
            })
            # Duplicate base package in merge-feed must be rejected cleanly.
            dup = base_feed / 'opl-netfleet-plugin-models-0.8.1.apk'
            dup.write_bytes(b'dup')
            bad_res = subprocess.run(
                [str(FEED_BUILDER), '--packages', str(cand), '--merge-feed', str(base_feed),
                 '--apk', str(fake_apk), '--sign-key', str(sign_key), '--output', str(out)],
                text=True, capture_output=True, check=False,
            )
            self.assertNotEqual(bad_res.returncode, 0)


if __name__ == '__main__': unittest.main()
