"""Native OpenWrt core lifecycle, bytecode/payload gate, and firmware delegation boundaries."""
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
INIT = ROOT / 'openwrt/files/etc/init.d/opl-netfleet-core'


def _load_module(name: str, relative: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


gate = _load_module('native_gate', 'scripts/verify-native-runtime.py')
feed = _load_module('feed_metadata', 'scripts/openwrt-feed-metadata.py')


class NativeLifecycleTest(unittest.TestCase):
    def run_init(self, body):
        script = '\n'.join([
            'extra_command() { :; }',
            '. "$1"',
            'procd_lock() { echo lock; }',
            'procd_kill() { echo "kill:$1"; }',
            body,
        ])
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package = root / 'plugin-package'
            package.write_text('#!/bin/sh\nexit "${PLUGIN_READY_EXIT:-0}"\n')
            package.chmod(0o755)
            source = root / 'init'
            source.write_text(INIT.read_text().replace('/usr/libexec/opl-netfleet-plugin-package', str(package)))
            return subprocess.run(
                ['sh', '-c', script, 'test', str(source)],
                check=False, text=True, capture_output=True,
            )

    def test_plugin_maintenance_prevents_starting_core_resources(self):
        result = self.run_init('''
export PLUGIN_READY_EXIT=1
gateway_action() { echo unexpected-prepare; }
start_service
''')
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')

    def test_reconcile_shares_service_lock_and_propagates_failure(self):
        result = self.run_init('''
ucode() { echo "gateway:$2"; return 7; }
reconcile
''')
        self.assertEqual(result.returncode, 7)
        self.assertEqual(result.stdout.splitlines(), ['lock', 'gateway:native-gateway-reconcile'])

    def test_running_checks_core_not_lifecycle_observer(self):
        result = self.run_init('''
procd_running() { echo "$1:$2"; return 1; }
service_running
''')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout.strip(), 'opl-netfleet-core:core')

    def test_failed_attach_cleans_before_core_stop(self):
        result = self.run_init('''
ucode() { echo "gateway:$2" >&2; [ "$2" != native-gateway-attach ]; }
service_started
''')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr.splitlines(), ['gateway:native-gateway-attach', 'gateway:native-gateway-cleanup'])
        self.assertEqual(result.stdout.splitlines(), ['kill:opl-netfleet-core'])

    def test_normal_stop_uses_same_cleanup_owner(self):
        result = self.run_init('''
ucode() { echo "gateway:$2" >&2; }
stop_service
service_stopped
''')
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr.splitlines(), ['gateway:native-gateway-cleanup', 'gateway:native-gateway-cleanup'])

    def test_core_and_notification_observer_have_distinct_instances(self):
        result = self.run_init('''
NETFLEET_PACKAGE_RESTORE=1
gateway_action() { return 0; }
config_load() { :; }
config_get() { eval "$1="; }
config_get_bool() { eval "$1=0"; }
procd_open_instance() { echo "instance:$1"; }
procd_set_param() {
    case "$1" in command|respawn) echo "$*" ;; esac
}
procd_append_param() { :; }
procd_close_instance() { :; }
start_service
''')
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.splitlines(), [
            'instance:core',
            'command /usr/bin/mihomo -d /etc/opl-netfleet/native/run -f /etc/opl-netfleet/native/run/config.yaml',
            'respawn 3600 5 5',
            'instance:lifecycle',
            'command /usr/bin/ucode /usr/libexec/opl-netfleet/main.uc native-gateway-watch',
            'respawn 3600 1 0',
        ])


