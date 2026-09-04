import hashlib
import json
import os
import subprocess
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
        self.assertIn('PKG_VERSION:=0.4.5', runtime)
        self.assertIn('PKG_RELEASE:=1', runtime)
        self.assertIn('PKG_LICENSE:=Apache-2.0', runtime)
        self.assertIn('PKG_MAINTAINER:=OPL NetFleet', runtime)
        self.assertIn('PKGARCH:=all', runtime)
        self.assertIn('PKG_VERSION:=0.4.5', luci)
        self.assertIn('PKGARCH:=all', luci)
        self.assertIn('include $(INCLUDE_DIR)/package.mk', luci)
        self.assertNotIn('feeds/luci/luci.mk', luci)
        self.assertIn('Package/luci-app-netfleet/install', luci)
        self.assertIn('Package/luci-app-netfleet/postinst', luci)
        self.assertIn('overview-$(NETFLEET_VIEW_VERSION).js', luci)
        self.assertIn("uci set 'rpcd.@rpcd[0].timeout=300'", luci)
        self.assertIn('[ "$$current_timeout" -ge 300 ]', luci)
        self.assertIn('/etc/init.d/rpcd restart', luci)
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

    def test_feed_builder_requires_exactly_two_apks(self):
        source = FEED_BUILDER.read_text()
        self.assertIn('feed requires exactly two APK artifacts', source)
        self.assertIn('apk_tool" mkndx', source)
        self.assertIn('--sign ', source)

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
            apk.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >>"$NETFLEET_APK_LOG"\n')
            apk.chmod(0o755)
            log = root / 'apk.log'
            result = subprocess.run(
                [str(INSTALLER)],
                env={
                    **os.environ,
                    'PATH': f'{bin_dir}:{os.environ["PATH"]}',
                    'NETFLEET_INSTALL_TESTING': '1',
                    'NETFLEET_FEED_BASE': 'https://fixture.invalid/release',
                    'NETFLEET_FIXTURE_FEED': str(feed),
                    'NETFLEET_APK_KEYS_DIR': str(keys),
                    'NETFLEET_APK_REPOSITORY_FILE': str(repository),
                    'NETFLEET_APK_LOG': str(log),
                },
                text=True, capture_output=True, check=False,
            )
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual((feed / 'opl-netfleet-apk.pem').read_bytes(), (keys / 'opl-netfleet-apk.pem').read_bytes())
            self.assertEqual('https://fixture.invalid/release/packages.adb\n', repository.read_text())
            self.assertEqual(
                ['--timeout 300 update', '--timeout 300 add --upgrade opl-netfleet luci-app-netfleet'],
                log.read_text().splitlines(),
            )

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

if __name__ == '__main__': unittest.main()
