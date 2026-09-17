import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import net from 'node:net';
import crypto from 'node:crypto';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { installBuiltin, verifyInstalledBuiltin } from './builtin.mjs';
import { CoreOwner, projectProfile } from './core.mjs';
import { NetworkOwner } from './network.mjs';
import { coreSettingRows } from './settings.mjs';
import { expandPanelArchive, installPanel, materializePanel } from './dashboard.mjs';
import { MAX_APP_IMAGE_BYTES, TEAM_ID, applicationBundle, componentState, latestRelease, releaseCandidate, sha256, verifyBundle, withMountedApp } from './update.mjs';
import { privateDir, atomicJSON, readJSON, object, assert, run, requestBody, codeDigest } from './io.mjs';

const desktopRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
// 应用包根目录：打包后指向 Contents/Resources，源码运行时指向仓库根。
const appRoot = path.resolve(desktopRoot, '..');
// 应用包目录：更新替换的目标就是它自己；源码运行没有包结构时为 null。
const appBundle = applicationBundle(appRoot);
const bundledWebRoot = path.join(desktopRoot, 'web');
const webRoot = await fs.access(bundledWebRoot).then(() => bundledWebRoot, () => path.resolve(desktopRoot, '../ui/dist-desktop'));
const sourceRoot = process.env.NETFLEET_SOURCE_ROOT ?? path.resolve(desktopRoot, '../openwrt/files/usr/libexec/opl-netfleet');
const builtinRoot = process.env.NETFLEET_BUILTIN_ROOT ?? (await fs.access(path.resolve(desktopRoot, '../builtin')).then(() => path.resolve(desktopRoot, '../builtin'), () => path.resolve(desktopRoot, '../.build/macos/builtin')));
// 打包后的面板资源位于应用包内；源码运行退回本机构建目录。
const bundledDashboard = path.resolve(desktopRoot, '../dashboard');
const localDashboard = path.resolve(desktopRoot, '../.build/macos/dashboard');
const hasDashboard = directory => fs.access(path.join(directory, 'index.html')).then(() => true, () => false);
const dashboardRoot = process.env.NETFLEET_DASHBOARD_ROOT
  ?? (await hasDashboard(bundledDashboard) ? bundledDashboard : (await hasDashboard(localDashboard) ? localDashboard : null));
