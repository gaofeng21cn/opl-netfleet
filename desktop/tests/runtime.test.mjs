import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { projectProfile } from '../runtime/core.mjs';
import { coreSettingRows } from '../runtime/settings.mjs';
import { expandPanelArchive, installPanel, materializePanel, readPanelArchive } from '../runtime/dashboard.mjs';
import { componentState, latestRelease, newerVersion, parseVersion, releaseCandidate } from '../runtime/update.mjs';
import { atomicJSON, privateDir, run } from '../runtime/io.mjs';

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

// A stored-entry ZIP keeps the fixture readable: the reader must validate the
// directory, not trust the archive's own metadata.
function storedZip(files, { mode = 0o100644, name } = {}) {
  const chunks = [], central = [];
  let offset = 0;
  for (const file of files) {
    const entry = Buffer.from(name ?? file.name);
    const data = Buffer.from(file.data ?? '');
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0); local.writeUInt16LE(20, 4); local.writeUInt16LE(0, 6);
    local.writeUInt32LE(0, 14); local.writeUInt32LE(data.length, 18); local.writeUInt32LE(data.length, 22);
    local.writeUInt16LE(entry.length, 26); local.writeUInt16LE(0, 28);
    chunks.push(local, entry, data);
    const row = Buffer.alloc(46);
    row.writeUInt32LE(0x02014b50, 0); row.writeUInt16LE(20, 4); row.writeUInt16LE(0, 6); row.writeUInt16LE(0, 8);
    row.writeUInt16LE(0, 10); row.writeUInt32LE(0, 16); row.writeUInt32LE(data.length, 20);
    row.writeUInt32LE(data.length, 24); row.writeUInt16LE(entry.length, 28);
    row.writeUInt32LE((mode << 16) >>> 0, 38); row.writeUInt32LE(offset, 42);
    central.push(Buffer.concat([row, entry]));
    offset += local.length + entry.length + data.length;
  }
  const directory = Buffer.concat(central);
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0); eocd.writeUInt16LE(files.length, 8); eocd.writeUInt16LE(files.length, 10);
  eocd.writeUInt32LE(directory.length, 12); eocd.writeUInt32LE(offset, 16);
  return Buffer.concat([...chunks, directory, eocd]);
}

test('a panel archive is expanded only when every entry is a plain dist path', () => {
  const good = storedZip([{ name: 'dist/index.html', data: '<div id="app"></div>' }, { name: 'dist/assets/app.js', data: 'x' }]);
  const rows = expandPanelArchive(good);
  assert.deepEqual(rows.map(row => row.relative).sort(), ['assets/app.js', 'index.html']);
  assert.equal(readPanelArchive(good).length, 2);
  // Traversal, absolute paths, links, unknown compression and a missing entry
  // point all fail before anything is written.
  for (const bad of [
    storedZip([{ name: 'dist/index.html', data: 'x' }], { name: 'dist/../../escape.js' }),
    storedZip([{ name: 'dist/index.html', data: 'x' }], { name: '/etc/passwd' }),
    storedZip([{ name: 'dist/index.html', data: 'x' }], { mode: 0o120777 }),
    storedZip([{ name: 'dist/assets/app.js', data: 'x' }]),
  ]) assert.throws(() => expandPanelArchive(bad), /dashboard_archive_invalid/);
});

