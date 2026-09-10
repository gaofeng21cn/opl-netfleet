import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { DesktopNetFleetClient } from '../../ui/src/desktop/client';
import { desktopConfigRequest, toDesktopDraft } from '../../ui/src/desktop/policy';

const repo = path.resolve(import.meta.dir, '../..');
const state = await fs.mkdtemp(path.join(os.tmpdir(), 'netfleet-react-client-'));
const runtime = process.env.NETFLEET_RUNTIME_ROOT;
assert.ok(runtime, 'NETFLEET_RUNTIME_ROOT is required');
const child = spawn(path.join(runtime, 'bin/node'), [path.join(repo, 'desktop/runtime/server.mjs'), '--state', state], {
  env: process.env, stdio: ['ignore', 'pipe', 'pipe'],
});
const exited = once(child, 'exit');
let client: DesktopNetFleetClient | undefined;
let passed = false;
try {
  const url = await new Promise<URL>((resolve, reject) => {
    let output = '';
    const timeout = setTimeout(() => reject(new Error('desktop startup timeout')), 15000);
    child.once('error', error => { clearTimeout(timeout); reject(error); });
    child.once('exit', () => { clearTimeout(timeout); reject(new Error('desktop exited before startup')); });
    child.stdout.on('data', data => {
      output += data.toString();
      if (output.includes('\n')) { clearTimeout(timeout); resolve(new URL(JSON.parse(output.split('\n')[0]).url)); }
    });
  });
  client = new DesktopNetFleetClient(url.searchParams.get('token'), (input, init) => fetch(new URL(String(input), url), init));
  assert.equal((await client.readSnapshot()).status, null);
  await client.action('configure', { profile: {
    proxies: [{ name: '日本 本地验证', type: 'http', server: '127.0.0.1', port: 9 }],
    'proxy-groups': [{ name: 'Proxy', type: 'select', proxies: ['日本 本地验证'] }], rules: ['MATCH,Proxy'],
  } });
  await client.action('compile');
  const before = await client.readSnapshot();
  assert.ok(before.config, before.configError || 'shared configuration unavailable');
  const draft = toDesktopDraft(before);
  draft.automation.selectionIntervalSeconds += 60;
  const request = desktopConfigRequest(before.config, draft);
  await client.action('config-save', { request });
  const saved = await client.readSnapshot();
  assert.equal(saved.config?.automation.selection_interval_seconds, draft.automation.selectionIntervalSeconds);
  assert.notEqual(saved.config?.revision, before.config.revision);
  assert.deepEqual(saved.policy?.fail_open, before.policy?.fail_open);
  assert.deepEqual(saved.policy?.checks, before.policy?.checks);
  assert.equal(saved.runtime.running, false);
  await assert.rejects(client.action('config-save', { request }), /配置已被其他操作修改/);
  assert.deepEqual((await client.readSnapshot()).policy, saved.policy);
  const invalid = desktopConfigRequest(saved.config!, toDesktopDraft(saved));
  (Object.values(invalid.providers as Record<string, { region_ids: string[] }>)[0]).region_ids = ['unavailable-region'];
  await assert.rejects(client.action('config-save', { request: invalid }), /配置校验失败/);
  assert.deepEqual((await client.readSnapshot()).policy, saved.policy);
  assert.deepEqual((await client.connections()).connections, []);
  passed = true;
  const receipt = { ok: true, checks: ['real_react_client_import_compile', 'shared_configuration_projection', 'structured_editor_save',
    'unrelated_policy_preserved', 'stale_revision_rejected', 'invalid_edit_preserves_policy', 'no_core_started'], systemNetworkMutated: false };
  await fs.mkdir(path.join(repo, '.build/macos'), { recursive: true });
  await fs.writeFile(path.join(repo, '.build/macos/react-client-qualification.json'), JSON.stringify(receipt, null, 2));
  console.log(JSON.stringify(receipt));
} finally {
  if (client) await client.action('shutdown').catch(() => {});
  else child.kill('SIGTERM');
  await exited;
  if (passed) await fs.rm(state, { recursive: true, force: true });
}