const dashboardMeta = dashboardRoot ? await readJSON(path.join(dashboardRoot, '../dashboard-meta.json')).catch(() => null) : null;
const UPDATE_RELEASE = 'https://api.github.com/repos/Zephyruso/zashboard/releases/latest';
const UPDATE_ASSET = 'dist-cdn-fonts.zip';
const UPDATE_ROOT = 'https://github.com/Zephyruso/zashboard/releases';
// 发布源默认是 GitHub 的 Release 列表；测试可以用 NETFLEET_UPDATE_FEED 指向本地
// 夹具。清单不是信任锚——制品仍必须通过 GitHub 摘要、Developer ID 与公证校验。
const APP_RELEASES = process.env.NETFLEET_UPDATE_FEED ?? 'https://api.github.com/repos/gaofeng21cn/opl-netfleet/releases?per_page=20';
const MAX_UPDATE_BYTES = 33554432;
const packagedIdentity = await readJSON(path.join(appRoot, 'build.json')).catch(() => null);
const runtimeRoot = process.env.NETFLEET_RUNTIME_ROOT ?? path.join(os.homedir(), '.cache/opl-netfleet/macos/runtime');
const option = name => { const index = process.argv.indexOf(name); return index < 0 ? null : process.argv[index + 1]; };
const stateDir = path.resolve(option('--state') ?? path.join(os.homedir(), 'Library/Application Support/OPL NetFleet'));
// 面板的当前所有者副本：首次从随包资源播种，之后由受校验的更新替换。
const panelRoot = path.join(stateDir, 'panel');
const panelStatePath = path.join(stateDir, 'panel.json');
const updateStatePath = path.join(stateDir, 'updates.json');
const socketDirectory = path.join(os.tmpdir(), `opl-netfleet-${process.getuid()}-${crypto.createHash('sha256').update(stateDir).digest('hex').slice(0, 12)}`);
const socketPath = path.join(socketDirectory, 'owner.sock');
const token = crypto.randomBytes(32).toString('hex'), rpcToken = crypto.randomBytes(32).toString('hex');
const cleanEnv = { ...process.env };
for (const key of Object.keys(cleanEnv)) if (/^(https?|all|no)_proxy$/i.test(key)) delete cleanEnv[key];
const env = { ...cleanEnv, PATH: `${runtimeRoot}/bin:/usr/bin:/bin:/usr/sbin:/sbin`,
  NETFLEET_STATE_DIR: stateDir, NETFLEET_SOURCE_ROOT: sourceRoot, NETFLEET_DESKTOP_ROOT: desktopRoot, NETFLEET_APP_ROOT: appRoot,
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
// 随包运行组件的实际身份：能执行的就现场回读版本，不能执行的退回随包清单。
let componentCache = null;
async function runtimeComponents() {
  if (componentCache) return componentCache;
  const packaged = await readJSON(path.join(appRoot, 'dependencies.json')).catch(() => null);
  const probe = async (file, args, pattern) => {
    try {
      const result = await run(path.join(runtimeRoot, 'bin', file), args, { env, timeout: 5000 });
      const match = result.code === 0 ? pattern.exec(`${result.stdout}\n${result.stderr}`) : null;
      return match ? match[1] : null;
    } catch { return null; }
  };
  const [mihomo, yq] = await Promise.all([
    probe('mihomo', ['-v'], /v(\d+\.\d+\.\d+)/),
    probe('yq', ['--version'], /version v?(\d+\.\d+\.\d+)/),
  ]);
  componentCache = [
    { id: 'node', label: 'Node', version: process.version.replace(/^v/, ''), source: 'running' },
    { id: 'ucode', label: 'UCode', version: packaged?.ucode?.version ?? null, source: 'package' },
    { id: 'mihomo', label: 'Mihomo 核心', version: mihomo ?? packaged?.mihomo?.version ?? null, source: mihomo ? 'runtime' : 'package' },
    { id: 'yq', label: 'yq', version: yq ?? packaged?.yq?.version ?? null, source: yq ? 'runtime' : 'package' },
  ];
  return componentCache;
}

// 特权网络组件是 root 所有的独立副本：应用更新后它们可能落后于包内版本，
// 需要用户重新授权安装。这里只比较字节，不触发任何特权操作。
const HELPER_PATH = '/Library/PrivilegedHelperTools/org.opl.netfleet.network';
const PRIVILEGED_CORE_PATH = '/Library/Application Support/OPL NetFleet/Privileged/mihomo';
async function networkComponentState() {
  if (process.platform !== 'darwin') return { state: 'unsupported-platform' };
  const helper = await componentState(path.join(runtimeRoot, 'bin/netfleet-network-helper'), HELPER_PATH);
  const core = await componentState(path.join(runtimeRoot, 'bin/mihomo'), PRIVILEGED_CORE_PATH);
  const states = [helper.state, core.state];
  const state = states.includes('missing') ? 'missing' : states.includes('outdated') ? 'outdated'
    : states.includes('unbundled') ? 'unbundled' : 'match';
  return { state, helper: helper.state, core: core.state };
}

async function sourceProfile() {
  if (typeof state.profile !== 'string') return null;
  try { return await core.parseProfile(await fs.readFile(core.resolveProfile(state.profile), 'utf8')); }
  catch { return null; }
}

// 本机核心设置只投影三层真实事实：Profile 声明、平台交给核心的配置、特权会话覆写。
async function coreProjection(runtime, networkState) {
  const profile = await sourceProfile();
  let projected = null;
  if (profile) {
    try { projected = projectProfile(profile, state, core.runtimeDir, state.network.mode); }
    catch { projected = null; }
  }
  const running = runtime.running ? await core.controller('/configs') : null;
  const overlay = state.network.mode === 'tun' && networkState.running ? networkState.overlay ?? null : null;
  const packaged = packagedIdentity;
  const components = await networkComponentState();
  return { profile: state.profile ?? null, mode: state.network.mode, running: Boolean(runtime.running),
    components_sync: components,
    overlay: Boolean(overlay), rows: coreSettingRows({ profile, projected, running, overlay }),
    components: await runtimeComponents(),
    identity: packaged && typeof packaged === 'object' ? {
      version: packaged.package_version ?? null, release: packaged.package_release ?? null,
      channel: packaged.channel ?? null, source_commit: packaged.source_commit ?? null,
      source_tree: packaged.source_tree ?? null, working_tree_dirty: packaged.working_tree_dirty === true,
    } : null };
}

// 面板的当前所有者副本：随包资源只负责首次播种，之后的更新由受校验的
// 候选替换，核心始终从这份私有副本取文件。
async function seedPanel() {
  if (!dashboardRoot) return null;
  const existing = await readJSON(panelStatePath).catch(() => null);
  if (existing && await fs.access(path.join(panelRoot, 'index.html')).then(() => true, () => false)) return existing;
  await materializePanel(dashboardRoot, panelRoot);
  const seeded = { schema: 'opl-netfleet-macos-panel-state.v1', version: dashboardMeta?.version ?? null,
    source: 'bundled', index_sha256: dashboardMeta?.index_sha256 ?? null, updated_at: null };
  await atomicJSON(panelStatePath, seeded);
  return seeded;
}

// 有界的外部读取：不跟随任意地址、限制响应体、限制等待时间。
async function fetchBounded(url, { accept = 'application/json', maxBytes = 1048576, timeout = 15000 } = {}) {
  const response = await fetch(url, { headers: { Accept: accept, 'User-Agent': 'OPL-NetFleet' },
    redirect: 'follow', signal: AbortSignal.timeout(timeout) });
  assert(response.ok, `update_request_failed:${response.status}`);
  const body = Buffer.from(await response.arrayBuffer());
  assert(body.length <= maxBytes, 'update_response_too_large');
  return body;
}

const versionParts = value => /^v?(\d+)\.(\d+)\.(\d+)$/.exec(String(value ?? ''))?.slice(1).map(Number) ?? null;
const newerVersion = (candidate, installed) => {
  const left = versionParts(candidate), right = versionParts(installed);
  if (!left) return false;
  if (!right) return true;
  for (let index = 0; index < 3; index++) {
    if (left[index] !== right[index]) return left[index] > right[index];
  }
  return false;
};

// 检查上游面板与已发布的 macOS 应用版本。结果缓存 24 小时，只报告候选，
// 不自动安装；安装始终由用户确认后的 dashboard-update 承担。
async function refreshUpdateStatus() {
  const status = { schema: 'opl-netfleet-macos-updates.v1', checked_at: Math.floor(Date.now() / 1000),
    panel: null, app: null, errors: [] };
  const panel = await readJSON(panelStatePath).catch(() => null);
  try {
    const body = JSON.parse((await fetchBounded(UPDATE_RELEASE, { maxBytes: 1048576 })).toString('utf8'));
    const asset = (Array.isArray(body?.assets) ? body.assets : []).find(item => item?.name === UPDATE_ASSET);
    const tag = body?.tag_name;
    const valid = typeof tag === 'string' && /^v\d+\.\d+\.\d+$/.test(tag) && body?.draft === false && body?.prerelease === false
      && asset?.browser_download_url === `${UPDATE_ROOT}/download/${tag}/${UPDATE_ASSET}`
      && Number.isInteger(asset?.size) && asset.size > 0 && asset.size <= MAX_UPDATE_BYTES
      && /^sha256:[a-f0-9]{64}$/.test(String(asset?.digest ?? ''));
    status.panel = valid
      ? { installed: panel?.version ?? null, available: tag, update_available: newerVersion(tag, panel?.version),
          url: asset.browser_download_url, size: asset.size, sha256: asset.digest.slice(7) }
      : { installed: panel?.version ?? null, available: null, update_available: false, error: 'update_release_invalid' };
  } catch (error) { status.errors.push(`panel:${error.message}`); status.panel = { installed: panel?.version ?? null, available: null, update_available: false, error: 'update_check_failed' }; }
  try {
    const releases = JSON.parse((await fetchBounded(APP_RELEASES, { maxBytes: 2097152 })).toString('utf8'));
    const installed = packagedIdentity?.package_version ?? null;
    const release = latestRelease(releases);
    const candidate = releaseCandidate(release);
    const available = candidate?.version ?? null;
    // 候选必须带 GitHub 计算的 sha256 摘要；没有摘要的 Release 只作为手动下载入口。
    status.app = { installed, available, update_available: Boolean(installed) && Boolean(available) && newerVersion(available, installed),
      url: release?.html_url ?? null, published_at: release?.published_at ?? null, installation_unknown: installed === null,
      self_update: selfUpdateState(), candidate,
      ...(candidate ? {} : release ? { manifest_error: 'update_asset_digest_missing' } : {}) };
  } catch (error) { status.errors.push(`app:${error.message}`); status.app = { installed: packagedIdentity?.package_version ?? null, available: null, update_available: false, installation_unknown: packagedIdentity == null, self_update: selfUpdateState(), error: 'update_check_failed' }; }
  await atomicJSON(updateStatePath, status);
  return status;
}

// 自更新只对分发渠道的 Developer ID 构建开放：本地与开发构建没有稳定 Team ID，
// 替换它们会破坏本地交付的证据链。
function selfUpdateState() {
  if (process.platform !== 'darwin') return 'unsupported-platform';
  if (packagedIdentity?.channel !== 'distribution') return 'local-build';
  if (packagedIdentity?.working_tree_dirty !== false) return 'dirty-build';
  if (!appBundle) return 'not-an-app-bundle';
  return 'available';
}

async function updateStatus({ force = false } = {}) {
  const cached = await readJSON(updateStatePath).catch(() => null);
  if (!force && cached && Math.floor(Date.now() / 1000) - Number(cached.checked_at ?? 0) < 86400) return cached;
  return refreshUpdateStatus();
}

// 只有通过大小与 SHA-256 校验的候选才会进入私有面板副本；替换按文件原子
// 落位，核心仍在服务旧文件时不会看到缺失路径。
async function applyPanelUpdate() {
  const status = await refreshUpdateStatus();
  const candidate = status.panel;
  assert(candidate?.update_available && candidate.url && candidate.sha256, candidate?.error ?? 'dashboard_candidate_unavailable');
  const body = await fetchBounded(candidate.url, { accept: 'application/octet-stream', maxBytes: MAX_UPDATE_BYTES, timeout: 120000 });
  assert(body.length === candidate.size, 'dashboard_asset_mismatch');
  assert(crypto.createHash('sha256').update(body).digest('hex') === candidate.sha256, 'dashboard_asset_mismatch');
  const rows = expandPanelArchive(body);
  await installPanel(rows, panelRoot);
  const index = rows.find(row => row.relative === 'index.html');
  await atomicJSON(panelStatePath, { schema: 'opl-netfleet-macos-panel-state.v1', version: candidate.available,
    source: 'update', index_sha256: crypto.createHash('sha256').update(index.bytes).digest('hex'),
    updated_at: Math.floor(Date.now() / 1000) });
  // 正在运行的核心按请求读取该目录，替换后无需重启；同时刷新它的服务副本。
  if (await fs.access(core.runtimeDir).then(() => true, () => false)) {
    await materializePanel(panelRoot, path.join(core.runtimeDir, 'ui'));
  }
  return { ok: true, version: candidate.available, previous: candidate.installed,
    panel: await dashboardProjection(await core.status()) };
}

// 应用更新：按 GitHub 资产摘要校验下载内容，验证新包签名与公证后暂存，再把替换
// 交给独立进程；替换发生在应用退出之后，这里不触碰正在运行的包。
async function applyAppUpdate() {
  assert(selfUpdateState() === 'available', selfUpdateState());
  // 复用已缓存的检查结论：安装的安全性来自制品校验，不来自再取一次列表，
  // 因此不为此额外消耗发布源的调用额度。
  const status = await updateStatus();
  const candidate = status.app?.candidate;
  assert(candidate, status.app?.manifest_error ?? 'update_candidate_unavailable');
  const image = await fetchBounded(candidate.url, { accept: 'application/octet-stream', maxBytes: MAX_APP_IMAGE_BYTES, timeout: 600000 });
  assert(image.length === candidate.size_bytes, 'update_asset_mismatch');
  assert(sha256(image) === candidate.sha256, 'update_asset_mismatch');
  return stageAppUpdate(candidate, image);
}

async function stageAppUpdate(candidate, image) {
  assert(Buffer.isBuffer(image) && image.length > 0, 'update_asset_unavailable');
  const work = path.join(stateDir, 'update');
  await fs.rm(work, { recursive: true, force: true });
  await privateDir(work);
  const imagePath = path.join(work, 'candidate.dmg');
  await fs.writeFile(imagePath, image, { mode: 0o600 });
  const staged = path.join(work, 'staged.app');
  // 挂载镜像并验证其中的应用：Developer ID 授权、Team ID、Gatekeeper 评估、
  // 已装订的公证票据，以及干净的分发构建身份；挂载总是会被卸载。
  await withMountedApp(imagePath, work, async app => {
    await verifyBundle(app, candidate.version);
    const copied = await run('/usr/bin/ditto', [app, staged], { timeout: 300000 });
    assert(copied.code === 0, 'update_stage_failed');
  });
  // 替换进程在应用退出后运行：它等待本应用的 PID 消失，再做单槽替换与重启。
  const script = path.join(desktopRoot, 'runtime/update-install.sh');
  const receipt = path.join(stateDir, 'update-receipt.json');
  const previous = path.join(path.dirname(appBundle), '.OPL NetFleet.previous.app');
  const child = spawn('/bin/sh', [script, String(process.ppid), staged, appBundle, previous, receipt, String(TEAM_ID)],
    { detached: true, stdio: 'ignore', env });
  child.unref();
  await atomicJSON(path.join(stateDir, 'update-pending.json'), { schema: 'opl-netfleet-macos-update-pending.v1',
    version: candidate.version, tag: candidate.tag, staged, target: appBundle, at: Math.floor(Date.now() / 1000) });
  // 被替换的是正在运行的这个构建，所以"上一个版本"就是包内身份，不是检查缓存。
  return { ok: true, version: candidate.version, previous: packagedIdentity?.package_version ?? null,
    relaunch_required: true };
}

async function dashboardUrl() {
  const projection = await dashboardProjection(await core.status());
  assert(projection.available, projection.reason ?? 'dashboard_unavailable');
  const host = '127.0.0.1';
  const url = new URL(`http://${host}:${state.ports.controller}/ui/`);
  url.search = new URLSearchParams({ hostname: host, host, port: String(state.ports.controller), secret: state.controllerSecret }).toString();
  // Zashboard only accepts a new connection on setup when a backend is already saved.
  url.hash = '/setup';
  return { ok: true, url: url.toString() };
}

// 面板可用性只说明本机核心当前能否提供这套随包资源；连接信息按需生成，
// 不进入普通快照，也不写入展示缓存。
async function dashboardProjection(runtime) {
  const panel = await readJSON(panelStatePath).catch(() => null);
  const reason = !panel ? 'dashboard_assets_missing'
    : !runtime.running ? 'core_not_running'
      : !runtime.controllerReady ? 'controller_unavailable' : null;
  return { available: reason === null, version: panel?.version ?? null, source: panel?.source ?? null, reason };
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
    subscriptions, status, events, config, configError, network: networkState, error,
    core: await coreProjection(runtime, networkState), dashboard: await dashboardProjection(runtime) };
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
      // A crashed core can leave the selected NetFleet profile marked enabled.
      // Reconcile through the normal stop path before compiling it again.
      if (state.enabled && !(await core.status()).running) await action({ action: 'mode', mode: 'direct' });
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
    case 'dashboard-open': return dashboardUrl();
    // 只读的候选检查（缓存的 24 小时结果或一次有界查询），不安装任何东西。
    case 'update-check': return updateStatus({ force: input.force === true });
    case 'dashboard-update': return applyPanelUpdate();
    case 'app-update-apply': return applyAppUpdate();
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
  // 随包面板先播种为私有副本，核心与更新都只使用这一份所有者数据。
  const panel = await seedPanel();
  core = new CoreOwner({ stateDir, corePath: path.join(runtimeRoot, 'bin/mihomo'), getState: () => state, network, env,
    dashboardDir: panel ? panelRoot : null });
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
