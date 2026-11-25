import test from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import zlib from 'node:zlib';
import { projectProfile } from '../runtime/core.mjs';
import { coreSettingRows } from '../runtime/settings.mjs';
import { expandPanelArchive, installPanel, materializePanel, readPanelArchive } from '../runtime/dashboard.mjs';
import { OVERLAY_SCHEMA, applySignedPluginOverlays, canonicalOverlayPayload } from '../runtime/plugin-overlay.mjs';
import { atomicJSON, componentState, privateDir, run } from '../runtime/io.mjs';

const execFileAsync = promisify(execFile);

const state = { ports: { mixed: 19080, controller: 19090, dns: 19053 }, controllerSecret: 'local-owner-secret', network: { mode: 'explicit' } };

test('imported listeners cannot expose the desktop owner or enable network takeover', () => {
  const input = { proxies: [], rules: ['MATCH,DIRECT'], 'allow-lan': true, 'mixed-port': 80,
    'external-controller': '0.0.0.0:9090', 'external-controller-unix': '/tmp/foreign.sock',
    'external-controller-tls': ':9443', secret: 'imported', listeners: [{ name: 'public', port: 8080 }],
    'tproxy-port': 7893, 'redir-port': 7892, tun: { enable: true }, dns: { listen: ':53' } };
  const original = structuredClone(input);
  const result = projectProfile(input, state, '/tmp/netfleet-state/backend/run');
  assert.equal(result['allow-lan'], false);
  assert.equal(result['bind-address'], '127.0.0.1');
  assert.equal(result['external-controller'], '127.0.0.1:19090');
  assert.equal(result.secret, state.controllerSecret);
  assert.equal(result.tun.enable, false);
  assert.equal(result.dns.listen, '127.0.0.1:19053');
  for (const field of ['listeners', 'external-controller-unix', 'external-controller-tls', 'tproxy-port', 'redir-port']) assert.equal(result[field], undefined);
  assert.deepEqual(input, original);
});

test('file providers cannot read outside the private backend, including sibling-prefix paths', () => {
  for (const location of ['/etc/passwd', '../../state.json', '/tmp/netfleet-state/backend-other/data.yaml']) {
    assert.throws(() => projectProfile({ 'proxy-providers': { sample: { type: 'file', path: location } } }, state,
      '/tmp/netfleet-state/backend/run'), /provider_path_outside_private_backend/);
  }
  const result = projectProfile({ 'proxy-providers': { sample: { type: 'file', path: '../subscriptions/airport.yaml' } } }, state,
    '/tmp/netfleet-state/backend/run');
  assert.equal(result['proxy-providers'].sample.path, '/tmp/netfleet-state/backend/subscriptions/airport.yaml');
});

test('remote provider cache names cannot traverse outside the runtime', () => {
  const result = projectProfile({ 'proxy-providers': { '../../foreign': { type: 'http', path: '/etc/foreign', url: 'https://example.invalid/subscription' } } }, state,
    '/tmp/netfleet-state/backend/run');
  assert.ok(result['proxy-providers']['../../foreign'].path.startsWith('/tmp/netfleet-state/backend/run/proxy-providers/'));
});

test('atomic writes replace a destination symlink without following it; state roots reject symlinks', async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'netfleet-io-test-'));
  try {
    const external = path.join(root, 'preserved.json'), link = path.join(root, 'state.json');
    await fs.writeFile(external, 'preserved'); await fs.symlink(external, link);
    await atomicJSON(link, { secret: 'private' });
    assert.equal(await fs.readFile(external, 'utf8'), 'preserved');
    assert.equal((await fs.stat(link)).mode & 0o777, 0o600);
    assert.deepEqual(JSON.parse(await fs.readFile(link, 'utf8')), { secret: 'private' });
    await fs.mkdir(path.join(root, 'real')); await fs.symlink(path.join(root, 'real'), path.join(root, 'alias'));
    await assert.rejects(privateDir(path.join(root, 'alias')), /unsafe_state_directory/);
  } finally { await fs.rm(root, { recursive: true, force: true }); }
});

