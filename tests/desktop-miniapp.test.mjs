import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { miniappStatus, serveMiniappStatus } from '../desktop/runtime/miniapp.mjs';
import { BUNDLE_ID, contribute, readOwner } from '../integrations/opl-netfleet-connector/connector.mjs';

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