test('installing a panel replaces files in place and removes stale ones', async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'netfleet-panel-test-'));
  try {
    const first = expandPanelArchive(storedZip([{ name: 'dist/index.html', data: 'one' }, { name: 'dist/legacy.js', data: 'old' }]));
    await installPanel(first, path.join(root, 'panel'));
    assert.equal(await fs.readFile(path.join(root, 'panel/index.html'), 'utf8'), 'one');
    const second = expandPanelArchive(storedZip([{ name: 'dist/index.html', data: 'two' }]));
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

test('a macOS release is installable only with a DMG and its published digest', () => {
  const asset = (name, digest, size = 1024) => ({ name, digest, size, browser_download_url: `https://github.com/gaofeng21cn/opl-netfleet/releases/download/macos-v0.1.7/${name}` });
  const release = (tag, assets) => ({ tag_name: tag, draft: false, prerelease: false, html_url: `https://github.com/gaofeng21cn/opl-netfleet/releases/tag/${tag}`, assets });
  const dmg = 'OPL-NetFleet-0.1.7-macos-arm64.dmg';
  const good = release('macos-v0.1.7', [asset(dmg, `sha256:${'a'.repeat(64)}`), asset('SHA256SUMS', 'sha256:' + 'b'.repeat(64))]);
  // 只有带 DMG 与 GitHub 摘要的正式 Release 才能作为候选。
  assert.deepEqual(releaseCandidate(good), { version: '0.1.7', tag: 'macos-v0.1.7', url: asset(dmg, '').browser_download_url, name: dmg,
    size_bytes: 1024, sha256: 'a'.repeat(64), page: good.html_url, published_at: null });
  for (const broken of [
    release('macos-v0.1.7', [asset('OPL-NetFleet-0.1.7-macos-arm64.zip', `sha256:${'a'.repeat(64)}`)]),
    release('macos-v0.1.7', [{ ...asset(dmg, ''), digest: undefined }]),
    release('macos-v0.1.7', [{ ...asset(dmg, `sha256:${'a'.repeat(64)}`), size: 0 }]),
    { ...good, prerelease: true },
    { ...good, draft: true },
  ]) assert.equal(releaseCandidate(broken), null);
  // 选版本最高的正式 Release，忽略草稿、预发布与 OpenWrt tag。
  assert.equal(latestRelease([
    { tag_name: 'v0.9.0', draft: false, prerelease: false },
    { tag_name: 'macos-v0.1.7', draft: false, prerelease: false },
    { tag_name: 'macos-v0.2.0', draft: true, prerelease: false },
    { tag_name: 'macos-v0.1.10', draft: false, prerelease: true },
    { tag_name: 'macos-v0.1.8', draft: false, prerelease: false, assets: [] },
  ]).tag_name, 'macos-v0.1.8');
  assert.equal(latestRelease([]), null);
});

test('version comparison only accepts a strictly newer release', () => {
  assert.deepEqual(parseVersion('v0.1.7'), [0, 1, 7]);
  assert.equal(newerVersion('0.1.7', '0.1.6'), true);
  assert.equal(newerVersion('0.2.0', '0.10.0'), false);
  assert.equal(newerVersion('0.1.6', '0.1.6'), false);
  assert.equal(newerVersion('0.1.6', null), true);
  assert.equal(newerVersion('latest', '0.1.6'), false);
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

test('the update installer refuses unsigned or still-running replacements and restores the old app', async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'netfleet-install-test-'));
  const script = new URL('../runtime/update-install.sh', import.meta.url).pathname;
  const prepare = async () => {
    const work = await fs.mkdtemp(path.join(root, 'case-'));
    const target = path.join(work, 'OPL NetFleet.app'), previous = path.join(work, '.previous.app');
    const staged = path.join(work, 'staged.app'), receipt = path.join(work, 'receipt.json');
    await fs.mkdir(target, { recursive: true }); await fs.writeFile(path.join(target, 'old'), 'old');
    await fs.mkdir(staged, { recursive: true }); await fs.writeFile(path.join(staged, 'new'), 'new');
    return { work, target, previous, staged, receipt };
  };
  try {
    // 未签名的新包：脚本必须拒绝、留下失败回执并恢复旧应用。
    const unsigned = await prepare();
    const refused = await run('/bin/sh', [script, '999999', unsigned.staged, unsigned.target, unsigned.previous, unsigned.receipt, 'SVVC4TA784'], { timeout: 60000 });
    assert.notEqual(refused.code, 0);
    assert.equal(JSON.parse(await fs.readFile(unsigned.receipt, 'utf8')).state, 'failed');
    assert.equal(await fs.readFile(path.join(unsigned.target, 'old'), 'utf8'), 'old');
    assert.equal(await fs.readdir(unsigned.work).then(rows => rows.includes('staged.app')), true);
    // 应用仍在运行：即使暂存包合法也绝不替换，旧应用内容保持不变。
    const running = await prepare();
    const blocked = await run('/bin/sh', [script, String(process.pid), running.staged, running.target, running.previous, running.receipt, 'SVVC4TA784'],
      { timeout: 60000, env: { ...process.env, NETFLEET_UPDATE_WAIT_SECONDS: '1' } });
    assert.notEqual(blocked.code, 0);
    assert.match(JSON.parse(await fs.readFile(running.receipt, 'utf8')).detail, /应用未在等待时间内退出/);
    assert.equal(await fs.readFile(path.join(running.target, 'old'), 'utf8'), 'old');
  } finally { await fs.rm(root, { recursive: true, force: true }); }
});