test('command output preserves UTF-8 when a multibyte node name crosses pipe chunks', async () => {
  const result = await run(process.execPath, ['-e', 'const b=Buffer.from("香港节点");process.stdout.write(b.subarray(0,2));setTimeout(()=>process.stdout.write(b.subarray(2)),40);']);
  assert.equal(result.code, 0);
  assert.equal(result.stdout, '香港节点');
});

test('core settings project the applied platform values, not a second copy of the mapping', () => {
  const profile = { 'log-level': 'info', dns: { nameserver: ['1.1.1.1'] } };
  const projected = projectProfile(profile, state, '/tmp/netfleet-state/backend/run', 'tun');
  const running = { 'log-level': 'warning', 'mixed-port': 19080, ipv6: false, tun: { device: 'utun198', stack: 'gvisor' } };
  const overlay = { 'dns-enable': true, 'dns-listen-removed': true, tun: { device: 'utun198', stack: 'gvisor', 'auto-route': true, 'dns-hijack': ['any:53'] },
    injected: ['sniffer'], sniffer: { enable: true, sniff: { TLS: { ports: [443] } } } };
  const rows = coreSettingRows({ profile, projected, running, overlay });
  const row = id => rows.find(item => item.id === id);
  // 平台强制值来自真实投影结果：DNS 接管、监听地址、日志级别都是平台接管。
  assert.equal(row('dns.enable').source, 'platform');
  assert.equal(row('dns.enable').configured, '开启');
  assert.equal(row('dns.listen').source, 'platform');
  assert.equal(row('log-level').source, 'platform');
  assert.equal(row('log-level').declared, 'info');
  assert.equal(row('log-level').configured, 'warning');
  assert.equal(row('log-level').running, 'warning');
  // Profile 自己声明的值不因为存在平台值就被改写来源。
  assert.equal(row('dns.nameserver').source, 'profile');
  assert.equal(row('dns.nameserver').configured, '1.1.1.1');
  // TUN 会话只在特权组件报告本次覆写时出现，并且使用会话实际写入的值。
  assert.equal(row('tun.device').configured, 'utun198');
  assert.equal(row('sniffer.sniff').source, 'platform');
  assert.equal(coreSettingRows({ profile, projected }).some(item => item.group === 'TUN 会话'), false);
  // 投影里没有密钥字段，页面拿不到 controller secret。
  assert.equal(JSON.stringify(rows).includes('local-owner-secret'), false);
});

// Build minimal valid ZIP fixtures with real CRC-32 and Unix mode attributes
// so system unzip/ditto validation and extraction paths are exercised end-to-end.
function buildZip(files, { mode = 0o100644, name, flags = 0, compress = false, badCrc = false } = {}) {
  const chunks = [], central = [];
  let offset = 0;
  for (const file of files) {
    const entry = Buffer.from(name ?? file.name);
    const raw = Buffer.from(file.data ?? '');
    const payload = compress ? zlib.deflateRawSync(raw) : raw;
    const method = compress ? 8 : 0;
    const crc = badCrc ? ((zlib.crc32(raw) ^ 0xffffffff) >>> 0) : (zlib.crc32(raw) >>> 0);
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0); local.writeUInt16LE(20, 4); local.writeUInt16LE(flags, 6);
    local.writeUInt16LE(method, 8); local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(payload.length, 18); local.writeUInt32LE(raw.length, 22);
    local.writeUInt16LE(entry.length, 26); local.writeUInt16LE(0, 28);
    chunks.push(local, entry, payload);
    const row = Buffer.alloc(46);
    row.writeUInt32LE(0x02014b50, 0); row.writeUInt16LE((3 << 8) | 20, 4); row.writeUInt16LE(20, 6);
    row.writeUInt16LE(flags, 8); row.writeUInt16LE(method, 10); row.writeUInt32LE(crc, 16);
    row.writeUInt32LE(payload.length, 20); row.writeUInt32LE(raw.length, 24);
    row.writeUInt16LE(entry.length, 28); row.writeUInt32LE((mode << 16) >>> 0, 38);
    row.writeUInt32LE(offset, 42);
    central.push(Buffer.concat([row, entry]));
    offset += local.length + entry.length + payload.length;
  }
  const directory = Buffer.concat(central);
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0); eocd.writeUInt16LE(files.length, 8); eocd.writeUInt16LE(files.length, 10);
  eocd.writeUInt32LE(directory.length, 12); eocd.writeUInt32LE(offset, 16);
  return Buffer.concat([...chunks, directory, eocd]);
}

