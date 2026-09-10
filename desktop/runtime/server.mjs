import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import net from 'node:net';
import crypto from 'node:crypto';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { installBuiltin, verifyInstalledBuiltin } from './builtin.mjs';
import { CoreOwner } from './core.mjs';
import { NetworkOwner } from './network.mjs';
import { privateDir, atomicJSON, readJSON, object, assert, run, requestBody, codeDigest } from './io.mjs';

const desktopRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const bundledWebRoot = path.join(desktopRoot, 'web');
const webRoot = await fs.access(bundledWebRoot).then(() => bundledWebRoot, () => path.resolve(desktopRoot, '../ui/dist-desktop'));
const sourceRoot = process.env.NETFLEET_SOURCE_ROOT ?? path.resolve(desktopRoot, '../openwrt/files/usr/libexec/opl-netfleet');
const builtinRoot = process.env.NETFLEET_BUILTIN_ROOT ?? (await fs.access(path.resolve(desktopRoot, '../builtin')).then(() => path.resolve(desktopRoot, '../builtin'), () => path.resolve(desktopRoot, '../.build/macos/builtin')));
const runtimeRoot = process.env.NETFLEET_RUNTIME_ROOT ?? path.join(os.homedir(), '.cache/opl-netfleet/macos/runtime');
const option = name => { const index = process.argv.indexOf(name); return index < 0 ? null : process.argv[index + 1]; };
const stateDir = path.resolve(option('--state') ?? path.join(os.homedir(), 'Library/Application Support/OPL NetFleet'));
const socketDirectory = path.join(os.tmpdir(), `opl-netfleet-${process.getuid()}-${crypto.createHash('sha256').update(stateDir).digest('hex').slice(0, 12)}`);
const socketPath = path.join(socketDirectory, 'owner.sock');
const token = crypto.randomBytes(32).toString('hex'), rpcToken = crypto.randomBytes(32).toString('hex');
const cleanEnv = { ...process.env };
for (const key of Object.keys(cleanEnv)) if (/^(https?|all|no)_proxy$/i.test(key)) delete cleanEnv[key];
const env = { ...cleanEnv, PATH: `${runtimeRoot}/bin:/usr/bin:/bin:/usr/sbin:/sbin`,
  NETFLEET_STATE_DIR: stateDir, NETFLEET_SOURCE_ROOT: sourceRoot, NETFLEET_DESKTOP_ROOT: desktopRoot,
  NETFLEET_SOCKET: socketPath, NETFLEET_RPC_TOKEN: rpcToken,
  UCODE_PATH: `${runtimeRoot}/lib/ucode/*.so:${runtimeRoot}/share/ucode/*.uc` };
