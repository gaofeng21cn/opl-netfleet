import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { delay } from '../runtime/io.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const resources = process.env.NETFLEET_TEST_APP && path.join(process.env.NETFLEET_TEST_APP, 'Contents/Resources');
const serverPath = resources ? path.join(resources, 'desktop/runtime/server.mjs') : path.join(root, 'desktop/runtime/server.mjs');
if (resources) {
  process.env.NETFLEET_RUNTIME_ROOT = path.join(resources, 'runtime');
  process.env.NETFLEET_SOURCE_ROOT = path.join(resources, 'shared');
  process.env.NETFLEET_BUILTIN_ROOT = path.join(resources, 'builtin');
}

const state = await fs.mkdtemp(path.join(os.tmpdir(), 'netfleet-owner-crash-'));
const lostState = await fs.mkdtemp(path.join(os.tmpdir(), 'netfleet-lost-state-'));
let server, base, token, corePid;
const alive = pid => { try { process.kill(pid, 0); return true; } catch { return false; } };
async function start(dir = state) {
  server = spawn(process.execPath, [serverPath, '--state', dir], { env: process.env, stdio: ['ignore', 'pipe', 'pipe'] });
  const line = await new Promise((resolve, reject) => {
    let out = '', error = ''; const timer = setTimeout(() => reject(new Error('startup_timeout')), 15000);
    server.stdout.on('data', data => { out += data; if (out.includes('\n')) { clearTimeout(timer); resolve(JSON.parse(out.split('\n')[0])); } });
    server.stderr.on('data', data => { error += data; });
    server.on('exit', () => { clearTimeout(timer); reject(new Error(error)); });
  });
  const url = new URL(line.url); base = url.origin; token = url.searchParams.get('token');
}
async function exited() {
  if (!server || server.exitCode !== null || server.signalCode !== null) return server?.exitCode ?? null;
  return new Promise(resolve => { server.once('exit', code => resolve(code)); setTimeout(() => resolve(null), 10000); });
}
async function api(action, fields = {}) {
  return (await fetch(`${base}/api/action`, { method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ action, ...fields }), signal: AbortSignal.timeout(30000) })).json();
}
async function status() { return (await (await fetch(`${base}/api/state`, { headers: { Authorization: `Bearer ${token}` } })).json()).result.runtime; }
try {
  await start();
  assert.equal((await api('configure', { profile: { proxies: [{ name: 'local', type: 'http', server: '127.0.0.1', port: 1 }], rules: ['MATCH,DIRECT'] } })).ok, true);
  assert.equal((await api('mode', { mode: 'mihomo' })).ok, true);
  corePid = (await status()).pid; assert.ok(alive(corePid));
  server.kill('SIGKILL');
  for (let i = 0; i < 50 && alive(corePid); i++) await delay(100);
  assert.equal(alive(corePid), false, 'A killed desktop owner must not leave its core running');
  await start();
  const actual = await status(); assert.equal(actual.running, false); assert.equal(actual.clean, true); assert.equal(actual.mode, 'direct');
  assert.equal((await api('shutdown')).ok, true);
  assert.equal(await exited(), 0, 'A graceful shutdown must end the owner process');
  // 外部清理状态目录时，退出仍必须完成：核心停止与接管释放已成立，写不回运行记录
  // 不能把应用永久留在运行状态（旧实现会因此卡在"应用保持打开"）。
  server = null;
  await start(lostState);
  await fs.rm(lostState, { recursive: true, force: true });
  assert.equal((await api('shutdown')).ok, true, 'A removed state directory must not fail the graceful exit');
  assert.equal(await exited(), 0, 'The owner must exit after its state directory disappeared');
  console.log(JSON.stringify({ ok: true,
    checks: ['owner_SIGKILL_reaps_core', 'restart_confirms_clean_direct', 'shutdown_completes_without_state_directory'], systemNetworkMutated: false }));
} finally {
  if (server?.exitCode === null && server?.signalCode === null) await api('shutdown').catch(() => {});
  await delay(300);
  if (corePid && alive(corePid)) process.kill(corePid, 'SIGTERM');
  if (server?.exitCode === null && server?.signalCode === null) server.kill('SIGKILL');
  await fs.rm(state, { recursive: true, force: true });
  await fs.rm(lostState, { recursive: true, force: true });
}