test('a panel archive is expanded only when every entry is a plain dist path', async () => {
  const good = buildZip([{ name: 'dist/index.html', data: '<div id="app"></div>' }, { name: 'dist/assets/app.js', data: 'x' }], { compress: true });
  const rows = await expandPanelArchive(good);
  assert.deepEqual(rows.map(row => row.relative).sort(), ['assets/app.js', 'index.html']);
  assert.equal((await readPanelArchive(good)).length, 2);
  // Traversal, absolute paths, links, encryption, corrupted CRC, non-ZIP data,
  // and missing index.html all fail before anything is written.
  for (const bad of [
    buildZip([{ name: 'dist/index.html', data: 'x' }], { name: 'dist/../../escape.js' }),
    buildZip([{ name: 'dist/index.html', data: 'x' }], { name: '/etc/passwd' }),
    buildZip([{ name: 'dist/index.html', data: 'x' }], { mode: 0o120777 }),
    buildZip([{ name: 'dist/index.html', data: 'x' }], { flags: 0x1 }),
    buildZip([{ name: 'dist/index.html', data: 'x' }], { badCrc: true }),
    buildZip([{ name: 'dist/assets/app.js', data: 'x' }]),
    Buffer.from('not-a-zip-archive'),
  ]) await assert.rejects(() => expandPanelArchive(bad), /dashboard_archive_invalid/);
});

test('installing a panel replaces files in place and removes stale ones', async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'netfleet-panel-test-'));
  try {
    const first = await expandPanelArchive(buildZip([{ name: 'dist/index.html', data: 'one' }, { name: 'dist/legacy.js', data: 'old' }]));
    await installPanel(first, path.join(root, 'panel'));
    assert.equal(await fs.readFile(path.join(root, 'panel/index.html'), 'utf8'), 'one');
    const second = await expandPanelArchive(buildZip([{ name: 'dist/index.html', data: 'two' }]));
    await installPanel(second, path.join(root, 'panel'));
    assert.equal(await fs.readFile(path.join(root, 'panel/index.html'), 'utf8'), 'two');
    assert.equal(await fs.readFile(path.join(root, 'panel/legacy.js'), 'utf8').catch(() => null), null);
    // Seeding from a directory uses the same verified path and skips its manifest.
    await materializePanel(path.join(root, 'panel'), path.join(root, 'served'));
    assert.equal(await fs.readFile(path.join(root, 'served/index.html'), 'utf8'), 'two');
    assert.ok(JSON.parse(await fs.readFile(path.join(root, 'served/.panel.json'), 'utf8')).files['index.html']);
  } finally { await fs.rm(root, { recursive: true, force: true }); }
});

test('the imported profile cannot choose the panel directory', () => {
  const imported = { proxies: [], rules: ['MATCH,DIRECT'], 'external-ui': '/Users/someone/panel',
    'external-ui-url': 'https://example.invalid/panel.zip', 'external-ui-name': 'foreign' };
  // Without pinned assets the core is left without a panel directory at all.
  const bare = projectProfile(imported, state, '/tmp/netfleet-state/backend/run');
  assert.equal(bare['external-ui'], undefined);
  assert.equal(bare['external-ui-url'], undefined);
  // With pinned assets the platform owns the path, the name and the download.
  const pinned = projectProfile(imported, state, '/tmp/netfleet-state/backend/run', 'explicit', '/Applications/OPL NetFleet.app/Contents/Resources/dashboard');
  assert.equal(pinned['external-ui'], '/Applications/OPL NetFleet.app/Contents/Resources/dashboard');
  assert.equal(pinned['external-ui-name'], undefined);
  assert.equal(pinned['external-ui-url'], undefined);
});

