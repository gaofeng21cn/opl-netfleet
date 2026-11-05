"""Behavior at the native ASU discovery and LuCI delegation boundaries."""
import importlib.util
import json
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('feed_metadata', ROOT / 'scripts/openwrt-feed-metadata.py')
feed = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(feed)


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


if __name__ == '__main__':
    unittest.main()

class FeedReadbackTests(unittest.TestCase):
    def test_release_metadata_cannot_advertise_a_different_package_version(self):
        import hashlib
        import tempfile
        from tests.test_release_tools import write_release
        spec = importlib.util.spec_from_file_location('firmware_release_verifier', ROOT / 'scripts/verify-netfleet-release.py')
        verifier = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(verifier)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_release(root, 'a'*40, 'b'*40)
            path = root/'manifest.json'
            manifest = json.loads(path.read_text())
            for item in manifest['artifacts']:
                item.update(version='0.4.5', release='1')
            value = {'version':2, 'architecture':'aarch64_generic',
                     'packages':{item['package']:'0.4.5-r1' for item in manifest['artifacts']}}
            def save():
                (root/'index.json').write_text(json.dumps(value))
                manifest['feed_metadata']={'name':'index.json','sha256':hashlib.sha256((root/'index.json').read_bytes()).hexdigest()}
                path.write_text(json.dumps(manifest))
            save()
            self.assertTrue(verifier.verify(root,'a'*40,'b'*40)['ok'])
            value['packages']['opl-netfleet']='99.0.0'
            save()
            with self.assertRaisesRegex(ValueError,'ASU feed metadata differs'):
                verifier.verify(root,'a'*40,'b'*40)
