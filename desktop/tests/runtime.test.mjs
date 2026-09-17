import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { projectProfile } from '../runtime/core.mjs';
import { coreSettingRows } from '../runtime/settings.mjs';
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
