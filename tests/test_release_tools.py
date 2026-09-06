import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).parents[1]
PACKAGER = ROOT / 'scripts/netfleet-package-build.sh'
PREPARER = ROOT / 'scripts/prepare-openwrt-sdk.sh'
VERIFIER = ROOT / 'scripts/verify-netfleet-release.py'
PUBLISHER = ROOT / 'scripts/publish-netfleet-release.sh'
WORKFLOW = ROOT / '.github/workflows/netfleet-release.yml'
FEED_BUILDER = ROOT / 'scripts/netfleet-feed-build.sh'
INSTALLER = ROOT / 'scripts/install-netfleet.sh'


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_release(directory: Path, commit: str, tree: str, version: str = '0.4.5') -> None:
    packages = {
        'opl-netfleet': f'opl-netfleet-{version}-r1.apk',
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
    def test_luci_release_dependencies_cannot_reuse_previous_module_urls(self):
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
                self.assertEqual(4, len(visited))
                self.assertFalse((resources / 'netfleet/managed.js').exists())
                namespaces.append({str(path.relative_to(resources)) for path in visited})
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

    def test_packager_requires_sdk_without_creating_artifacts(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'out'
            result = subprocess.run([str(PACKAGER), '--output', str(output)], text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(output.exists())

    def test_package_sources_are_versioned_and_do_not_embed_instance_inputs(self):
        runtime = (ROOT / 'openwrt/Makefile').read_text()
        luci = (ROOT / 'openwrt/luci-app-netfleet/Makefile').read_text()
        self.assertIn('PKG_VERSION:=0.5.3', runtime)
        self.assertIn('PKG_RELEASE:=1', runtime)
        self.assertIn('PKG_LICENSE:=GPL-3.0-only', runtime)
        self.assertIn('PKG_MAINTAINER:=OPL NetFleet', runtime)
        self.assertIn('PKGARCH:=all', runtime)
        self.assertIn('PKG_VERSION:=0.5.3', luci)
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
        self.assertIn('opl-netfleet-${version}-r${release}.apk', packager)
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
                        apk_tool.write_text('#!/bin/sh\nwhile [ "$#" -gt 0 ]; do\n'
                                            '  if [ "$1" = --output ]; then shift; output=$1; fi\n'
                                            '  case "$1" in *.apk) packages="$packages $1";; esac\n'
                                            '  shift\ndone\nprintf "%s\\n" "$packages" >"$output"\n')
                        apk_tool.chmod(0o755)
                        feed = feed_root / 'feed'
                        built = subprocess.run([str(FEED_BUILDER), '--packages', str(release),
                                                '--apk', str(apk_tool), '--sign-key', str(release / 'opl-netfleet-apk.pem'),
                                                '--output', str(feed)], text=True, capture_output=True)
                        self.assertEqual(built.returncode, 0, built.stderr)
                        self.assertEqual(len(list(feed.glob('*.apk'))), 3)
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
        self.assertEqual(7, receipt['file_count'])

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

    def test_feed_bootstrap_configures_feed_and_installs_both_packages_once(self):
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
            apk = bin_dir / 'apk'
            apk.write_text(
                '#!/bin/sh\n'
                'if [ "$1" = info ]; then\n'
                '  case " $NETFLEET_INSTALLED " in *" $3 "*) exit 0 ;; *) exit 1 ;; esac\n'
                'fi\n'
                'printf "%s\\n" "$*" >>"$NETFLEET_APK_LOG"\n'
            )
            apk.chmod(0o755)
            uci = bin_dir / 'uci'
            uci.write_text('#!/bin/sh\nprintf "%s\\n" "subscription:fixture"\n')
            uci.chmod(0o755)
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
            for installed in ('', 'opl-netfleet', 'luci-app-netfleet', 'opl-netfleet luci-app-netfleet'):
                with self.subTest(installed=installed):
                    log.write_text('')
                    result = subprocess.run(
                        [str(INSTALLER)], env={**env, 'NETFLEET_INSTALLED': installed},
                        text=True, capture_output=True, check=False,
                    )
                    self.assertEqual(0, result.returncode, result.stderr)
                    expected = ['--timeout 300 update']
                    if installed != 'opl-netfleet luci-app-netfleet':
                        expected.append('--timeout 300 add opl-netfleet luci-app-netfleet')
                    expected.append('--timeout 300 upgrade opl-netfleet luci-app-netfleet')
                    self.assertEqual(expected, log.read_text().splitlines())
            self.assertEqual((feed / 'opl-netfleet-apk.pem').read_bytes(), (keys / 'opl-netfleet-apk.pem').read_bytes())
            self.assertEqual('https://fixture.invalid/release/packages.adb\n', repository.read_text())

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
            apk = bin_dir / 'apk'
            apk.write_text('#!/bin/sh\nprintf called >>"$NETFLEET_APK_LOG"\n')
            apk.chmod(0o755)
            uci = bin_dir / 'uci'
            uci.write_text('#!/bin/sh\nprintf "%s\\n" "subscription:fixture"\n')
            uci.chmod(0o755)
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
        self.assertIn('name: netfleet-openwrt-candidate-${{ env.NETFLEET_SOURCE_COMMIT }}', workflow)
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
        self.assertIn('candidate source is not current canonical main', source)
        self.assertIn('release already exists and is immutable', source)
        self.assertIn('gh release download', source)
        self.assertEqual(2, source.count('verify-netfleet-release.py'))

class PackageLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for path in ('bin', 'etc/init.d', 'etc/config', 'etc/opl-netfleet',
                     'usr/libexec/opl-netfleet', 'tmp'):
            (self.root / path).mkdir(parents=True, exist_ok=True)
        self.state = self.root / 'state.json'
        self.state.write_text(json.dumps({
            'backend': 'native-mihomo', 'calls': [], 'nikki_profile': 'file:OPL-NetFleet.json',
            'opl-netfleet': {'enabled': True, 'running': True, 'generation': 1},
            'opl-netfleet-core': {'enabled': True, 'running': True, 'generation': 1},
        }))
        (self.root / 'etc/opl-netfleet/backend.json').write_text('{"kind":"native-mihomo"}')
        (self.root / 'etc/config/nikki').write_text('fixture')
        (self.root / 'usr/libexec/opl-netfleet/main.uc').touch(mode=0o755)
        mock = f'#!{sys.executable}\n' + r'''
import json, os, sys
from pathlib import Path
root = Path(os.environ['NETFLEET_TEST_ROOT'])
path = root / 'state.json'
state = json.loads(path.read_text())
name = Path(sys.argv[0]).name
args = sys.argv[1:]
state['calls'].append([name, *args])
code = 0
if name in ('opl-netfleet', 'opl-netfleet-core'):
    action = args[0]
    service = state[name]
    if action in ('running', 'enabled'):
        code = 0 if service[action] else 1
    elif action == 'stop':
        service['running'] = False
    elif action in ('enable', 'disable'):
        service['enabled'] = action == 'enable'
    elif action in ('start', 'restart'):
        guarded = (root / 'tmp/opl-netfleet-package-upgrade-state').exists()
        if not guarded or os.environ.get('NETFLEET_PACKAGE_RESTORE') == '1':
            service['running'] = True
            service['generation'] += 1
elif name == 'ucode':
    if args[0] == '-e':
        print(state['backend'])
    elif 'native_gateway.uc' in args[0]:
        running = state['opl-netfleet-core']['running']
        print(json.dumps({'ok': True, 'result': {
            'core_running': running, 'ready': running and not state.get('not_ready'),
            'clean': not running and not state.get('dirty'),
        }}))
    elif args[1] == 'disable':
        state['nikki_profile'] = 'subscription:recovery'
    elif args[1] == 'package-cleanup':
        pass
    else:
        code = 1
elif name == 'jsonfilter':
    value = json.load(sys.stdin)
    for key in args[args.index('-e') + 1].removeprefix('@.').split('.'):
        value = value[key]
    print(str(value).lower() if isinstance(value, bool) else value)
elif name == 'uci' and 'get' in args:
    print(state['nikki_profile'])
path.write_text(json.dumps(state))
sys.exit(code)
'''
        for name in ('ucode', 'jsonfilter', 'uci', 'sleep'):
            target = self.root / 'bin' / name
            target.write_text(mock)
            target.chmod(0o755)
        for name in ('opl-netfleet', 'opl-netfleet-core'):
            target = self.root / 'etc/init.d' / name
            target.write_text(mock)
            target.chmod(0o755)
        self.env = {**os.environ, 'PATH': f'{self.root}/bin:{os.environ["PATH"]}',
                    'NETFLEET_TEST_ROOT': str(self.root), 'PKG_UPGRADE': '1'}

    def read_state(self):
        return json.loads(self.state.read_text())

    def update_state(self, **changes):
        self.state.write_text(json.dumps({**self.read_state(), **changes}))

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
        self.assertNotEqual(0, self.hook('prerm').returncode)
        self.update_state(dirty=False)
        result = self.hook('prerm')
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertFalse(self.read_state()['opl-netfleet-core']['running'])
        self.assertFalse(self.read_state()['opl-netfleet-core']['enabled'])
        self.assertNotIn('native-core-stop', json.dumps(self.read_state()['calls']))

    def test_nikki_removal_retains_existing_owner_cleanup(self):
        self.update_state(backend='nikki-mihomo')
        result = self.hook('prerm')
        self.assertEqual(0, result.returncode, result.stderr)
        actions = [call[-1] for call in self.read_state()['calls'] if call[0] == 'ucode']
        self.assertIn('disable', actions)
        self.assertIn('package-cleanup', actions)


if __name__ == '__main__': unittest.main()