test('network components report their sync state against the bundled bytes', async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'netfleet-component-test-'));
  try {
    await fs.writeFile(path.join(root, 'bundled'), 'same');
    assert.deepEqual((await componentState(path.join(root, 'bundled'), path.join(root, 'missing'))).state, 'missing');
    await fs.writeFile(path.join(root, 'installed'), 'same');
    assert.equal((await componentState(path.join(root, 'bundled'), path.join(root, 'installed'))).state, 'match');
    await fs.writeFile(path.join(root, 'installed'), 'older');
    assert.equal((await componentState(path.join(root, 'bundled'), path.join(root, 'installed'))).state, 'outdated');
    assert.equal((await componentState(path.join(root, 'absent'), path.join(root, 'installed'))).state, 'unbundled');
  } finally { await fs.rm(root, { recursive: true, force: true }); }
});

test('signed plugin overlay verifies Ed25519 signature, replaces bundled plugin atomically, and rejects tampered or disallowed overlays fail-closed', async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'netfleet-overlay-test-'));
  const ED25519_PKCS8_PREFIX_LEN = 16;
  const ED25519_SPKI_PREFIX_LEN = 12;
  const sha = value => crypto.createHash('sha256').update(value).digest('hex');

  function makeEd25519Pair() {
    const pair = crypto.generateKeyPairSync('ed25519');
    const spki = pair.publicKey.export({ format: 'der', type: 'spki' });
    const pkcs8 = pair.privateKey.export({ format: 'der', type: 'pkcs8' });
    return {
      privateKey: pair.privateKey,
      privateSeedB64: pkcs8.subarray(ED25519_PKCS8_PREFIX_LEN).toString('base64'),
      publicKeyB64: spki.subarray(ED25519_SPKI_PREFIX_LEN).toString('base64'),
    };
  }

  async function seedBundled(codeRoot, id = 'events', version = '0.7.0') {
    const pluginDir = path.join(codeRoot, 'plugins', id);
    await fs.mkdir(path.join(pluginDir, 'lib'), { recursive: true, mode: 0o700 });
    await fs.writeFile(path.join(pluginDir, 'manifest.json'), JSON.stringify({
      schema: 'opl-netfleet-service-plugin.v1', id, version, api_version: 1,
    }));
    await fs.writeFile(path.join(pluginDir, 'lib/control.uc'), 'bundled-impl');
  }

  async function writeOverlay(overlayRoot, id, files, signerKey, { version = '0.7.1', envelopePatch = {} } = {}) {
    const dir = path.join(overlayRoot, id);
    await fs.rm(dir, { recursive: true, force: true });
    await fs.mkdir(dir, { recursive: true, mode: 0o700 });
    const entries = [];
    for (const [rel, body] of Object.entries(files).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))) {
      const dest = path.join(dir, rel);
      await fs.mkdir(path.dirname(dest), { recursive: true, mode: 0o700 });
      await fs.writeFile(dest, body, { mode: 0o600 });
      entries.push({ path: rel, sha256: sha(body) });
    }
    const baseEnvelope = {
      schema: OVERLAY_SCHEMA,
      id,
      version,
      files: entries,
    };
    const merged = { ...baseEnvelope, ...envelopePatch };
    const signature = crypto.sign(null, Buffer.from(canonicalOverlayPayload(merged), 'utf8'), signerKey).toString('base64');
    await fs.writeFile(path.join(dir, 'overlay-signature.json'), JSON.stringify({ ...merged, signature }, null, 2), { mode: 0o600 });
    return dir;
  }

  try {
    const keys = makeEd25519Pair();
    const otherKeys = makeEd25519Pair();

    // 1. Valid signed newer overlay via applySignedPluginOverlays
    const codeRoot = path.join(root, 'case1-code');
    const overlayRoot = path.join(root, 'case1-overlay');
    await fs.mkdir(overlayRoot, { mode: 0o700 });
    await seedBundled(codeRoot, 'events', '0.7.0');
    await writeOverlay(overlayRoot, 'events', {
      'lib/control.uc': 'overlay-impl-v2',
      'manifest.json': JSON.stringify({ schema: 'opl-netfleet-service-plugin.v1', id: 'events', version: '0.7.1', api_version: 1 }),
    }, keys.privateKey, { version: '0.7.1' });
    const okResult = await applySignedPluginOverlays({ overlayRoot, codeRoot, publicKeyBase64: keys.publicKeyB64 });
    assert.deepEqual(okResult, { applied: [{ id: 'events', version: '0.7.1', bundled_version: '0.7.0' }], rejected: [] });
    assert.equal(await fs.readFile(path.join(codeRoot, 'plugins/events/lib/control.uc'), 'utf8'), 'overlay-impl-v2');

    // 2. Negative cases must fail closed and leave bundled plugin untouched
    const negCases = [
      {
        name: 'tampered file bytes',
        reason: 'file_digest_mismatch',
        setup: async (cRoot, oRoot) => {
          const dir = await writeOverlay(oRoot, 'events', {
            'lib/control.uc': 'overlay-impl-v2',
            'manifest.json': JSON.stringify({ schema: 'opl-netfleet-service-plugin.v1', id: 'events', version: '0.7.1', api_version: 1 }),
          }, keys.privateKey);
          await fs.writeFile(path.join(dir, 'lib/control.uc'), 'tampered-bytes', { mode: 0o600 });
        },
      },
      {
        name: 'bad signature',
        reason: 'signature_verification_failed',
        setup: async (cRoot, oRoot) => {
          const dir = await writeOverlay(oRoot, 'events', {
            'manifest.json': JSON.stringify({ schema: 'opl-netfleet-service-plugin.v1', id: 'events', version: '0.7.1', api_version: 1 }),
          }, keys.privateKey);
          const env = JSON.parse(await fs.readFile(path.join(dir, 'overlay-signature.json'), 'utf8'));
          env.signature = Buffer.alloc(64, 7).toString('base64');
          await fs.writeFile(path.join(dir, 'overlay-signature.json'), JSON.stringify(env), { mode: 0o600 });
        },
      },
      {
        name: 'wrong public key',
        reason: 'signature_verification_failed',
        setup: async (cRoot, oRoot) => {
          await writeOverlay(oRoot, 'events', {
            'manifest.json': JSON.stringify({ schema: 'opl-netfleet-service-plugin.v1', id: 'events', version: '0.7.1', api_version: 1 }),
          }, otherKeys.privateKey);
        },
      },
      {
        name: 'unlisted extra file',
        reason: 'unlisted_overlay_file',
        setup: async (cRoot, oRoot) => {
          const dir = await writeOverlay(oRoot, 'events', {
            'manifest.json': JSON.stringify({ schema: 'opl-netfleet-service-plugin.v1', id: 'events', version: '0.7.1', api_version: 1 }),
          }, keys.privateKey);
          await fs.mkdir(path.join(dir, 'lib'), { recursive: true, mode: 0o700 });
          await fs.writeFile(path.join(dir, 'lib/extra.uc'), 'sneaky', { mode: 0o600 });
        },
      },
      {
        name: 'symlink inside overlay',
        reason: 'symlink_disallowed',
        setup: async (cRoot, oRoot) => {
          const dir = await writeOverlay(oRoot, 'events', {
            'manifest.json': JSON.stringify({ schema: 'opl-netfleet-service-plugin.v1', id: 'events', version: '0.7.1', api_version: 1 }),
          }, keys.privateKey);
          await fs.symlink('/etc/hosts', path.join(dir, 'lib-link'));
        },
      },
      {
        name: 'path traversal in envelope',
        reason: 'invalid_signature_envelope',
        setup: async (cRoot, oRoot) => {
          await writeOverlay(oRoot, 'events', {
            'manifest.json': JSON.stringify({ schema: 'opl-netfleet-service-plugin.v1', id: 'events', version: '0.7.1', api_version: 1 }),
          }, keys.privateKey, { envelopePatch: { files: [{ path: '../escape.uc', sha256: sha('x') }] } });
        },
      },
      {
        name: 'unknown plugin id',
        id: 'unknown-plugin',
        reason: 'unknown_plugin_id',
        setup: async (cRoot, oRoot) => {
          await writeOverlay(oRoot, 'unknown-plugin', {
            'manifest.json': JSON.stringify({ schema: 'opl-netfleet-service-plugin.v1', id: 'unknown-plugin', version: '0.7.1', api_version: 1 }),
          }, keys.privateKey);
        },
      },
      {
        name: 'platform-macos disallowed',
        id: 'platform-macos',
        reason: 'platform_plugin_disallowed',
        setup: async (cRoot, oRoot) => {
          await seedBundled(cRoot, 'platform-macos', '0.7.0');
          await writeOverlay(oRoot, 'platform-macos', {
            'manifest.json': JSON.stringify({ schema: 'opl-netfleet-service-plugin.v1', id: 'platform-macos', version: '0.7.1', api_version: 1 }),
          }, keys.privateKey);
        },
      },
      {
        name: 'downgrade or equal version rejected',
        reason: 'downgrade_rejected',
        setup: async (cRoot, oRoot) => {
          await writeOverlay(oRoot, 'events', {
            'lib/control.uc': 'downgrade',
            'manifest.json': JSON.stringify({ schema: 'opl-netfleet-service-plugin.v1', id: 'events', version: '0.7.0', api_version: 1 }),
          }, keys.privateKey, { version: '0.7.0' });
        },
      },
    ];

    for (let i = 0; i < negCases.length; i++) {
      const testCase = negCases[i];
      const cRoot = path.join(root, `neg-code-${i}`);
      const oRoot = path.join(root, `neg-overlay-${i}`);
      await fs.mkdir(oRoot, { mode: 0o700 });
      await seedBundled(cRoot, 'events', '0.7.0');
      await testCase.setup(cRoot, oRoot);
      const outcome = await applySignedPluginOverlays({ overlayRoot: oRoot, codeRoot: cRoot, publicKeyBase64: keys.publicKeyB64 });
      assert.deepEqual(outcome.applied, [], `${testCase.name}: must not apply`);
      assert.deepEqual(outcome.rejected, [{ id: testCase.id ?? 'events', reason: testCase.reason }], testCase.name);
      assert.equal(await fs.readFile(path.join(cRoot, 'plugins/events/lib/control.uc'), 'utf8'), 'bundled-impl', testCase.name);
    }

    // 3. End-to-end test with scripts/macos/sign-plugin-overlay.py
    const pyCode = path.join(root, 'py-code');
    const pyOverlay = path.join(root, 'py-overlay');
    const pySrc = path.join(root, 'py-src');
    await seedBundled(pyCode, 'events', '0.7.0');
    await fs.mkdir(path.join(pySrc, 'lib'), { recursive: true });
    await fs.writeFile(path.join(pySrc, 'manifest.json'), JSON.stringify({
      schema: 'opl-netfleet-service-plugin.v1', id: 'events', version: '0.7.2', api_version: 1,
    }));
    await fs.writeFile(path.join(pySrc, 'lib/control.uc'), 'signed-by-python-cli');
    await execFileAsync('python3', [
      path.resolve('scripts/macos/sign-plugin-overlay.py'),
      '--plugin-dir', pySrc,
      '--output-dir', path.join(pyOverlay, 'events'),
    ], { env: { ...process.env, SPARKLE_ED25519_PRIVATE_KEY: keys.privateSeedB64 } });
    const pyResult = await applySignedPluginOverlays({ overlayRoot: pyOverlay, codeRoot: pyCode, publicKeyBase64: keys.publicKeyB64 });
    assert.deepEqual(pyResult, { applied: [{ id: 'events', version: '0.7.2', bundled_version: '0.7.0' }], rejected: [] });
    assert.equal(await fs.readFile(path.join(pyCode, 'plugins/events/lib/control.uc'), 'utf8'), 'signed-by-python-cli');
  } finally { await fs.rm(root, { recursive: true, force: true }); }
});
