import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { miniappStatus, serveMiniappStatus } from '../desktop/runtime/miniapp.mjs';
import { BUNDLE_ID, contribute, ownerSocketPath, readOwner } from '../integrations/opl-netfleet-connector/connector.mjs';

const execute = promisify(execFile);
const root = path.resolve(import.meta.dirname, '..');

test('private socket supplies a bounded summary to the real connector', async t => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'netfleet-miniapp-'));
  await fs.chmod(directory, 0o700);
  const socketPath = path.join(directory, 'owner.sock');
  const state = { profile: 'file:OPL-NetFleet.json', configured: true, network: { mode: 'explicit' },
    controllerSecret: 'not-for-projection', subscriptions: { hidden: { url: 'secret' } } };
  const server = http.createServer(async (request, response) => {
    if (await serveMiniappStatus(request, response, () => miniappStatus({
      state, runtime: { running: true, controllerSecret: 'hidden' }, network: { clean: true },
    }))) return;
    response.writeHead(401); response.end();
  });
  await new Promise(resolve => server.listen(socketPath, resolve));
  await fs.chmod(socketPath, 0o600);
  t.after(async () => { await new Promise(resolve => server.close(resolve)); await fs.rm(directory, { recursive: true, force: true }); });
  const value = await contribute('status', {}, { platform: 'darwin', socketPath,
    run: async () => ({ stdout: '/Applications/OPL NetFleet.app/\n' }) });
  assert.equal(value.state, 'ready');
  assert.equal(value.data.items[0].status, 'netfleet');
  assert.equal(value.data.items[0].running, true);
  assert.equal(value.data.items[0].owner_available, true);
  assert.equal(value.data.items[0].freshness.state, 'fresh');
  assert.equal(value.data.items[0].freshness.observed_at, value.data.items[0].read_at);
  assert.equal(value.data.items[0].actions[0].action_ref, 'opl.netfleet.connector.v1#open');
  assert.equal(JSON.stringify(value).includes('secret'), false);
  assert.equal(JSON.stringify(value).includes('subscriptions'), false);
  for (const [url, method, status] of [['/rpc', 'POST', 401], ['/miniapp/status', 'POST', 405], ['/miniapp/status?file=state.json', 'GET', 401]]) {
    const actual = await new Promise(resolve => {
      const request = http.request({ socketPath, path: url, method }, response => { response.resume(); resolve(response.statusCode); }); request.end();
    });
    assert.equal(actual, status);
  }
  await fs.chmod(socketPath, 0o666);
  await assert.rejects(readOwner(socketPath), /owner_unavailable/);
});

test('open uses a fixed bundle, works without owner, and returns accepted only', async () => {
  const calls = [];
  const run = async (program, args) => { calls.push([program, args]); return { stdout: '/Applications/OPL NetFleet.app/\n' }; };
  const result = await contribute('open', {}, { platform: 'darwin', run, socketPath: '/absent/owner.sock' });
  assert.deepEqual(result, { state: 'ready', result: { status: 'accepted', bundle_id: BUNDLE_ID } });
  assert.deepEqual(calls.at(-1), ['/usr/bin/open', ['-b', 'com.onepersonlab.netfleet']]);
  assert.equal((await contribute('open', { bundle_id: 'another.app' }, { platform: 'darwin', run })).reason, 'empty_input_required');
  assert.equal((await contribute('open', {}, { platform: 'linux', run })).reason, 'macos_required');
  assert.equal((await contribute('open', {}, { platform: 'darwin', run: async () => { throw new Error('absent'); } })).reason, 'app_not_installed');
});

test('missing owner is visible and never reads a private fallback', async () => {
  const result = await contribute('status', {}, { platform: 'darwin', socketPath: '/absent/owner.sock', run: async () => { throw new Error('absent'); } });
  assert.equal(result.data.items[0].status, 'owner_unavailable');
  assert.equal(result.data.items[0].installed, false);
  assert.deepEqual(result.data.items[0].actions, []);
  assert.equal(result.data.items[0].owner_available, false);
  assert.equal(result.data.items[0].freshness.state, 'unavailable');
});

test('old or future owner observations never become current network state', async t => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'netfleet-age-'));
  await fs.chmod(directory, 0o700);
  const socketPath = path.join(directory, 'owner.sock');
  const now = Date.now();
  let observedAt = new Date(now - 16000);
  const server = http.createServer((request, response) => serveMiniappStatus(request, response,
    () => miniappStatus({ state: { configured: true, network: { mode: 'tun' } },
      runtime: { running: true }, network: { recoveryRequired: true }, now: observedAt })));
  await new Promise(resolve => server.listen(socketPath, resolve));
  await fs.chmod(socketPath, 0o600);
  t.after(async () => { await new Promise(resolve => server.close(resolve)); await fs.rm(directory, { recursive: true, force: true }); });
  const options = { platform: 'darwin', socketPath, now: () => now,
    run: async () => ({ stdout: '/Applications/OPL NetFleet.app/\n' }) };
  const stale = (await contribute('status', {}, options)).data.items[0];
  assert.equal(stale.status, 'owner_snapshot_stale');
  assert.equal(stale.installed, true);
  assert.equal(stale.owner_available, false);
  assert.equal(stale.freshness.state, 'stale');
  assert.equal(stale.freshness.observed_at, observedAt.toISOString());
  assert.equal(stale.running, undefined);
  assert.equal(stale.recovery_required, undefined);
  assert.equal(stale.actions.length, 1, 'explicit open remains available');
  observedAt = new Date(now + 6000);
  const future = (await contribute('status', {}, options)).data.items[0];
  assert.equal(future.status, 'owner_clock_invalid');
  assert.equal(future.freshness.state, 'unavailable');
  observedAt = new Date(now);
  const fresh = (await contribute('status', {}, options)).data.items[0];
  assert.equal(fresh.freshness.state, 'fresh');
  assert.equal(fresh.running, true);
  await new Promise(resolve => server.close(resolve));
  const unavailable = (await contribute('status', {}, options)).data.items[0];
  assert.equal(unavailable.freshness.state, 'unavailable');
  assert.equal(unavailable.read_at, undefined, 'closed owner does not retain a previous snapshot');
});

