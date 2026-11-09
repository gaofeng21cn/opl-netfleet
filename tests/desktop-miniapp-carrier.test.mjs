import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { miniappStatus, serveMiniappStatus } from '../desktop/runtime/miniapp.mjs';
import { ownerSocketPath } from '../integrations/opl-netfleet-connector/connector.mjs';

const execute = promisify(execFile);
const root = path.resolve(import.meta.dirname, '..');

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
