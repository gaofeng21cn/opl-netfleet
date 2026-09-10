import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { projectProfile } from '../runtime/core.mjs';
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