const statePath = path.join(stateDir, 'state.json');
const codeRoot = path.join(stateDir, 'ucode');
let state, core, network, queue = Promise.resolve(), scheduled = false, closing = false, lastError = null, tickState = null, authorizeNetwork = false;
let webServer, rpcServer, origin;
let ownerLease;
async function acquireOwner() {
  const program = `import * as fs from 'fs';
const path = getenv('NETFLEET_STATE_DIR') + '/owner.lock';
const info = fs.lstat(path), owner = fs.stat(getenv('NETFLEET_STATE_DIR')).uid;
if (info != null && (info.type != 'file' || info.uid != owner || (info.mode & 077))) exit(1);
const lock = fs.open(path, 'ae', 0600);
if (lock == null || !lock.lock('xn')) exit(1);
print('ready\\n'); fs.stdout.flush(); fs.stdin.read('all'); lock.close();`;
  ownerLease = spawn(path.join(runtimeRoot, 'bin/ucode'), ['-L', `${runtimeRoot}/lib/ucode/*.so`, '-e', program], { env, stdio: ['pipe', 'pipe', 'ignore'] });
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => { ownerLease.kill(); reject(new Error('owner_lock_timeout')); }, 5000);
    ownerLease.once('error', () => { clearTimeout(timer); reject(new Error('owner_lock_unavailable')); });
    ownerLease.once('exit', () => { clearTimeout(timer); reject(new Error('desktop_owner_already_running')); });
    ownerLease.stdout.once('data', data => { clearTimeout(timer); data.toString().trim() === 'ready' ? resolve() : reject(new Error('owner_lock_invalid')); });
  });
  ownerLease.on('exit', () => { if (!closing && core) serialized(shutdown).catch(() => { lastError = 'owner_lock_lost'; }); });
}
const serialized = work => { const pending = queue.then(work); queue = pending.catch(() => {}); return pending; };
async function saveState(patch) { state = { ...state, ...patch }; await atomicJSON(statePath, state); return { ok: true }; }
async function freePort() { const server = net.createServer(); await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); }); const port = server.address().port; await new Promise(resolve => server.close(resolve)); return port; }
async function ucode(action, args = []) {
  // Mihomo -t parses configuration but loads file rules lazily. Check the
  // shipped MRS bytes as well before declaring a bundle ready or starting it.
  if (['compile', 'enable'].includes(action) && (await readJSON(path.join(stateDir, 'policy.json')))?.policy_source?.kind === 'bundle')
    await verifyInstalledBuiltin(builtinRoot, stateDir);
  const result = await run(path.join(runtimeRoot, 'bin/ucode'), ['-L', `${runtimeRoot}/lib/ucode/*.so`, path.join(codeRoot, 'main.uc'), action, ...args], { env, timeout: 300000 });
  let value;
  try { value = JSON.parse(result.stdout.trim()); }
  catch { await atomicJSON(path.join(stateDir, 'business-error.json'), { action, code: result.code, stderr: result.stderr, stdout: result.stdout }); throw new Error(`business_response_invalid:${action}`); }
  if (value?.ok === false || result.code !== 0) { const error = new Error(value?.error ?? `business_failed:${action}`); error.detail = value?.detail; throw error; }
  return value?.result ?? value;
}
async function parse(value) { return core.parseProfile(value); }
async function normalizedSubscriptions(values, previous = state.subscriptions, caches = {}, policy = null, reconcile = false) {
  const candidate = path.join(stateDir, 'candidate-sources.json');
  await atomicJSON(candidate, { sources: values, previous, imported: Object.fromEntries(Object.keys(caches).map(id => [id, object(caches[id])])), policy, reconcile });
  let planned;
  try { planned = await ucode('desktop-sources', [candidate]); }
  finally { await fs.unlink(candidate).catch(() => {}); }
  const sources = Object.fromEntries(Object.entries(planned.sources).map(([id, value]) => [id, {
    ...value, quota: previous[id]?.quota, subscriptionUserinfo: previous[id]?.subscriptionUserinfo,
    updatedAt: previous[id]?.updatedAt, nodeCount: previous[id]?.nodeCount }]));
  return { sources, policy: planned.policy };
}
async function replaceSubscriptions(values) {
  assert(!(await core.status()).running, 'stop_proxy_before_subscription_change');
  const current = await readJSON(path.join(stateDir, 'policy.json'));
  const { sources: subscriptions, policy } = await normalizedSubscriptions(values, state.subscriptions, {}, current, true);
  const changes = {};
  if (policy) { await validatePolicy(policy); changes['policy.json'] = policy; }
  for (const id of Object.keys(state.subscriptions)) if (!subscriptions[id]) changes[`backend/subscriptions/${id}.yaml`] = null;
  const next = { ...state, subscriptions }; changes['state.json'] = next;
  await fileTransaction(changes); state = next;
  if (policy) {
    try { await ucode('compile'); }
    catch { return { saved: true, ready: false, message: '来源变更已保存，请检查配置并重新编译。代理仍未启动。' }; }
  }
  return { saved: true, message: '订阅来源已保存，业务配置已同步。' };
}
async function downloadSubscription(item) {
  let response;
  try { response = await fetch(item.url, { headers: { 'User-Agent': item.user_agent || 'clash.meta' }, signal: AbortSignal.timeout(45000) }); }
  catch { throw new Error('subscription_download_failed'); }
  assert(response.ok, 'subscription_download_failed');
  const chunks = []; let size = 0;
  for await (const chunk of response.body) { size += chunk.length; assert(size <= 8 * 1024 * 1024, 'subscription_too_large'); chunks.push(Buffer.from(chunk)); }
  const profile = await parse(Buffer.concat(chunks).toString('utf8'));
  assert(Array.isArray(profile.proxies) && profile.proxies.length > 0, 'subscription_has_no_nodes');
  await core.validate({ proxies: profile.proxies, rules: ['MATCH,DIRECT'] });
  return { profile, metadata: { quota: undefined, subscriptionUserinfo: response.headers.get('subscription-userinfo'),
    updatedAt: new Date().toISOString(), nodeCount: profile.proxies.length } };
}
async function updateSubscription(id) {
  assert(/^[A-Za-z0-9_]{1,64}$/.test(id), 'invalid_subscription_id');
  const item = state.subscriptions[id]; assert(item, 'subscription_missing');
  if (item.imported && !item.url) return { ok: true, result: { id, unchanged: true } };
  const downloaded = await downloadSubscription(item);
  await fileTransaction({ [`backend/subscriptions/${id}.yaml`]: downloaded.profile,
    'state.json': { ...state, subscriptions: { ...state.subscriptions, [id]: { ...item, ...downloaded.metadata } } } });
  state = await readJSON(statePath);
  return { ok: true, result: { id, updated: true } };
}
async function discoverCandidate(profile, subscriptions, caches = {}, section = null, switchBuiltin = false) {
  const sources = [];
  for (const [id, item] of Object.entries(subscriptions)) {
    if (!item.enabled) continue;
    const cached = caches[id] ?? await readJSON(path.join(stateDir, 'backend/subscriptions', `${id}.yaml`));
    if (cached) sources.push({ section: id, display_name: item.name, profile: cached,
      digest: crypto.createHash('sha256').update(JSON.stringify(cached)).digest('hex') });
  }
  const candidate = path.join(stateDir, 'candidate-discovery.json');
  await atomicJSON(candidate, { current_profile: 'file:Original.json', current_profile_object: profile,
    subscriptions: sources, section, builtin: true, switch_builtin: switchBuiltin, policy: await readJSON(path.join(stateDir, 'policy.json')), target: 'macos', evidence_path: path.join(stateDir, 'evidence.json') });
  try { return await ucode('desktop-discover', [candidate]); }
  finally { await fs.unlink(candidate).catch(() => {}); }
}
async function prepareSubscription(input) {
  assert(!(await core.status()).running, 'stop_proxy_before_subscription_change');
  const id = input.id ?? `airport_${crypto.randomBytes(6).toString('hex')}`;
  assert(/^[A-Za-z0-9_]{1,64}$/.test(id), 'invalid_subscription_id');
  const old = state.subscriptions[id];
  const item = (await normalizedSubscriptions({ [id]: { ...old, ...input.subscription, enabled: old?.enabled ?? true } })).sources[id];
  assert(item.url, 'subscription_url_required');
  assert(!Object.entries(state.subscriptions).some(([key, value]) => key !== id && value.url === item.url), 'subscription_already_exists');
  const downloaded = await downloadSubscription(item);
  const subscriptions = { ...state.subscriptions, [id]: { ...item, ...downloaded.metadata } };
  const first = !state.configured;
  let profile = first ? downloaded.profile : await readJSON(path.join(stateDir, 'backend/profiles/Original.json'));
  if (first && !profile['proxy-groups']?.length && !profile.rules?.length) {
    profile = { proxies: profile.proxies, 'proxy-groups': [{ name: 'Proxy', type: 'select', proxies: profile.proxies.map(node => node.name) }], rules: ['MATCH,Proxy'] };
  }
  await core.validate(profile);
  const discovery = await discoverCandidate(profile, subscriptions, { [id]: downloaded.profile }, id);
  const { policy, recognized } = discovery;
  if (policy) await validatePolicy(policy);
  const next = { ...state, subscriptions, configured: Boolean(policy) };
  const changes = { 'state.json': next, [`backend/subscriptions/${id}.yaml`]: downloaded.profile };
  if (first) changes['backend/profiles/Original.json'] = profile;
  if (policy) changes['policy.json'] = policy;
  await fileTransaction(changes); state = next;
  if (!recognized) return { id, saved: true, ready: false, message: '订阅已保存并校验，但无法自动识别地区或主入口。请在配置中补充地区映射或导入完整配置。' };
  try { await ucode('compile'); }
  catch { return { id, saved: true, ready: false, message: '订阅已保存，业务配置尚未编译成功。请在配置中检查并重新编译，代理仍未启动。' }; }
  return { id, saved: true, ready: true, message: `已更新 ${downloaded.profile.proxies.length} 条节点记录并编译。可在概览启动代理；本机流量接入未改变。` };
}
async function useBuiltin() {
  assert(!(await core.status()).running, 'stop_proxy_before_policy_change');
  const policy = await readJSON(path.join(stateDir, 'policy.json'));
  assert(policy, 'initial_policy_needs_configuration');
  const result = await discoverCandidate(null, state.subscriptions, {}, null, true);
  await validatePolicy(result.policy);
  await fileTransaction({ 'policy.json': result.policy }, () => ucode('compile'));
  return { saved: true, ready: true, message: '已使用 NetFleet 内置策略：海外加速与 AI 出口独立选优。订阅和本机流量接入已保留。' };
}
async function configure(input, caches = null) {
  assert(!(await core.status()).running, 'stop_proxy_before_import');
  const profile = await parse(input.profile);
  await core.validate(profile);
  assert(Array.isArray(profile.proxies) && profile.proxies.length > 0 || object(profile['proxy-providers']), 'profile_has_no_nodes');
  if (input.policy !== undefined && input.policy !== null) await validatePolicy(input.policy);
  const next = structuredClone(state);
  if (input.subscriptions !== undefined) next.subscriptions = (await normalizedSubscriptions(input.subscriptions, caches ? {} : state.subscriptions, caches ?? {})).sources;
  const changes = { 'backend/profiles/Original.json': profile, 'policy.json': input.policy ?? null };
  // Native recovery configuration and its imported node cache have separate roles.
  if (caches) {
    for (const [id, value] of Object.entries(caches)) {
      assert(/^[A-Za-z0-9_]{1,64}$/.test(id) && object(value) && Array.isArray(value.proxies), 'invalid_backup_cache');
      await core.validate({ proxies: value.proxies, rules: ['MATCH,DIRECT'] });
      changes[`backend/subscriptions/${id}.yaml`] = value;
    }
  } else if (profile.proxies?.length) {
    changes['backend/subscriptions/imported.yaml'] = { proxies: profile.proxies };
    next.subscriptions.imported = { name: '导入的节点', imported: true, enabled: true, quota: { state: 'unknown' } };
  }
  Object.assign(next, { profile: 'file:Original.json', enabled: false, configured: true, mode: 'direct', scheduler: { enabled: false, running: false } });
  changes['state.json'] = next;
  await fileTransaction(changes); state = next;
  return { configured: true, policyRequired: input.policy === undefined };
}
async function validatePolicy(policy) {
  assert(object(policy), 'invalid_policy');
  const candidate = path.join(stateDir, 'candidate-policy.json');
  await atomicJSON(candidate, policy);
  try { await ucode('validate-schema', [candidate]); }
  finally { await fs.unlink(candidate).catch(() => {}); }
  return { saved: true };
}
async function savePolicy(policy) { await validatePolicy(policy); await atomicJSON(path.join(stateDir, 'policy.json'), policy); return { saved: true }; }
const journalPath = path.join(stateDir, 'import-transaction.json');
async function recoverImport() {
  const journal = await readJSON(journalPath);
  if (!journal) return;
  for (const [relative, value] of Object.entries(journal.before)) {
    assert(/^(state\.json|policy\.json|backend\/profiles\/Original\.json|backend\/subscriptions\/[A-Za-z0-9_]+\.yaml)$/.test(relative), 'unsafe_import_journal');
    const target = path.join(stateDir, relative);
    if (value === null) await fs.unlink(target).catch(error => { if (error.code !== 'ENOENT') throw error; });
    else { const temp = `${target}.restore`; await fs.writeFile(temp, Buffer.from(value, 'base64'), { mode: 0o600 }); await fs.rename(temp, target); }
  }
  await fs.unlink(journalPath);
}
async function fileTransaction(changes, verify = async () => {}) {
  const before = {};
  for (const relative of Object.keys(changes)) {
    try { before[relative] = (await fs.readFile(path.join(stateDir, relative))).toString('base64'); }
    catch (error) { if (error.code !== 'ENOENT') throw error; before[relative] = null; }
  }
  await atomicJSON(journalPath, { before });
  try {
    for (const [relative, value] of Object.entries(changes)) {
      if (value === null) await fs.unlink(path.join(stateDir, relative)).catch(error => { if (error.code !== 'ENOENT') throw error; });
      else await atomicJSON(path.join(stateDir, relative), value);
    }
    await verify();
    await fs.unlink(journalPath);
  } catch (error) { await recoverImport(); throw error; }
}
async function ensurePolicy() {
  if (await readJSON(path.join(stateDir, 'policy.json'))) return;
  for (const [id, item] of Object.entries(state.subscriptions)) if (item.enabled && item.url) await updateSubscription(id);
  const discovered = await ucode('desktop-discover');
  assert(discovered?.ready && discovered.policy, 'initial_policy_needs_configuration');
  await savePolicy(discovered.policy);
}
async function snapshot() {
  const runtime = await core.status();
  const networkState = await network.status();
  const actualMode = runtime.running ? (state.profile === 'file:OPL-NetFleet.json' ? 'netfleet' : 'mihomo') : networkState.clean !== false && !networkState.recoveryRequired ? 'direct' : 'unconfirmed';
  const subscriptions = Object.fromEntries(Object.entries(state.subscriptions).map(([id, value]) => [id, {
    name: value.name, enabled: value.enabled, imported: value.imported, hasUrl: Boolean(value.url),
    updatedAt: value.updatedAt ?? null, nodeCount: value.nodeCount ?? null }]));
  let status = null, events = null, config = null, configError = null, error = null;
  if (await readJSON(path.join(stateDir, 'policy.json'))) {
    try { status = await ucode('status'); events = await ucode('events'); }
    catch (failure) { error = failure.message; }
    try { config = await ucode('config-get'); }
    catch (failure) { configError = failure.message; }
  }
  return { runtime: { ...runtime, platform: 'macos', mode: actualMode, requestedMode: state.mode, networkMode: state.network.mode,
    ports: state.ports, configured: state.configured, lastError }, policy: await readJSON(path.join(stateDir, 'policy.json')),
    subscriptions, status, events, config, configError, network: networkState, error };
}
async function action(input) {
  assert(object(input) && typeof input.action === 'string', 'invalid_action');
  switch (input.action) {
    case 'configure': return configure(input);
    case 'use-builtin-policy': return useBuiltin();
    case 'subscriptions-set': return replaceSubscriptions(input.subscriptions);
    case 'subscription-prepare': return prepareSubscription(input);
    case 'save-policy': return savePolicy(input.policy);
    case 'config-save': {
      assert(object(input.request), 'config_request_unreadable');
      const envelope = path.join(stateDir, 'candidate-config-request.json');
      await atomicJSON(envelope, { request: input.request });
      try { return await ucode('config-save', [envelope]); }
      finally { await fs.unlink(envelope).catch(() => {}); }
    }
    case 'compile': await ensurePolicy(); return ucode('compile');
    case 'enable': {
      await ensurePolicy(); await ucode('compile'); const result = await ucode('enable');
      await saveState({ mode: 'netfleet', enabled: true, scheduler: { enabled: true, running: true } }); return result;
    }
    case 'disable': {
      const result = await ucode('disable'); await saveState({ mode: 'mihomo', scheduler: { enabled: false, running: false } }); return result;
    }
    case 'select-auto': return ucode('select', [input.capability ?? 'standard', 'auto']);
    case 'select-region': assert(typeof input.region === 'string', 'region_required'); return ucode('select', [input.capability ?? 'standard', input.region, 'desktop', 'region']);
    case 'refresh': {
      if (!await readJSON(path.join(stateDir, 'policy.json'))) {
        const entry = Object.entries(state.subscriptions).find(([, item]) => item.enabled && item.url);
        assert(entry, 'subscription_required');
        return prepareSubscription({ id: entry[0] });
      }
      const result = await ucode('refresh', ['manual']);
      assert(result?.result?.ok !== false, result?.result?.reason ?? 'subscription_refresh_failed');
      return { ...result, message: result?.result?.reloaded ? '订阅已更新，运行配置已重载并验证。' : '订阅检查完成，当前配置保持可用。' };
    }
    case 'mode': {
      assert(['direct', 'mihomo', 'netfleet'].includes(input.mode), 'invalid_mode');
      if (input.mode === 'netfleet') return action({ action: 'enable' });
      if (input.mode === 'direct') { await core.stop(); await saveState({ enabled: false, mode: 'direct', scheduler: { enabled: false, running: false } });
        await fs.unlink(path.join(stateDir, 'recovery.json')).catch(error => { if (error.code !== 'ENOENT') throw error; }); return { mode: 'direct' }; }
      if (state.profile === 'file:OPL-NetFleet.json') await ucode('disable');
      else { await core.start({ authorize: authorizeNetwork }); await saveState({ enabled: true }); }
      await saveState({ mode: 'mihomo', scheduler: { enabled: false, running: false } }); return { mode: 'mihomo' };
    }
    case 'network-install': return network.install({ authorize: input.authorize === true });
    case 'network': {
      assert(['explicit', 'system', 'tun'].includes(input.mode), 'invalid_network_mode');
      const before = structuredClone(state.network), wasRunning = (await core.status()).running;
      if (input.mode !== 'explicit' && (await network.status()).helper === 'needs-install') {
        const installed = await network.install({ authorize: input.authorize === true });
        assert(installed.ok, installed.status ?? 'helper_install_failed');
      }
      await core.stop();
      if (before.mode !== input.mode) { const closed = await network.detach({ close: true }); assert(closed.ok, closed.status ?? 'network_cleanup_failed'); }
      await saveState({ network: { mode: input.mode } });
      try { if (wasRunning) await core.start({ authorize: input.authorize === true }); }
      catch (error) { await saveState({ network: before }); if (wasRunning && before.mode === 'explicit') await core.start();
        else await saveState({ enabled: false, mode: 'direct', scheduler: { enabled: false, running: false } }); throw error; }
      return { networkMode: state.network.mode, running: (await core.status()).running };
    }
    case 'logs': { const log = await fs.readFile(path.join(stateDir, 'core.log'), 'utf8').catch(() => '');
      return { text: redact(log.slice(-24000)) }; }
    case 'connections': {
      const runtime = await core.status();
      assert(runtime.clean || runtime.controllerReady, 'controller_unavailable');
      if (runtime.clean) return { connections: [], count: 0, truncated: false, read_at: Math.floor(Date.now() / 1000) };
      return ucode('connections');
    }
    case 'backup-export': {
      const profile = await readJSON(path.join(stateDir, 'backend/profiles/Original.json'));
      const caches = {};
      for (const id of Object.keys(state.subscriptions)) caches[id] = await readJSON(path.join(stateDir, 'backend/subscriptions', `${id}.yaml`));
      return { schema: 'opl-netfleet-macos-backup.v1', profile, policy: await readJSON(path.join(stateDir, 'policy.json')), subscriptions: state.subscriptions, caches };
    }
    case 'backup-restore': {
      const backup = input.backup; assert(backup?.schema === 'opl-netfleet-macos-backup.v1' && object(backup.caches), 'invalid_backup');
      assert(!(await core.status()).running, 'stop_proxy_before_restore');
      for (const [id, value] of Object.entries(backup.caches)) {
        assert(/^[A-Za-z0-9_]{1,64}$/.test(id) && object(value) && Array.isArray(value.proxies), 'invalid_backup_cache');
        await core.validate({ proxies: value.proxies, rules: ['MATCH,DIRECT'] });
      }
      await configure({ profile: backup.profile, ...(backup.policy ? { policy: backup.policy } : {}), subscriptions: backup.subscriptions }, backup.caches);
      return { restored: true };
    }
    case 'shutdown': await shutdown(); return { stopped: true };
    default: throw new Error('unknown_action');
  }
}
function redact(text) {
  let result = text.replace(/https?:\/\/[^\s"']+/g, '[URL]');
  for (const value of [state.controllerSecret, token, rpcToken, ...Object.values(state.subscriptions).map(item => item.url)].filter(Boolean)) result = result.split(value).join('[redacted]');
  return result;
}
async function rpc({ method, params = {} }) {
  switch (method) {
    case 'code.digest': return { digest: await codeDigest(codeRoot, params.directory, params.files) };
    case 'state.get': return state;
    case 'state.patch': {
      const allowed = ['profile', 'enabled', 'scheduler']; assert(Object.keys(params).every(key => allowed.includes(key)), 'state_patch_rejected');
      if (params.profile !== undefined) core.resolveProfile(params.profile);
      if (params.enabled !== undefined) assert(typeof params.enabled === 'boolean', 'invalid_enabled');
      return saveState(params);
    }
    case 'core.start': return core.start({ authorize: authorizeNetwork });
    case 'core.stop': return core.stop();
    case 'core.status': return core.status();
    case 'subscription.update': return updateSubscription(params.id);
    case 'network.status': {
      const actual = await network.status(), running = await core.status();
      const route = await run('/sbin/route', ['-n', 'get', 'default'], { timeout: 3000 });
      return { ...actual, device_name: os.hostname(), upstream_ready: route.code === 0,
        mode: state.network.mode, ready: running.running && (state.network.mode === 'explicit' || actual.ready === true),
        dns_ready: running.running, clean: !running.running && actual.clean !== false };
    }
    case 'scheduler.state': return { installed: true, ...state.scheduler };
    case 'scheduler.set': await saveState({ scheduler: { enabled: params.enabled === true, running: params.running === true } }); return { ok: true, installed: true, ...state.scheduler };
    default: throw new Error('unknown_platform_method');
  }
}
function respond(response, status, value) { const body = JSON.stringify(value); response.writeHead(status, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body), 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' }); response.end(body); }
async function shutdown() {
  await core.stop(); const cleanup = await network.detach({ close: true }); assert(cleanup.ok, cleanup.status ?? 'network_cleanup_failed');
  await saveState({ enabled: false, mode: 'direct', scheduler: { enabled: false, running: false } });
  closing = true;
  setTimeout(async () => { webServer.close(); rpcServer.close(); await fs.unlink(socketPath).catch(() => {}); process.exit(0); }, 150);
}
async function tick() {
  if (closing) return;
  let wait = 5000;
  if (state.scheduler.running && !scheduled) {
    scheduled = true;
    try { const result = await serialized(async () => {
      return ucode('desktop-tick', [JSON.stringify(tickState)]);
    }); tickState = result.state; wait = Math.max(1000, result.delay_ms ?? result.delay ?? 15000); }
    catch (error) { lastError = error.message; }
    finally { scheduled = false; }
  }
  setTimeout(tick, wait).unref();
}
async function main() {
  for (const directory of [stateDir, socketDirectory, path.join(stateDir, 'backend/profiles'), path.join(stateDir, 'backend/subscriptions'), path.join(stateDir, 'backend/run')]) await privateDir(directory);
  await acquireOwner();
  // An existing owner is detected before its socket can be replaced.
  const alive = await new Promise(resolve => { const socket = net.connect(socketPath); socket.once('connect', () => { socket.destroy(); resolve(true); }); socket.once('error', () => resolve(false)); });
  assert(!alive, 'desktop_owner_already_running');
  await fs.unlink(socketPath).catch(error => { if (error.code !== 'ENOENT') throw error; });
  await recoverImport();
  state = await readJSON(statePath);
  if (!state) state = { schema: 'opl-netfleet-macos-state.v1', profile: 'file:Original.json', enabled: false, mode: 'direct', configured: false,
    subscriptions: {}, network: { mode: 'explicit' }, scheduler: { enabled: false, running: false },
    controllerSecret: crypto.randomBytes(32).toString('hex'), ports: { mixed: await freePort(), controller: await freePort(), dns: await freePort() } };
  assert(state.schema === 'opl-netfleet-macos-state.v1', 'unknown_state_schema');
  // Starting the UI never silently reclaims the machine's network.
  state.enabled = false; state.mode = 'direct'; state.scheduler = { enabled: false, running: false };
  network = new NetworkOwner({ stateDir, corePath: path.join(runtimeRoot, 'bin/mihomo'), ports: state.ports,
    ownerPid: process.pid, helperPath: path.join(runtimeRoot, 'bin/netfleet-network-helper') });
  core = new CoreOwner({ stateDir, corePath: path.join(runtimeRoot, 'bin/mihomo'), getState: () => state, network, env });
  await core.reconcileStartup();
  await installBuiltin(builtinRoot, stateDir);
  await saveState({});
  rpcServer = http.createServer(async (request, response) => {
    try { assert(request.method === 'POST' && request.url === '/rpc' && request.headers.authorization === `Bearer ${rpcToken}`, 'unauthorized');
      respond(response, 200, await rpc(await requestBody(request))); }
    catch (error) { respond(response, 400, { ok: false, error: error.message }); }
  });
  await new Promise((resolve, reject) => { rpcServer.once('error', reject); rpcServer.listen(socketPath, resolve); }); await fs.chmod(socketPath, 0o600);
  await privateDir(codeRoot);
  await fs.cp(sourceRoot, codeRoot, { recursive: true, force: true });
  await fs.cp(path.join(desktopRoot, 'ucode'), codeRoot, { recursive: true, force: true });
  webServer = http.createServer(async (request, response) => {
    try {
      const url = new URL(request.url, origin);
      assert(request.headers.host === new URL(origin).host, 'invalid_host');
      if (url.pathname === '/favicon.ico') { response.writeHead(204); response.end(); return; }
      if (url.pathname.startsWith('/api/')) {
        assert(request.headers.authorization === `Bearer ${token}`, 'unauthorized');
        assert(!request.headers.origin || request.headers.origin === origin, 'invalid_origin');
        if (request.method === 'GET' && url.pathname === '/api/state') return respond(response, 200, { ok: true, result: await serialized(snapshot) });
        assert(request.method === 'POST' && url.pathname === '/api/action' && request.headers['content-type']?.startsWith('application/json'), 'invalid_request');
        const input = await requestBody(request);
        return respond(response, 200, { ok: true, result: await serialized(async () => {
          authorizeNetwork = input.authorize === true;
          try { return await action(input); } finally { authorizeNetwork = false; }
        }) });
      }
      assert(request.method === 'GET', 'method_not_allowed');
      let file, type;
      if (url.pathname === '/') { file = path.join(webRoot, 'desktop.html'); type = 'text/html; charset=utf-8'; }
      else if (url.pathname === '/logo.png') { file = path.resolve(desktopRoot, '../assets/branding/opl-netfleet-logo.png'); type = 'image/png'; }
      else {
        assert(/^\/assets\/[A-Za-z0-9_-]+\.(js|css|svg|png|woff2)$/.test(url.pathname), 'not_found');
        file = path.join(webRoot, url.pathname.slice(1));
        type = { '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.svg': 'image/svg+xml', '.png': 'image/png', '.woff2': 'font/woff2' }[path.extname(file)];
      }
      const body = await fs.readFile(file);
      response.writeHead(200, { 'Content-Type': type, 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff',
        'Content-Security-Policy': "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'none'", 'Referrer-Policy': 'no-referrer' });
      response.end(body);
    } catch (error) { respond(response, error.message === 'unauthorized' ? 401 : 400, { ok: false, error: redact(error.message) }); }
  });
  await new Promise((resolve, reject) => { webServer.once('error', reject); webServer.listen(0, '127.0.0.1', resolve); });
  origin = `http://127.0.0.1:${webServer.address().port}`;
  console.log(JSON.stringify({ url: `${origin}/?token=${token}` }));
  tick();
  for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => { serialized(shutdown).catch(() => { lastError = 'shutdown_cleanup_failed'; }); });
  if (process.env.NETFLEET_PARENT_PID) setInterval(() => {
    try { process.kill(Number(process.env.NETFLEET_PARENT_PID), 0); }
    catch { if (!closing) serialized(shutdown).catch(() => { lastError = 'orphan_cleanup_failed'; }); }
  }, 2000).unref();
}
main().catch(error => { console.error(JSON.stringify({ ok: false, error: error.message })); process.exitCode = 1; });