test('native isolated carrier discovers and calls the same local owner through Framework', {
  skip: !process.env.NETFLEET_OPL_BIN || process.platform !== 'darwin', timeout: 120000,
}, async t => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'netfleet-carrier-'));
  const stateDirectory = path.join(directory, 'state');
  const carrierDirectory = path.join(stateDirectory, 'internal-package-carrier');
  const marketplace = path.join(directory, 'marketplace');
  const nativeState = path.join(directory, 'netfleet-state');
  const socketPath = ownerSocketPath(nativeState);
  const environment = { ...process.env, OPL_STATE_DIR: stateDirectory,
    CODEX_HOME: path.join(directory, 'interactive'), NETFLEET_STATE_DIR: nativeState };
  const carrierEnvironment = { ...environment, CODEX_HOME: carrierDirectory };
  await Promise.all([fs.mkdir(carrierDirectory, { recursive: true }),
    fs.mkdir(environment.CODEX_HOME, { recursive: true }),
    fs.mkdir(path.dirname(socketPath), { recursive: true, mode: 0o700 })]);
  t.after(async () => {
    await fs.rm(directory, { recursive: true, force: true });
    await fs.rm(path.dirname(socketPath), { recursive: true, force: true });
  });
  await fs.cp(path.join(root, '.agents'), path.join(marketplace, '.agents'), { recursive: true });
  await fs.cp(path.join(root, 'integrations/opl-netfleet-connector'),
    path.join(marketplace, 'integrations/opl-netfleet-connector'), { recursive: true });
  const native = async args => JSON.parse((await execute('codex', args,
    { env: carrierEnvironment, timeout: 30000, maxBuffer: 1024 * 1024 })).stdout);
  const opl = async args => JSON.parse((await execute(process.env.NETFLEET_OPL_BIN, args,
    { env: environment, timeout: 30000, maxBuffer: 1024 * 1024 })).stdout);
  await native(['plugin', 'marketplace', 'add', marketplace, '--json']);
  const installed = await native(['plugin', 'add', 'opl-netfleet-connector@opl-netfleet', '--json']);
  assert.equal(installed.pluginId, 'opl-netfleet-connector@opl-netfleet');
  const manifest = JSON.parse(await fs.readFile(path.join(installed.installedPath, 'opl-package.json')));
  assert.equal(manifest.publication_channel_admission, 'development_only');
  assert.equal(manifest.codex_surface.configured_codex_plugin_carrier.publication_ref, null);
  const exposure = await opl(['packages', 'disable', 'opl-netfleet-connector', '--json']);
  assert.equal(exposure.opl_agent_package_exposure.configured_carrier.executor.status, 'callable');
  assert.equal(exposure.opl_agent_package_exposure.configured_carrier.enabled, false);
  const list = await native(['plugin', 'list', '--json']);
  assert.equal(list.installed.length, 1);
  assert.equal(list.installed[0].enabled, false, 'headless module stays outside interactive exposure');
  let mode = 'explicit';
  let observedAt;
  const server = http.createServer((request, response) => serveMiniappStatus(request, response,
    () => miniappStatus({ state: { profile: 'file:OPL-NetFleet.json', configured: true, network: { mode } },
      runtime: { running: true }, network: { clean: true }, now: observedAt || new Date() })));
  await new Promise(resolve => server.listen(socketPath, resolve));
  await fs.chmod(socketPath, 0o600);
  t.after(async () => { await new Promise(resolve => server.close(resolve)); });
  const read = async () => {
    const value = (await opl(['app', 'contribution', 'read', '--package-id', 'opl-netfleet-connector',
      '--ref', 'opl.netfleet.connector.v1#status'])).opl_app_contribution;
    assert.equal(value.carrier_readback.identity, 'opl-netfleet-connector@opl-netfleet');
    assert.equal(value.readiness.callability, 'callable');
    assert.equal(value.response.ok, true);
    return value.response.result.data.items[0];
  };
  assert.equal((await read()).freshness.state, 'fresh');
  mode = 'system';
  assert.equal((await read()).network_mode, 'system', 'reopen reads the same owner again');
  observedAt = new Date(Date.now() - 60000);
  const stale = await read();
  assert.equal(stale.freshness.state, 'stale');
  assert.equal(stale.running, undefined);
  await new Promise(resolve => server.close(resolve));
  assert.equal((await read()).freshness.state, 'unavailable');
  await execute('codex', ['plugin', 'remove', 'opl-netfleet-connector@opl-netfleet'],
    { env: carrierEnvironment, timeout: 30000, maxBuffer: 1024 * 1024 });
  assert.equal((await native(['plugin', 'list', '--json'])).installed.length, 0);
});