class NativeRuntimeGate(unittest.TestCase):
    def test_bytecode_requires_matching_checked_source_and_payload(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            relative = Path('usr/libexec/opl-netfleet/plugins/example/main.uc')
            source = root / 'source' / relative
            installed = root / 'installed' / relative
            source.parent.mkdir(parents=True)
            installed.parent.mkdir(parents=True)
            source.write_text('return context => ({});')
            data = b'#!/usr/bin/env ucode\n\x1bucb\x01\xff'
            installed.write_bytes(data)
            entry = {'plugin': 'example', 'module': 'main.uc',
                     'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
                     'compiled_sha256': hashlib.sha256(data).hexdigest()}
            with self.assertRaisesRegex(ValueError, 'unverified'):
                gate.inspect_payload(root / 'installed')
            checked = gate.verified_bytecode(root / 'source', [entry])
            self.assertEqual(gate.inspect_payload(root / 'installed', checked), 1)
            installed.write_bytes(data + b'changed')
            with self.assertRaisesRegex(ValueError, 'unverified'):
                gate.inspect_payload(root / 'installed', checked)
            source.write_text('return context => ({changed: true});')
            with self.assertRaisesRegex(ValueError, 'source mismatch'):
                gate.verified_bytecode(root / 'source', [entry])
            source.write_text('command(["python3", "helper.py"]);')
            entry['source_sha256'] = hashlib.sha256(source.read_bytes()).hexdigest()
            with self.assertRaisesRegex(ValueError, 'caller'):
                gate.verified_bytecode(root / 'source', [entry])

    def test_payload_only_and_native_identifiers(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'usr/libexec').mkdir(parents=True)
            (root / 'tests').mkdir()
            (root / 'tests/probe.py').write_text('test_only = True')
            script = root / 'usr/libexec/control.uc'
            script.write_text('const matches = filter(nodes, node => node.name == state.now);\n')
            self.assertEqual(gate.inspect_payload(root), 1)
            script.write_text('command(["python3", "/tmp/helper.py"]);\n')
            with self.assertRaisesRegex(ValueError, 'caller'):
                gate.inspect_payload(root)
            script.unlink()
            script = root / 'usr/libexec/control'
            script.write_text('#!/usr/bin/env python3\n')
            with self.assertRaisesRegex(ValueError, 'caller'):
                gate.inspect_payload(root)
            script.unlink()
            script.symlink_to('/missing/python3')
            with self.assertRaisesRegex(ValueError, 'link'):
                gate.inspect_payload(root)

    def test_verify_plugin_modes_rejects_group_or_other_writable_paths(self):
        gate.verify_plugin_modes({'paths': [
            {'name': 'usr/libexec/opl-netfleet/plugins', 'acl': {'mode': 0o755}, 'files': []},
            {'name': 'usr/libexec/opl-netfleet/plugins/events', 'acl': {'mode': '755'},
             'files': [{'name': 'manifest.json', 'acl': {'mode': 0o644}},
                       {'name': 'control', 'acl': {'mode': '755'}}]},
        ]})
        with self.assertRaisesRegex(ValueError, 'unsafe plugin directory mode'):
            gate.verify_plugin_modes({'paths': [
                {'name': 'usr/libexec/opl-netfleet/plugins/events', 'acl': {'mode': 0o775}, 'files': []},
            ]})
        with self.assertRaisesRegex(ValueError, 'unsafe plugin file mode'):
            gate.verify_plugin_modes({'paths': [
                {'name': 'usr/libexec/opl-netfleet/plugins/events/lib', 'acl': {'mode': 0o755},
                 'files': [{'name': 'model.uc', 'acl': {'mode': 0o664}}]},
            ]})


class FeedMetadataTests(unittest.TestCase):
    def test_preserves_full_apk_versions_and_architecture(self):
        result = feed.metadata({'packages': [
            {'name': 'plugin', 'version': '1.2.3', 'arch': 'noarch'},
            {'name': 'core', 'version': '2.0.0-r1', 'arch': 'aarch64_generic'},
        ]}, 'aarch64_generic')
        self.assertEqual(result, {'version': 2, 'architecture': 'aarch64_generic',
                                  'packages': {'core': '2.0.0-r1', 'plugin': '1.2.3'}})

    def test_refuses_conflicting_or_wrong_architecture_candidates(self):
        row = {'name': 'plugin', 'version': '1.2.3', 'arch': 'noarch'}
        for rows in [[], [row, row], [{**row, 'arch': 'x86_64'}], [{**row, 'name': '../plugin'}]]:
            with self.subTest(rows=rows), self.assertRaises(ValueError):
                feed.metadata({'packages': rows}, 'aarch64_generic')


class NativeFirmwareViewTests(unittest.TestCase):
    def test_native_view_forwards_feeds_and_explicitly_delegates_install(self):
        source = ROOT / 'openwrt/luci-app-netfleet/htdocs/luci-static/resources/view/netfleet/firmware.js'
        script = r'''
const assert = require('node:assert/strict');
const fsNode = require('node:fs');
const calls = [];
const fixtures = {
 describe: {repositories: {addon:'https://example.org/packages.adb'}, repository_keys:['public-key'],
  repositories_mode:'append', excluded:['luci-theme-argon']},
 install: {started:true}
};
const view={request_hash:new Map(),handleRequest:function(...args){calls.push({super:'handleRequest',args});}};
new Function('view','attended','fs','ui','poll','_','E','setTimeout',fsNode.readFileSync(process.argv[1],'utf8'))(
 {extend: definition => definition},view,
 {exec: async (path,args) => { calls.push({path,args}); return {code:0,stdout:JSON.stringify(fixtures[args[0]])}; }},
 {showModal(){},addNotification(){},hideModal(){},awaitReconnect(){}},
 {add(){},remove(){}}, text=>text, ()=>({}), ()=>{}
);
(async()=>{
 const content={version:'25.12.6',packages:['netfleet','luci-theme-argon']};
 await view.handleRequest('server',true,content,{},{});
 assert.deepEqual(content.packages,['netfleet']);
 assert.deepEqual(content.repositories,fixtures.describe.repositories);
 assert.deepEqual(content.repository_keys,['public-key']);
 assert.equal(view.targetVersion,'25.12.6');
 assert.equal(calls.at(-1).super,'handleRequest');
 await view.handleInstall('https://example.org/store/image',false,'a'.repeat(64));
 assert.equal(calls.filter(c=>c.args?.[0]==='install').length,0);
 await view.handleInstall('https://example.org/store/image',true,'a'.repeat(64));
 assert.deepEqual(calls.at(-1).args,['install','https://example.org/store/image','a'.repeat(64),'25.12.6']);
 assert.equal(calls.at(-1).path,'/usr/libexec/opl-netfleet-firmware');
})().catch(error=>{console.error(error);process.exit(1)});
'''
        subprocess.run(['node', '-e', script, str(source)], check=True, capture_output=True, text=True)


class FeedReadbackTests(unittest.TestCase):
    def test_release_metadata_cannot_advertise_a_different_package_version(self):
        from tests.test_release_tools import write_release
        verifier = _load_module('firmware_release_verifier', 'scripts/verify-netfleet-release.py')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_release(root, 'a' * 40, 'b' * 40)
            path = root / 'manifest.json'
            manifest = json.loads(path.read_text())
            for item in manifest['artifacts']:
                item.update(version='0.4.5', release='1')
            value = {'version': 2, 'architecture': 'aarch64_generic',
                     'packages': {item['package']: '0.4.5-r1' for item in manifest['artifacts']}}

            def save():
                (root / 'index.json').write_text(json.dumps(value))
                manifest['feed_metadata'] = {'name': 'index.json', 'sha256': hashlib.sha256((root / 'index.json').read_bytes()).hexdigest()}
                path.write_text(json.dumps(manifest))

            save()
            self.assertTrue(verifier.verify(root, 'a' * 40, 'b' * 40)['ok'])
            value['packages']['opl-netfleet'] = '99.0.0'
            save()
            with self.assertRaisesRegex(ValueError, 'ASU feed metadata differs'):
                verifier.verify(root, 'a' * 40, 'b' * 40)

    def test_product_ui_pins_batch_backend_dependency_and_auto_update_is_async(self):
        makefile = (ROOT / 'openwrt/Makefile').read_text()
        template = makefile.split('define Package/opl-netfleet-plugin-$(1)\n', 1)[1].split('\nendef', 1)[0]
        fixture = f'''comma:=,
define plugin
{template}
endef
$(eval $(call plugin,product-ui))
all:
\t@printf '%s\\n' '$(EXTRA_DEPENDS)'
'''
        dependencies = subprocess.check_output(['make', '-s', '-f', '-'], input=fixture, text=True)
        dependencies = [value.strip() for value in dependencies.split(',')]
        self.assertIn('opl-netfleet-plugin-components (>=0.8.17)', dependencies)
        self.assertIn('opl-netfleet-plugin-configuration (>=0.7.10)', dependencies)
        components_src = (ROOT / 'plugins/components/lib/control.uc').read_text()
        self.assertIn('batch_plugin_update: true', components_src)
        auto_start = components_src.index('auto_update = function(trigger)')
        auto_end = components_src.index('command = function(argv)', auto_start)
        auto_body = components_src[auto_start:auto_end]
        self.assertIn('start("check")', auto_body)
        self.assertNotIn('apk --timeout 90 update', auto_body)


if __name__ == '__main__':
    unittest.main()
