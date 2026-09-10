import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import http from 'node:http';
import net from 'node:net';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { run } from '../runtime/io.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const stateDir = await fs.mkdtemp(path.join(os.tmpdir(), 'netfleet-macos-qualify-'));
const nodeList = `proxies:
  - name: "香港 01"
    type: http
    server: 127.0.0.1
    port: 18080
  - name: "日本 02"
    type: http
    server: 127.0.0.1
    port: 18080
  - name: "新加坡 03"
    type: http
    server: 127.0.0.1
    port: 18080
`;
const relay = http.createServer((request, response) => {
  if (request.method === 'GET' && request.url === '/subscription') {
    return response.writeHead(200, { 'Content-Type': 'text/yaml' }).end(nodeList);
  }
  response.writeHead(405).end();
});
let connections = 0, processHandle, base, token, stopped = false, subscriptionHandle, subscriptionStateDir;
const sockets = new Set();
relay.on('connection', socket => { sockets.add(socket); socket.on('close', () => sockets.delete(socket)); });
relay.on('connect', (request, client, head) => {
  const [host, raw] = request.url.split(':');
  // A real local proxy forwards only the explicit test destination.
  if (host !== 'www.gstatic.com' || raw !== '443') return client.end('HTTP/1.1 403 Forbidden\r\n\r\n');
  connections++;
  const upstream = net.connect(443, host, () => { client.write('HTTP/1.1 200 Connection Established\r\n\r\n'); if (head.length) upstream.write(head); upstream.pipe(client); client.pipe(upstream); });
  upstream.on('error', () => client.destroy()); client.on('error', () => upstream.destroy()); client.on('close', () => upstream.destroy());
});
await new Promise(resolve => relay.listen(0, '127.0.0.1', resolve));
async function api(action, input = {}) {
  const response = await fetch(`${base}/api/action`, { method: 'POST', headers: { Authorization: `Bearer ${token}`, Origin: base, 'Content-Type': 'application/json' },
    body: JSON.stringify({ action, ...input }), signal: AbortSignal.timeout(300000) });
  return response.json();
}
async function state() { return (await (await fetch(`${base}/api/state`, { headers: { Authorization: `Bearer ${token}` } })).json()).result; }
// Each qualification instance owns its own state directory and loopback endpoint.
async function boot(dir) {
  const handle = spawn(process.execPath, [path.join(root, 'desktop/runtime/server.mjs'), '--state', dir], { env: process.env, stdio: ['ignore', 'pipe', 'pipe'] });
  const startup = await new Promise((resolve, reject) => {
    let output = '', error = ''; const timer = setTimeout(() => reject(new Error('startup timeout')), 45000);
    handle.stdout.on('data', data => { output += data; if (output.includes('\n')) { clearTimeout(timer); try { resolve(JSON.parse(output.split('\n')[0])); } catch (failure) { reject(failure); } } });
    handle.stderr.on('data', data => { error += data; });
    handle.on('exit', () => { clearTimeout(timer); reject(new Error(`server exited: ${error}`)); });
  });
  const url = new URL(startup.url); base = url.origin; token = url.searchParams.get('token');
  return handle;
}
const evidence = { platform: process.platform, networkMode: 'explicit', systemNetworkMutated: false, checks: [] };
try {
  processHandle = await boot(stateDir);
  assert.equal((await fetch(`${base}/api/state`)).status, 401); evidence.checks.push('unauthenticated_request_rejected');
  const initial = await state(); assert.equal(initial.runtime.running, false); assert.equal(initial.runtime.networkMode, 'explicit');
  assert.equal(initial.status, null); assert.equal(initial.events, null);
  assert.deepEqual((await api('connections')).result.connections, []);
  const duplicate = await run(process.execPath, [path.join(root, 'desktop/runtime/server.mjs'), '--state', stateDir], { env: process.env });
  assert.notEqual(duplicate.code, 0); evidence.checks.push('single_owner_enforced');
  const profile = { proxies: [{ name: '日本 qualification', type: 'http', server: '127.0.0.1', port: relay.address().port }],
    'proxy-groups': [{ name: 'Proxy', type: 'select', proxies: ['日本 qualification'] }], rules: ['MATCH,Proxy'] };
  assert.equal((await api('configure', { profile })).ok, true); evidence.checks.push('profile_import_core_validation');
  const invalid = await api('configure', { profile: { proxies: [{ name: 'broken', type: 'invalid-protocol' }] } });
  assert.equal(invalid.ok, false);
  assert.deepEqual(JSON.parse(await fs.readFile(path.join(stateDir, 'backend/profiles/Original.json'))), profile);
  evidence.checks.push('invalid_import_preserves_profile');
  const invalidPolicy = await api('configure', { profile: { ...profile, rules: ['MATCH,DIRECT'] }, policy: { invalid: true } });
  assert.equal(invalidPolicy.ok, false);
  assert.deepEqual(JSON.parse(await fs.readFile(path.join(stateDir, 'backend/profiles/Original.json'))), profile);
  evidence.checks.push('invalid_policy_import_preserves_all_sources');
  const compiled = await api('compile'); assert.equal(compiled.ok, true, JSON.stringify(compiled)); evidence.checks.push('shared_discovery_and_compiler');
  assert.equal((await state()).runtime.running, false); evidence.checks.push('compile_has_no_running_core');
  const enabled = await api('enable'); assert.equal(enabled.ok, true, JSON.stringify(enabled)); evidence.checks.push('shared_activation_and_selection');
  const active = await state(); assert.equal(active.runtime.running, true); assert.equal(active.runtime.mode, 'netfleet');
  for (const field of ['capabilities', 'providers', 'regions']) assert.ok(Array.isArray(active.status[field]), field);
  assert.ok(Array.isArray(active.events.events));
  const connectionRead = await api('connections');
  assert.equal(connectionRead.ok, true); assert.ok(Array.isArray(connectionRead.result.connections));
  evidence.checks.push('shared_react_status_and_connections_contract');
  const probe = await run('/usr/bin/curl', ['--noproxy', '', '--proxy', `http://127.0.0.1:${active.runtime.ports.mixed}`, '--max-time', '15', '-sS', '-o', '/dev/null', '-w', '%{http_code}', 'https://www.gstatic.com/generate_204']);
  assert.equal(probe.stdout, '204'); assert.ok(connections > 0); evidence.checks.push('real_mihomo_proxy_https_204');
  const selectable = active.status.capabilities.find(item => item.can_select_region && item.selectable_regions?.length);
  assert.ok(selectable, 'real selectable capability');
  const region = selectable.selectable_regions[0];
  const selected = await api('select-region', { capability: selectable.id, region });
  assert.equal(selected.ok, true, JSON.stringify(selected));
  assert.equal((await state()).status.capabilities.find(item => item.id === selectable.id).manual_region_id, region);
  const automatic = await api('select-auto', { capability: selectable.id }); assert.equal(automatic.ok, true, JSON.stringify(automatic));
  evidence.checks.push('manual_region_and_restore_automatic');
  const refreshed = await api('refresh'); assert.equal(refreshed.ok, true, JSON.stringify(refreshed)); evidence.checks.push('shared_refresh');
  const disabled = await api('disable'); assert.equal(disabled.ok, true, JSON.stringify(disabled));
  const native = await state(); assert.equal(native.runtime.running, true); assert.equal(native.runtime.mode, 'mihomo'); evidence.checks.push('recovery_profile_restored');
  assert.equal((await api('mode', { mode: 'direct' })).ok, true); assert.equal((await state()).runtime.running, false); evidence.checks.push('direct_stops_owned_core');
  const backup = await api('backup-export'); assert.equal(backup.ok, true);
  const restore = await api('backup-restore', { backup: backup.result }); assert.equal(restore.ok, true, JSON.stringify(restore)); evidence.checks.push('backup_roundtrip');
  assert.equal((await api('mode', { mode: 'mihomo' })).ok, true);
  const original = await state(); process.kill(original.runtime.pid, 'SIGKILL');
  await new Promise(resolve => setTimeout(resolve, 500));
  const crashed = await state(); assert.equal(crashed.runtime.running, false); assert.notEqual(crashed.runtime.mode, 'mihomo');
  assert.equal((await api('mode', { mode: 'direct' })).ok, true); evidence.checks.push('crashed_core_not_reported_running');
  assert.equal((await api('shutdown')).ok, true); stopped = true;
  // Subscription preparation is qualified on a second, empty owner instance so the
  // import path above keeps its own artifact and revision semantics.
  subscriptionStateDir = await fs.mkdtemp(path.join(os.tmpdir(), 'netfleet-macos-subscription-'));
  subscriptionHandle = await boot(subscriptionStateDir);
  const submission = `http://127.0.0.1:${relay.address().port}/subscription`;
  const prepared = await api('subscription-prepare', { subscription: { name: '节点列表 qualification', url: submission } });
  assert.equal(prepared.ok, true, JSON.stringify(prepared)); assert.equal(prepared.result.ready, true, JSON.stringify(prepared));
  const preparedState = await state();
  assert.equal(preparedState.runtime.running, false); assert.equal(preparedState.runtime.networkMode, 'explicit');
  assert.deepEqual(Object.keys(preparedState.policy.regions).sort(), ['hong_kong', 'japan', 'singapore']);
  assert.ok(preparedState.policy.providers[prepared.result.id]);
  assert.equal(preparedState.subscriptions[prepared.result.id].nodeCount, 3);
  const generated = JSON.parse(await fs.readFile(path.join(subscriptionStateDir, 'backend/profiles/Original.json')));
  assert.deepEqual(generated.rules, ['MATCH,Proxy']); assert.equal(generated['proxy-groups'][0].name, 'Proxy');
  evidence.checks.push('subscription_prepare_download_discovery_compile');
  assert.equal((await api('subscription-prepare', { subscription: { name: '重复地址', url: submission } })).ok, false);
  assert.equal((await api('subscription-prepare', { subscription: { name: '失效地址', url: `http://127.0.0.1:${relay.address().port}/missing` } })).ok, false);
  const afterFailure = await state();
  assert.equal(afterFailure.runtime.configured, true); assert.equal(Object.keys(afterFailure.subscriptions).length, 1);
  assert.deepEqual(Object.keys(afterFailure.policy.providers), [prepared.result.id]);
  evidence.checks.push('subscription_failure_preserves_previous_configuration');
  assert.equal((await api('shutdown')).ok, true); subscriptionHandle = null;
  await fs.rm(subscriptionStateDir, { recursive: true, force: true }); subscriptionStateDir = null;
  evidence.ok = true; evidence.proxyConnections = connections;
  const output = path.join(root, '.build/macos/qualification.json'); await fs.mkdir(path.dirname(output), { recursive: true });
  await fs.writeFile(output, JSON.stringify(evidence, null, 2)); console.log(JSON.stringify(evidence));
} finally {
  if (base && !stopped) await api('shutdown').catch(() => {});
  if (subscriptionHandle && subscriptionHandle.exitCode === null) await api('shutdown').catch(() => {});
  if (processHandle && processHandle.exitCode === null) await new Promise(resolve => { processHandle.once('exit', resolve); setTimeout(resolve, 5000); });
  if (subscriptionHandle && subscriptionHandle.exitCode === null) await new Promise(resolve => { subscriptionHandle.once('exit', resolve); setTimeout(resolve, 5000); });
  for (const socket of sockets) socket.destroy(); relay.close();
  // Retain isolated private state only on failure to permit exact diagnosis.
  if (evidence.ok) await fs.rm(stateDir, { recursive: true, force: true }); else console.error(`qualification state: ${stateDir}`);
  if (evidence.ok && subscriptionStateDir) await fs.rm(subscriptionStateDir, { recursive: true, force: true });
  else if (subscriptionStateDir) console.error(`qualification subscription state: ${subscriptionStateDir}`);
}
