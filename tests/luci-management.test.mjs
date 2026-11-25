import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { webcrypto } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { beforeEach, test } from 'node:test';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const RESOURCES = path.join(ROOT, 'plugins/product-ui/resources');
const SHELL_RESOURCES = path.join(ROOT, 'openwrt/luci-app-netfleet/htdocs/luci-static/resources/netfleet');

const clone = value => JSON.parse(JSON.stringify(value));

function text(value) {
  if (Array.isArray(value)) return value.map(text).join('');
  if (value == null) return '';
  return typeof value === 'object' ? text(value.children) : String(value);
}

function E(tag, attrs, children) {
  const items = Array.isArray(children) ? children : children == null ? [] : [children];
  // LuCI E() appends one child level; nested arrays stringify DOM objects.
  const node = { tag, attrs: attrs || {}, children: items.map(item => Array.isArray(item) ? String(item) : item) };
  node.toString = () => '[object HTMLElement]';
  node.value = node.attrs.value == null ? tag === 'textarea' ? text(node.children) : '' : String(node.attrs.value);
  // HTML boolean attributes are true by presence, including disabled="false".
  node.type = node.attrs.type;
  for (const name of ['disabled', 'checked', 'open', 'required']) {
    if (node.attrs[name] != null) node.attrs[name] = String(node.attrs[name]);
    Object.defineProperty(node, name, {
      get: () => node.attrs[name] != null,
      set: value => {
        if (value) node.attrs[name] = '';
        else delete node.attrs[name];
      },
    });
  }
  node.setAttribute = (name, value) => { node.attrs[name] = String(value); };
  node.getAttribute = name => node.attrs[name] ?? null;
  Object.defineProperty(node, 'textContent', {
    get: () => text(node),
    set: value => { node.children = [value]; },
  });
  function setParents(itemsList) {
    itemsList.forEach(item => {
      if (Array.isArray(item)) setParents(item);
      else if (item && typeof item === 'object') item.parent = node;
    });
  }
  setParents(node.children);
  node.remove = () => {};
  node.click = () => node.attrs.click && node.attrs.click({ target: node });
  node.replaceChildren = (...replacement) => { node.children = replacement; setParents(replacement); };
  node.reportValidity = () => !node.required || !!node.value;
  node.checkValidity = node.reportValidity;
  return node;
}

function all(root, predicate) {
  if (Array.isArray(root)) return root.flatMap(item => all(item, predicate));
  if (!root || typeof root !== 'object') return [];
  return [...(predicate(root) ? [root] : []), ...all(root.children, predicate)];
}

const find = (root, predicate) => all(root, predicate)[0];
const button = (root, name) => find(root, node => node.tag === 'button' && text(node) === name);

function locked(node) {
  for (let at = node; at; at = at.parent) if (at.disabled && (at === node || at.tag === 'fieldset')) return true;
  return false;
}

function fire(node, kind = 'click', data = {}) {
  assert(node, 'missing interactive node');
  assert(!locked(node), 'disabled control must not accept input');
  if (Object.hasOwn(data, 'value')) node.value = data.value;
  return node.attrs[kind]({ target: Object.assign(node, data) });
}

const tick = () => new Promise(resolve => setImmediate(resolve));
const baseclass = { extend: value => value };
const forbiddenStorage = new Proxy({}, { get() { throw new Error('secret storage access is forbidden'); } });

if (!globalThis.crypto) globalThis.crypto = webcrypto;

let modal = null;
let notifications = [];
let ui;

beforeEach(() => {
  modal = null;
  notifications = [];
  ui = {
    showModal(title, content) { modal = { title, content }; },
    hideModal() { modal = null; },
    addNotification(_, content, severity) { notifications.push({ text: text(content), severity }); },
  };
  globalThis.localStorage = forbiddenStorage;
  globalThis.sessionStorage = forbiddenStorage;
  globalThis.document = { body: { appendChild() {} }, querySelectorAll() { return []; } };
  globalThis.L = { url: (...parts) => '/cgi-bin/luci/' + parts.join('/') };
  delete globalThis.window;
  delete globalThis.fetch;
});

function loadModule(name, api) {
  if (name === 'compatibility.js') {
    const source = fs.readFileSync(path.join(RESOURCES, '../../https-compat/resources/manager.js'), 'utf8');
    return new Function('E', source.replace('export function', 'function') + '\nreturn createManager;')(E)({
      api,
      ui,
      readOnly: () => false,
    });
  }
  const product = new Function('baseclass', fs.readFileSync(path.join(RESOURCES, 'product.js'), 'utf8'))(baseclass);
  const advanced = new Function('baseclass', 'ui', 'E', fs.readFileSync(path.join(RESOURCES, 'advanced.js'), 'utf8'))(baseclass, ui, E);
  let shared;
  const evaluate = (file, managed) => new Function(
    'baseclass', 'ui', 'api', 'E', 'managed', 'product', 'advanced', 'loadModule',
    fs.readFileSync(path.join(RESOURCES, file), 'utf8'),
  )(baseclass, ui, api, E, managed, product, advanced, async target => evaluate(target + '.js', shared));
  if (name === 'managed.js') {
    shared = evaluate(name, null);
    Object.assign(shared, evaluate('components.js', shared), evaluate('subscriptions.js', shared));
    return shared;
  }
  return evaluate(name, loadModule('managed.js', api));
}

function configModule(management) {
  return new Function(
    'baseclass', 'ui', 'management', 'E', 'compatibility',
    fs.readFileSync(path.join(RESOURCES, 'config.js'), 'utf8'),
  )(baseclass, ui, management, E, { render: () => null });
}

function modesModule(api, selectionRunner) {
  const source = fs.readFileSync(path.join(RESOURCES, 'product-pages.js'), 'utf8');
  const exports = source.slice(0, source.lastIndexOf('return baseclass.extend({')) +
    'return { progress: managed, regions: regionsPage, controls: operatingModeControls, controller: productController, summary: statusSummary, health: pathHealthLabel, region: currentRegion, mode: modeName };';
  const managed = loadModule('managed.js', { operationGet: async () => ({}), ...api });
  if (selectionRunner) managed.runSelection = selectionRunner;
  const views = new Function('baseclass', 'ui', 'managed', 'E', fs.readFileSync(path.join(RESOURCES, 'product-views.js'), 'utf8'))(baseclass, ui, managed, E);
  return new Function('baseclass', 'ui', 'netfleet', 'E', 'managed', 'productViews', exports)(baseclass, ui, api, E, managed, views);
}

function networkState() {
  return {
    available: true,
    backend: 'native-mihomo',
    revision: 'network-r1',
    running: true,
    settings: {
      dns: {
        nameservers: ['1.1.1.1'],
        default_nameservers: ['9.9.9.9'],
        proxy_nameservers: ['https://resolver.example/dns-query'],
        direct_nameservers: [],
        policies: [{ domain: 'service.example', match: 'exact', nameservers: ['1.0.0.1'] }],
        proxy_policies: [],
      },
      lan: {
        enabled: true,
        interfaces: ['br-lan'],
        rules: [{ id: 'device-a', enabled: true, ipv4: ['192.0.2.10'], ipv6: ['2001:db8::10'], mac: [], proxy: false, dns: true }],
      },
      router: { enabled: true },
      listeners: {
        mixed_port: 7890,
        http_port: 0,
        socks_port: 0,
        authentication_enabled: true,
        credentials: [{ id: 'login-a', username: 'operator', password_configured: true }],
      },
    },
    resources: { interfaces: [{ name: 'br-lan', up: true, device: 'br-lan' }], preserved_dns_policy_count: 1, preserved_proxy_policy_count: 0 },
  };
}

function maintenanceState() {
  return {
    supported: true,
    revision: 'maintenance-r1',
    profiles: [{ id: 'custom.json', ref: 'file:custom.json', format: 'json', size_bytes: 64, modified_at: 100, referenced: false, editable: true }],
    core: { running: true, controller_available: true, running_version: 'v1.19.30', actions: ['restart', 'reload'] },
    backup: { format: 'netfleet-backup-v1', contains_credentials: true },
  };
}

function policyConfig() {
  return {
    revision: 'policy-r1',
    active: true,
    pending_apply: false,
    backend: { id: 'native-mihomo', display_name: 'NetFleet + Mihomo' },
    policy_source: { kind: 'bundle', ref: 'bundle:base-v1', display_name: '默认策略' },
    policy_source_options: [],
    policy_groups: ['OUTBOUND'],
    recovery_profile: { ref: 'file:custom.json', display_name: '本地配置' },
    recovery_profile_options: [],
    providers: [],
    provider_options: [],
    regions: [],
    region_options: [],
    capabilities: [{ id: 'standard', display_name: '常规出口', enabled: true, mode: 'automatic', region_ids: [], entry_group: 'OUTBOUND', policy_groups: [] }],
    routing_rules: [],
    automation: { enabled: true, selection_interval_seconds: 1800, subscription_refresh_enabled: true, subscription_refresh_interval_seconds: 43200 },
    safety: {
      region_switch_margin_ms: 150,
      leaf_switch_margin_ms: 150,
      runtime_grace_seconds: 120,
      latency_url: 'https://latency.example',
      path_probe_url: 'https://probe.example',
      guard_probe_url: 'https://guard.example',
    },
  };
}

function controller() {
  const policy = policyConfig();
  return {
    busy: false,
    liveDataReady: true,
    redraw() {},
    refreshes: 0,
    async refreshData() { this.refreshes++; },
    config: policy,
    configDraft: clone(policy),
    configSection: 'network',
    status: { providers: [], regions: [], runtime: {} },
    showConfigWizard() {},
    discardConfig() {},
    previewConfigChanges() {},
    saveConfig() {},
    confirmConfigApply() {},
  };
}

function collectJsFiles(dir) {
  const files = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) files.push(...collectJsFiles(full));
    else if (entry.name.endsWith('.js')) files.push(full);
  }
  return files;
}

test('staged modules resolve every versioned dependency', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'netfleet-luci-assets-'));
  try {
    const resources = path.join(tmpDir, 'resources');
    const pkgDir = path.join(ROOT, 'openwrt/luci-app-netfleet');
    const makefile = fs.readFileSync(path.join(pkgDir, 'Makefile'), 'utf8');
    const installs = [...makefile.matchAll(/\$\(INSTALL_DATA\)\s+\.\/htdocs\/luci-static\/resources\/(\S+)\s+\$\(1\)\/www\/luci-static\/resources\/(\S+)/g)];
    assert(installs.length > 0);
    for (const [, source, destination] of installs) {
      const target = path.join(resources, destination);
      fs.mkdirSync(path.dirname(target), { recursive: true });
      fs.copyFileSync(path.join(path.dirname(SHELL_RESOURCES), source), target);
    }
    execFileSync('sh', [path.join(ROOT, 'openwrt/luci-app-netfleet/stage-assets.sh'), resources, 'vtest'], { stdio: 'pipe' });
    for (const script of collectJsFiles(resources)) {
      const content = fs.readFileSync(script, 'utf8');
      for (const [, dependency] of content.matchAll(/require (netfleet\.[A-Za-z0-9_.]+)/g)) {
        assert.equal(fs.statSync(path.join(resources, dependency.replaceAll('.', '/') + '.js')).isFile(), true, dependency);
      }
    }
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test('shared probe edit submits both aliases and distinct probes stay independent', () => {
  const owner = controller();
  owner.configSection = 'safety';
  owner.configDraft.health_probes_shared = true;
  owner.configDraft.safety.guard_probe_url = owner.configDraft.safety.path_probe_url;
  const config = configModule(loadModule('managed.js', {}));
  let page = config.render(owner);
  assert(text(page).includes('通道健康检查地址'));
  assert(!text(page).includes('最终保护地址'));
  let inputs = all(page, node => node.tag === 'input' && node.attrs.type === 'url');
  assert.equal(inputs.length, 2);
  fire(inputs[1], 'change', { value: 'https://new-health.example' });
  assert.equal(config.request(owner.configDraft).safety.path_probe_url, 'https://new-health.example');
  assert.equal(config.request(owner.configDraft).safety.guard_probe_url, 'https://new-health.example');
  assert(!Object.hasOwn(config.request(owner.configDraft), 'health_probes_shared'));
  owner.configDraft.health_probes_shared = false;
  page = config.render(owner);
  inputs = all(page, node => node.tag === 'input' && node.attrs.type === 'url');
  assert.equal(inputs.length, 3);
  fire(inputs[1], 'change', { value: 'https://only-path.example' });
  assert.equal(config.request(owner.configDraft).safety.guard_probe_url, 'https://new-health.example');
  fire(inputs[2], 'change', { value: 'https://only-guard.example' });
  assert.equal(config.request(owner.configDraft).safety.path_probe_url, 'https://only-path.example');
  assert.equal(config.request(owner.configDraft).safety.guard_probe_url, 'https://only-guard.example');
});

test('advanced json invalid draft blocks owner call and omissions are preserved', async () => {
  const owner = controller();
  owner.networkState = networkState();
  owner.networkState.settings.advanced = { 'sniffer.sniff': { TLS: { ports: [443] } }, 'tcp-concurrent': true };
  owner.networkState.resources.advanced_fields = [{ id: 'sniffer.sniff', label: '协议与端口', kind: 'sniff', group: '嗅探' }];
  owner.networkDraft = clone(owner.networkState.settings);
  let calls = 0;
  const management = loadModule('management.js', { networkValidate: async () => { calls++; return { changes: [] }; } });
  const root = management.network(owner);
  const field = find(root, node => node.tag === 'textarea' && node.attrs['aria-label'] === '协议与端口');
  fire(field, 'input', { value: '{', setCustomValidity() {} });
  await fire(button(root, '校验配置'));
  assert.equal(calls, 0);
  assert(notifications.some(n => n.text.includes('有效 JSON')));
  await fire(button(root, '应用网络配置'));
  assert.equal(modal, null);
  fire(field, 'input', { value: '{"HTTP":{"port":[80]}}', setCustomValidity() {} });
  await fire(button(root, '校验配置'));
  assert.equal(calls, 1);
  ui.hideModal();
  fire(button(root, '专家 JSON 编辑'));
  const expert = find(modal.content, node => node.tag === 'textarea');
  expert.value = '{"sniffer.sniff":null}';
  fire(button(modal.content, '更新草稿'));
  assert.equal(owner.networkDraft.advanced['sniffer.sniff'], null);
  assert.equal(owner.networkDraft.advanced['tcp-concurrent'], true);
});

test('geodata update settings are visible outside collapsed advanced section', () => {
  const state = networkState();
  state.resources.advanced_fields = [
    { id: 'geo-auto-update', label: '自动更新 GeoData', kind: 'bool', group: '规则数据' },
    { id: 'geo-update-interval', label: 'GeoData 更新间隔（小时）', kind: 'int', min: 1, max: 720, group: '规则数据' },
    { id: 'log-level', label: '核心日志级别', kind: 'enum', options: ['silent', 'info'], group: '连接' },
  ];
  state.settings.advanced = { 'geo-auto-update': true, 'geo-update-interval': 168, 'log-level': 'info' };
  const owner = controller();
  owner.networkState = state;
  owner.networkDraft = clone(state.settings);
  const root = loadModule('management.js', {}).network(owner);
  const geodata = find(root, node => node.tag === 'section' && node.attrs.class === 'netfleet-geodata-settings');
  assert(geodata, 'GeoData controls have their own visible settings section: ' + text(root));
  assert(find(geodata, node => node.tag === 'strong' && text(node) === '自动更新 GeoData'));
  assert(find(geodata, node => node.tag === 'strong' && text(node) === 'GeoData 更新间隔（小时）'));
  assert.equal(all(geodata, node => node.tag === 'select').length, 1);
  assert.equal(all(geodata, node => node.tag === 'input' && node.attrs.type === 'number').length, 1);
  const advanced = find(root, node => node.tag === 'details' && text(node).includes('Mihomo 高级设置'));
  assert(advanced && !text(advanced).includes('自动更新 GeoData'));
});

test('network default rule is explicit and new device precedes it', async () => {
  const state = networkState();
  const fallback = { id: 'default', enabled: true, ipv4: [], ipv6: [], mac: [], proxy: true, dns: true };
  state.settings.lan.rules.push(fallback);
  const management = loadModule('management.js', { networkGet: async () => state });
  const owner = controller();
  await management.load(owner, 'network');
  let root = management.network(owner);
  const row = find(root, node => node.tag === 'tr' && text(node).includes('其余设备（默认规则）'));
  assert(row);
  assert.equal(all(row, node => node.tag === 'textarea').length, 0);
  assert.equal(all(row, node => node.attrs.type === 'checkbox')[0].checked, true);
  assert.deepEqual(owner.networkDraft, state.settings, 'rendering must not change the actual default rule');
  fire(button(root, '添加设备规则'));
  assert.equal(owner.networkDraft.lan.rules.at(-1).id, 'default');
  assert.equal(owner.networkDraft.lan.rules.at(-2).enabled, false);
  root = management.network(owner);
  assert.equal(all(root, node => node.attrs['aria-label'] === 'IPv4 地址或网段').length, 2);
  assert(text(root).includes('留空并启用会匹配其余所有设备'));
});

test('network domain policy edits exact and suffix matches', async () => {
  const state = networkState();
  state.settings.dns.policies.push({ domain: 'linkedin.com', match: 'suffix', nameservers: ['https://1.1.1.1/dns-query#overseas'] });
  const management = loadModule('management.js', { networkGet: async () => state });
  const owner = controller();
  await management.load(owner, 'network');
  const root = management.network(owner);
  assert(text(root).includes('精确域名只匹配该域名；域名后缀同时匹配该域名及其子域名'));
  const selections = all(root, node => node.tag === 'select' && node.attrs['aria-label'] === '按域名指定 DNS 匹配方式');
  assert.equal(selections.length, 2);
  const chosen = node => all(node, item => item.tag === 'option' && item.attrs.selected != null).map(text);
  assert.deepEqual(chosen(selections[0]), ['精确域名']);
  assert.deepEqual(chosen(selections[1]), ['域名后缀']);
  assert(text(root).includes('另有 1 条规则（如 geosite:、rule-set:）由当前配置保留，不在此处编辑。'));
  fire(selections[1], 'change', { value: 'exact' });
  assert.equal(owner.networkDraft.dns.policies[1].match, 'exact');
  fire(button(root, '添加域名 DNS'));
  assert.deepEqual(owner.networkDraft.dns.policies.at(-1), { domain: '', match: 'exact', nameservers: [] });
});

test('network form sends complete revision bound request', async () => {
  const sent = [];
  let reads = 0;
  const api = {
    networkGet: async () => { reads++; return networkState(); },
    networkValidate: async request => { sent.push(['validate', request]); },
    networkApply: async request => { sent.push(['apply', request]); return { ok: true }; },
  };
  const management = loadModule('management.js', api);
  const owner = controller();
  await Promise.all([management.load(owner, 'network'), management.load(owner, 'network')]);
  assert.equal(reads, 1, 'concurrent reads must share the request');
  let root = management.network(owner);
  const ruleRow = find(root, node => node.tag === 'tr' && all(node, item => item.attrs['aria-label'] === 'IPv4 地址或网段').length);
  const ruleChecks = all(ruleRow, node => node.attrs.type === 'checkbox');
  assert.equal(ruleChecks[1].checked, false, 'a disabled proxy rule must remain unchecked in real HTML');
  assert.equal(ruleChecks[2].checked, true);
  const dns = find(root, node => node.attrs['aria-label'] === '常规 DNS');
  fire(dns, 'input', { value: '8.8.8.8\n8.8.4.4\n' });
  const username = find(root, node => node.attrs['aria-label'] === '代理用户名');
  fire(username, 'input', { value: 'updated-operator' });
  await fire(button(root, '校验配置'));
  assert.equal(sent[0][0], 'validate');
  assert.equal(sent[0][1].revision, 'network-r1');
  assert.deepEqual(sent[0][1].settings, owner.networkDraft);
  assert.deepEqual(sent[0][1].settings.dns.nameservers, ['8.8.8.8', '8.8.4.4']);
  assert.equal(sent[0][1].settings.listeners.credentials[0].password, undefined, 'an untouched password must be preserved by omission');
  owner.networkDraft.dns.nameservers.push('4.4.4.4');
  assert.deepEqual(sent[0][1].settings.dns.nameservers, ['8.8.8.8', '8.8.4.4'], 'requests must not alias editable state');
  fire(button(root, '应用网络配置'));
  assert.equal(modal.title, '应用网络配置');
  assert(text(modal.content).includes('DNS 解析、代理监听与认证'));
  assert(!text(modal.content).includes('updated-operator'), 'change review must not expose credentials');
  await fire(button(modal.content, '确认应用'));
  assert.equal(sent[1][0], 'apply');
  assert.equal(sent[1][1].revision, 'network-r1');
  assert.equal(sent[1][1].settings.lan.rules[0].ipv6[0], '2001:db8::10');
  assert.equal(sent[1][1].settings.listeners.credentials[0].username, 'updated-operator');
  assert.equal(owner.busy, false);
  assert.equal(owner.refreshes, 1);
  assert.equal(reads, 2, 'apply must re-read network owner state');
  const config = configModule(management);
  root = config.render(owner);
  assert(button(root, '应用网络配置'));
  assert(!button(root, '应用配置'), 'network must not expose the unrelated policy apply command');
  assert(!button(root, '保存配置'));
  owner.maintenanceState = maintenanceState();
  owner.configSection = 'files';
  root = config.render(owner);
  assert(button(root, '导入配置'));
  assert(!button(root, '应用配置'));
});

test('stale live state blocks writes and failed apply preserves recovery', async () => {
  let writes = 0;
  const api = {
    networkGet: async () => networkState(),
    networkApply: async () => {
      writes++;
      const error = new Error('network_revision_conflict');
      error.detail = { rollback: { ok: true } };
      throw error;
    },
  };
  const management = loadModule('management.js', api);
  const owner = controller();
  await management.load(owner, 'network');
  owner.liveDataReady = false;
  let root = management.network(owner);
  assert(locked(find(root, node => node.attrs['aria-label'] === '常规 DNS')));
  assert(button(root, '校验配置').disabled);
  assert(button(root, '应用网络配置').disabled);
  owner.maintenanceState = maintenanceState();
  root = management.files(owner);
  assert(button(root, '导入配置').disabled);
  assert(button(root, '下载备份').disabled);
  assert(find(root, node => node.attrs['aria-label'] === '选择配置备份').disabled);
  root = management.maintenance(owner);
  assert(button(root, '重启核心').disabled);
  owner.liveDataReady = true;
  owner.networkDraft.router.enabled = false;
  root = management.network(owner);
  fire(button(root, '应用网络配置'));
  owner.liveDataReady = false;
  await fire(button(modal.content, '确认应用'));
  assert.equal(writes, 0, 'confirmation must recheck live state');
  owner.liveDataReady = true;
  fire(button(management.network(owner), '应用网络配置'));
  await fire(button(modal.content, '确认应用'));
  assert.equal(writes, 1);
  assert.equal(owner.busy, false);
  assert(notifications.some(item => item.text.includes('网络配置已变化') && item.text.includes('已恢复操作前状态')));
  owner.networkState = { available: false, reason: 'native_backend_required' };
  assert(!button(management.network(owner), '应用网络配置'));
});

test('no change skips write and read failure does not retry success', async () => {
  let writes = 0;
  const api = { networkGet: async () => networkState(), networkApply: async () => { writes++; return { state: 'applied' }; } };
  const management = loadModule('management.js', api);
  const owner = controller();
  await management.load(owner, 'network');
  await fire(button(management.network(owner), '应用网络配置'));
  assert.equal(modal, null);
  assert.equal(writes, 0);
  assert(owner.networkResult.includes('无需应用'));
  owner.networkDraft.router.enabled = false;
  owner.refreshData = async () => { throw new Error('transport interrupted'); };
  fire(button(management.network(owner), '应用网络配置'));
  await fire(button(modal.content, '确认应用'));
  assert.equal(writes, 1);
  assert.equal(owner.busy, false);
  assert(notifications.some(item => item.severity === 'warning' && item.text.includes('已完成') && item.text.includes('不要重复执行')));
  assert(!notifications.some(item => item.severity === 'error'));
});

test('subscription and selection read failure keep execution result', async () => {
  const managed = loadModule('managed.js', { operationGet: async () => ({ subscription: null, selection: null, packages: null }) });
  for (const action of ['runSubscription', 'runSelection']) {
    const owner = controller();
    owner.refreshData = async () => { throw new Error('read timed out'); };
    let writes = 0;
    const result = await managed[action](owner, async () => { writes++; return { state: 'unchanged' }; });
    assert.equal(writes, 1);
    assert.equal(result.state, 'unchanged');
    assert.equal(owner.busy, false);
    clearTimeout(owner.operationTimer);
  }
  assert.equal(notifications.filter(item => item.text.includes('不要重复执行')).length, 2);
  assert(!notifications.some(item => item.text.includes('可能仍在更新') || item.text.includes('可能仍在测速')));
});

test('profile import is memory only and clears after save or cancel', async () => {
  const saved = [];
  const api = {
    maintenanceGet: async () => maintenanceState(),
    profileSave: async value => { saved.push(clone(value)); },
    profileGet: async () => ({ revision: 'maintenance-r1', profile: { id: 'custom.json', content: 'private-profile-body' } }),
  };
  const management = loadModule('management.js', api);
  const owner = controller();
  await management.load(owner, 'maintenance');
  let root = management.files(owner);
  fire(button(root, '导入配置'));
  const upload = find(modal.content, node => node.tag === 'input' && node.attrs.type === 'file');
  const body = '{"secret":"fixture-only-sensitive-value"}';
  fire(upload, 'change', { files: [{ name: 'imported.json', size: body.length, text: async () => body }] });
  await tick();
  const editor = find(modal.content, node => node.attrs['aria-label'] === '配置内容');
  assert.equal(editor.value, body);
  assert.equal(find(modal.content, node => node.attrs['aria-label'] === '文件名').value, 'imported.json');
  await fire(button(modal.content, '校验并保存'));
  await tick();
  assert.deepEqual(saved, [{ revision: 'maintenance-r1', id: 'imported.json', content: body }]);
  assert.equal(editor.value, '');
  assert.equal(modal, null);
  assert(!JSON.stringify(owner.maintenanceState).includes('fixture-only-sensitive-value'));
  root = management.files(owner);
  await fire(button(root, '编辑'));
  const cancelledEditor = find(modal.content, node => node.attrs['aria-label'] === '配置内容');
  assert.equal(cancelledEditor.value, 'private-profile-body');
  fire(button(modal.content, '取消'));
  assert.equal(cancelledEditor.value, '');
  assert.equal(saved.length, 1);
  assert.equal(modal, null);
  fire(button(management.files(owner), '导入配置'));
  owner.liveDataReady = false;
  fire(button(modal.content, '校验并保存'));
  await tick();
  assert.equal(saved.length, 1, 'an already opened editor must not write after live state is lost');
  fire(button(modal.content, '取消'));
});

test('config rules send cidr and exclusive direct target', async () => {
  const config = configModule({});
  const owner = controller();
  owner.configSection = 'routing';
  let root = config.render(owner);
  const add = find(root, node => String(node.attrs.class || '') === 'netfleet-inline-add');
  const selects = all(add, node => node.tag === 'select');
  fire(selects[0], 'change', { value: 'ip_cidr' });
  fire(find(add, node => node.tag === 'input'), 'input', { value: '2001:db8::/32' });
  fire(selects[1], 'change', { value: 'direct' });
  fire(button(add, '添加规则'));
  let request = config.request(owner.configDraft);
  assert.deepEqual(request.routing_rules, [{ kind: 'ip_cidr', value: '2001:db8::/32', target: 'direct' }]);
  assert.equal(request.revision, 'policy-r1');
  assert(!Object.hasOwn(request, 'network'));
  root = config.render(owner);
  const row = find(root, node => node.tag === 'tr' && all(node, item => item.tag === 'input').length === 1);
  const rowSelects = all(row, node => node.tag === 'select');
  fire(rowSelects[1], 'change', { value: 'standard' });
  request = config.request(owner.configDraft);
  assert.deepEqual(request.routing_rules, [{ kind: 'ip_cidr', value: '2001:db8::/32', capability: 'standard' }]);
  assert(!Object.hasOwn(request.routing_rules[0], 'target'));
  const wire = [];
  const rpc = { declare: options => (...args) => { wire.push({ method: options.method, args }); return Promise.resolve({ ok: true, result: { valid: true } }); } };
  const api = new Function('baseclass', 'rpc', 'fs', 'request', 'L', 'window', fs.readFileSync(path.join(RESOURCES, 'api.js'), 'utf8'))(
    baseclass, rpc, {}, {}, { env: { rpctimeout: 20 } }, {},
  );
  owner.previewConfigChanges = () => api.configValidate(config.request(owner.configDraft));
  await fire(button(config.render(owner), '校验与变更'));
  assert.equal(wire[0].method, 'config_validate');
  assert.deepEqual(wire[0].args[0].routing_rules, [{ kind: 'ip_cidr', value: '2001:db8::/32', capability: 'standard' }]);
  owner.configDraft.routing_rules.push({ kind: 'domain_suffix', value: 'example.test', target: 'direct' });
  root = config.render(owner);
  fire(all(root, n => n.attrs['aria-label'] === '上移规则')[1]);
  assert.equal(config.request(owner.configDraft).routing_rules[0].value, 'example.test');
  assert.equal(config.request(owner.configDraft).routing_rules[1].value, '2001:db8::/32');
});

test('luci file transport uses authenticated upload and small rpc reference', async () => {
  const calls = [], posts = [], reads = [];
  let uploadFails = false, envelopeFails = false;
  const rpc = {
    getSessionID: () => 'fixture-session',
    declare: options => (...args) => {
      calls.push({ method: options.method, args, nobatch: options.nobatch });
      return Promise.resolve({ ok: true, result: { saved: true } });
    },
  };
  const request = {
    post: async (url, form) => {
      posts.push({ url, form });
      return {
        ok: !uploadFails,
        json: () => envelopeFails ? { failure: [1, 'Operation not permitted'] } : uploadFails ? { error: 'denied' } : {},
      };
    },
  };
  const localFs = {
    exec_direct: async (...args) => {
      reads.push(args);
      return { ok: true, result: { filename: 'netfleet-backup.json', backup: {} } };
    },
  };
  const L = { env: { rpctimeout: 20, cgi_base: '/cgi-bin' } };
  const window = { crypto: { getRandomValues: value => { value.fill(7); return value; } } };
  const api = new Function('baseclass', 'rpc', 'fs', 'request', 'L', 'window', fs.readFileSync(path.join(RESOURCES, 'api.js'), 'utf8'))(
    baseclass, rpc, localFs, request, L, window,
  );
  const profile = { revision: 'r1', id: 'local.json', content: '{"secret":"sample-private-value"}' };
  await api.profileSave(profile);
  assert.equal(posts[0].url, '/cgi-bin/cgi-upload');
  assert.equal(posts[0].form.get('sessionid'), 'fixture-session');
  assert.match(posts[0].form.get('filename'), /^\/tmp\/opl-netfleet-upload\.[0-9a-f]{32}\.json$/);
  assert.deepEqual(JSON.parse(await posts[0].form.get('filedata').text()), { request: profile });
  assert.deepEqual(calls[0], { method: 'profile_save', args: [{ upload_id: '07'.repeat(16) }], nobatch: true });
  assert(!JSON.stringify(calls).includes('sample-private-value'));
  assert.equal(L.env.rpctimeout, 20);
  const backup = { revision: 'r2', confirm: true, backup: { format: 'netfleet-backup-v1', files: [], sections: [] } };
  await api.backupRestore(backup);
  assert.equal(calls[1].method, 'backup_restore');
  assert.deepEqual(JSON.parse(await posts[1].form.get('filedata').text()), { request: backup });
  await api.profileGet('local.json');
  await api.backupExport();
  assert.deepEqual(reads, [
    ['/usr/libexec/opl-netfleet-transfer', ['profile-get', 'local.json'], 'json'],
    ['/usr/libexec/opl-netfleet-transfer', ['backup-export'], 'json'],
  ]);
  uploadFails = true;
  await assert.rejects(api.profileSave(profile), /transfer_upload_failed/);
  uploadFails = false;
  envelopeFails = true;
  await assert.rejects(api.profileSave(profile), /transfer_upload_failed/);
  assert.equal(calls.length, 2, 'failed upload must not invoke mutation RPC');
  assert.equal(L.env.rpctimeout, 20);
});

test('dashboard updates only the confirmed resource version', async () => {
  let checks = 0;
  const updates = [];
  const initial = { id: 'zashboard', available: true, managed: true, installed_version: null, available_version: null, update_available: false, checked_at: null };
  const candidate = { ...initial, available_version: 'v3.0.0', update_available: true, checked_at: 100 };
  const api = {
    dashboardCheck: async () => { checks++; return clone(candidate); },
    dashboardUpdate: async version => { updates.push(version); return { ...candidate, installed_version: version, update_available: false }; },
    coreAction: async () => { throw new Error('dashboard must not restart core'); },
  };
  const managed = loadModule('managed.js', api);
  const owner = controller();
  owner.componentsSection = 'software';
  owner.components = { dashboard: clone(initial), components: [], dependencies: [], feed: { configured: false } };
  let root = managed.components(owner);
  assert.equal(checks, 0, 'render must not query upstream');
  assert(text(root).includes('版本未记录'));
  assert.equal(button(root, '更新面板'), undefined);
  await fire(button(root, '检查更新'));
  assert.equal(checks, 1);
  root = managed.components(owner);
  fire(button(root, '更新面板'));
  owner.liveDataReady = false;
  await fire(button(modal.content, '确认更新'));
  assert.deepEqual(updates, [], 'a confirmation opened before disconnect must not authorize an update');
  owner.liveDataReady = true;
  fire(button(managed.components(owner), '更新面板'));
  await fire(button(modal.content, '确认更新'));
  assert.deepEqual(updates, ['v3.0.0']);
  assert.equal(owner.components.dashboard.installed_version, 'v3.0.0');
  assert.equal(owner.dashboardBusy, false);
});

test('plugin package confirmation uses owner plan and disabled uninstall', async () => {
  const owner = controller();
  owner.componentsSection = 'plugins';
  const item = { name: 'opl-netfleet-plugin-example', id: 'example', installed_version: null, available_version: '1.2.3', dependencies: [] };
  owner.components = { supported: true, feed: { configured: true }, components: [], extensions: [], plugin_packages: [item] };
  const plan = { names: [item.name, 'missing-helper'], candidates: { [item.name]: '1.2.3', 'missing-helper': '1.0' } };
  let writes = 0, resolvePlan;
  const managed = loadModule('managed.js', {
    componentsPluginPlan: request => { assert.equal(request.confirm, false); return new Promise(resolve => { resolvePlan = resolve; }); },
    componentsPlugin: async request => {
      writes++;
      assert.deepEqual(request.plan, plan);
      assert.equal(request.before_version, null);
      assert.equal(request.action, 'install');
      return { operation: { id: 'install-1', state: 'running' } };
    },
    operationGet: async () => ({ packages: { id: 'install-1', state: 'running' } }),
  });
  const reading = fire(button(managed.components(owner), '安装'));
  assert(button(modal.content, '确认安装').disabled);
  assert.equal(writes, 0);
  resolvePlan(plan);
  await reading;
  assert(text(modal.content).includes('missing-helper'));
  await fire(button(modal.content, '确认安装'));
  assert.equal(writes, 1);
  owner.operations = {};
  item.installed_version = '1.2.3';
  owner.components.extensions = [{ kind: 'plugin', id: 'example', package: item.name, enabled: true }];
  assert(button(managed.components(owner), '卸载').disabled);
  owner.components.extensions[0].enabled = false;
  assert(!button(managed.components(owner), '卸载').disabled);
  owner.liveDataReady = false;
  assert(button(managed.components(owner), '卸载').disabled);
  clearTimeout(owner.operationTimer);
  clearTimeout(owner.resultTimer);
});

test('component first read is pending not unsupported', () => {
  const managed = loadModule('managed.js', {});
  const owner = controller();
  let root = managed.components(owner);
  assert(text(root).includes('正在读取已安装组件'));
  assert(!text(root).includes('未提供组件管理接口'));
  owner.componentsError = new Error('read failed');
  root = managed.components(owner);
  assert(text(root).includes('组件信息未能确认'));
  assert(!text(root).includes('正在读取已安装组件'));
});

test('component checks serialize sources and preserve partial failure', async () => {
  const calls = [];
  const owner = controller();
  owner.componentsSection = 'software';
  const snapshot = { supported: true, components: [], dependencies: [], feed: { configured: true, checked_at: 100 }, dashboard: { managed: true, available: true } };
  owner.components = clone(snapshot);
  const operation = { id: 'check-1', kind: 'packages', subject: 'feed', state: 'running', phase: 'checking', started_at: 100 };
  let releaseDashboard;
  const api = {
    dashboardCheck: () => {
      calls.push('dashboard');
      return new Promise((_, reject) => { releaseDashboard = () => reject(new Error('dashboard_release_check_failed')); });
    },
    componentsCheck: async () => { calls.push('packages'); return { operation }; },
    operationGet: async () => ({ packages: { ...operation, state: 'succeeded', finished_at: 101 } }),
    componentsGet: async () => clone(snapshot),
  };
  const managed = loadModule('managed.js', api);
  let root = managed.components(owner);
  assert.equal(all(root, node => node.tag === 'button' && text(node) === '检查更新').length, 1);
  const pending = fire(button(root, '检查更新'));
  assert.deepEqual(calls, ['dashboard']);
  assert(button(managed.components(owner), '正在检查更新…').disabled);
  releaseDashboard();
  await pending;
  await tick();
  assert.deepEqual(calls, ['dashboard', 'packages']);
  assert(owner.dashboardError);
  root = managed.components(owner);
  assert(text(root).includes('面板：上次检查失败'));
  assert(text(root).includes('软件包源检查'));
  assert(!text(root).includes('已耗时'));
  assert(!button(root, '检查更新').disabled);
  owner.operations = {};
  api.dashboardCheck = async () => ({ managed: true, available: true, checked_at: 100 });
  api.componentsCheck = async () => { throw new Error('feed_check_failed'); };
  await fire(button(managed.components(owner), '检查更新'));
  assert.equal(owner.dashboardError, null);
  assert.equal(owner.components.dashboard.checked_at, 100);
  assert(owner.componentsError);
  clearTimeout(owner.resultTimer);
});

test('regions rank current measurement without pinning the selected region', () => {
  const view = modesModule({});
  const region = (id, selected, measured, historic) => ({
    id, display_name: id, selected, mode: 'automatic', available_count: 1,
    available_provider_count: 1, available_node_count: 1,
    measurement: measured == null ? null : { best_delay_ms: measured, measured_count: 1 },
    last_best_delay_ms: historic, delay_sample_count: 2,
  });
  const status = { regions: [region('Japan', true, 93, 20), region('Singapore', false, 49, 99), region('Old', false, null, 1)] };
  const page = view.regions(status, {});
  const rows = all(page, node => node.tag === 'tr').filter(row => all(row, node => node.tag === 'td').length);
  assert(text(rows[0]).startsWith('Singapore'));
  assert(text(rows[1]).startsWith('Japan'));
  assert.equal(rows[1].attrs.class, 'cbi-rowstyle-1');
  assert(text(rows[2]).startsWith('Old'));
});

test('regions collapse empty directory rows and keep runtime states visible', async () => {
  const view = modesModule({});
  const empty = { id: 'empty', display_name: '空目录地区', mode: 'automatic', available_count: 0, available_provider_count: 0, provider_count: 0, node_count: null };
  const status = {
    active: true,
    runtime: { controller_available: true },
    regions: [
      empty,
      { ...empty, id: 'loaded', display_name: '已有机场地区', provider_count: 4, node_count: 5 },
      { ...empty, id: 'usable', display_name: '节点未知但路径可用地区', available_count: 1, available_provider_count: 1, provider_count: 1 },
      { ...empty, id: 'selected', display_name: '当前使用地区', selected: true },
    ],
  };
  const owner = {};
  const page = view.regions(status, owner);
  const rows = () => all(page, n => n.tag === 'tr').filter(n => all(n, child => child.tag === 'td').length > 1);
  assert.equal(rows().length, 3);
  assert(!text(page).includes('空目录地区'));
  for (const name of ['已有机场地区', '节点未知但路径可用地区', '当前使用地区']) assert(text(page).includes(name));
  const toggle = button(page, '展开暂无资源的地区（1）');
  assert.equal(toggle.attrs['aria-expanded'], 'false');
  await fire(toggle);
  assert.equal(rows().length, 4);
  assert(text(page).includes('空目录地区'));
  assert(text(page).includes('显示 4 个'));
  assert.equal(button(page, '收起暂无资源的地区（1）').attrs['aria-expanded'], 'true');
  await fire(button(page, '收起暂无资源的地区（1）'));
  assert.equal(rows().length, 3);
  assert(text(page).includes('显示 3 个'));
  const search = find(page, n => n.tag === 'input' && n.attrs.type === 'search');
  await fire(search, 'input', { value: '空目录地区' });
  assert.equal(rows().length, 0);
  assert(text(page).includes('可展开查看暂无资源的地区'));
  await fire(button(page, '展开暂无资源的地区（1）'));
  assert.equal(rows().length, 1);
  assert(text(rows()[0]).startsWith('空目录地区'));
  await fire(search, 'input', { value: '已有机场地区' });
  assert.equal(rows().length, 1);
  assert(!button(page, '收起暂无资源的地区（1）'));
  status.active = false;
  assert(text(view.regions(status, {})).includes('空目录地区'));
  status.active = true;
  status.runtime.controller_available = false;
  assert(text(view.regions(status, {})).includes('空目录地区'));
});

test('measurement keeps success quota and candidate diagnostics visible', () => {
  const view = modesModule({});
  const status = {
    providers: [{ id: 'airport', display_name: '示例机场' }],
    regions: [{
      id: 'region', display_name: '示例地区', available_count: 1, available_provider_count: 1,
      measurement: {
        sampled_at: 1788947164, best_delay_ms: 41, measured_count: 1, exclusions: { quota_exhausted: 1 },
        entries: [
          { provider_id: 'airport', region_id: 'region', ok: true, delay_ms: 41, quota_state: 'available' },
          { provider_id: 'other', region_id: 'region', ok: false, quota_state: 'exhausted', measurement_reason: 'leaf_latency_unrecorded' },
        ],
      },
    }],
  };
  const page = view.regions(status, {});
  const content = text(page);
  assert(content.includes('41 ms') && content.includes('1 项测速成功') && content.includes('1 项流量耗尽'));
  assert(content.includes('示例机场') && content.includes('采样于'));
  assert(content.includes('所选节点缺少该测速目标的健康记录'));
  assert(content.includes('流量已耗尽，不参与选优'));
  assert(!content.includes('未通过') && !content.includes('[object HTMLElement]'));
  const details = find(page, node => node.tag === 'details' && text(node).includes('查看测速详情'));
  assert(details && !details.open);
  details.open = true;
  assert(details.open && all(details, node => node.tag === 'li').length === 2);
});

test('measurement current quota precedes stale health and recovers', () => {
  const view = modesModule({});
  const provider = { id: 'airport', display_name: '机场', subscription_section: 'source', quota: { state: 'exhausted' } };
  const entry = { provider_id: 'airport', region_id: 'region', ok: false, quota_state: 'available', measurement_reason: 'group_latency_failed' };
  const status = {
    providers: [provider],
    subscriptions: [{ section: 'source', last_success: 1789000000 }],
    regions: [{ id: 'region', available_count: 1, available_provider_count: 1, measurement: { sampled_at: 1788947164, measured_count: 0, entries: [entry] } }],
  };
  let item = all(view.regions(status, {}), n => n.tag === 'li').find(n => n.children[0]?.tag === 'strong' && text(n.children[0]).startsWith('机场'));
  assert.equal(text(item.children[1]), '流量已耗尽，不参与选优');
  assert(text(item).includes('候选线路测速失败'));
  assert(!text(item).includes('未提供底层错误'));
  // A later quota reset must not present the old exhausted sample as a current ban.
  provider.quota = { state: 'available', remaining_bytes: 1073741824 };
  entry.quota_state = 'exhausted';
  item = all(view.regions(status, {}), n => n.tag === 'li').find(n => n.children[0]?.tag === 'strong' && text(n.children[0]).startsWith('机场'));
  assert(text(item).includes('候选线路测速失败'), 'quota recovery must not invent a successful measurement');
  assert(text(item).includes('该次测速时流量已耗尽'));
  assert(!item.children.some(n => text(n) === '流量已耗尽，不参与选优'));
});

test('subscription selection is one operation feedback', () => {
  const managed = loadModule('managed.js', {});
  const owner = controller();
  owner.operations = {
    subscription: { id: 'subscription-1', state: 'running', phase: 'selecting', started_at: 100, total: 3, completed: 3 },
    selection: { id: 'selection-1', parent_id: 'subscription-1', state: 'running', phase: 'checking', started_at: 110, total: 2, completed: 0 },
  };
  assert(managed.operationNode(owner, 'selection').attrs.hidden);
  const progress = text(managed.operationNode(owner, 'subscription'));
  assert(progress.includes('机场订阅更新') && progress.includes('检查节点健康') && progress.includes('0 / 2 个出口'));
  assert(!progress.includes('检查更新源'));
  owner.operations.selection.state = 'succeeded';
  assert(!text(managed.operationNode(owner, 'subscription')).includes('完成于'));
  owner.operations.subscription.state = 'failed';
  owner.operations.subscription.error = 'protected_probe_failed';
  assert(text(managed.operationNode(owner, 'subscription')).includes('执行失败'));
  assert(managed.operationNode(owner, 'selection').attrs.hidden);
  owner.operations.selection.parent_id = null;
  owner.operations.selection.state = 'running';
  assert(!managed.operationNode(owner, 'selection').attrs.hidden, 'independent selection must remain visible');
  owner.operations.selection.parent_id = 'subscription-old';
  assert(!managed.operationNode(owner, 'selection').attrs.hidden, 'unrelated operation must not be merged');
});

test('operation results dismiss without changing owner or hiding new work', () => {
  const records = new Map();
  globalThis.sessionStorage = { getItem: key => records.get(key), setItem: (key, value) => records.set(key, value) };
  const managed = loadModule('managed.js', {});
  const owner = controller();
  const done = { id: 'operation-1', kind: 'subscription', state: 'succeeded', phase: 'done', started_at: 100, finished_at: 137, updated_at: 137, total: 3, completed: 3, subject: 'private-name' };
  owner.operations = { subscription: { ...done, state: 'running' } };
  managed.operationNode(owner, 'subscription');
  owner.operations = { subscription: clone(done) };
  let root = managed.operationNode(owner, 'subscription');
  assert(text(root).includes('完成于 ' + new Date(137000).toLocaleString()));
  assert(text(root).includes('耗时 37 秒'));
  assert(!text(root).includes('[object HTMLElement]'));
  const close = find(root, node => node.attrs['aria-label'] === '关闭机场订阅更新结果');
  ui.showModal('订阅更新', root);
  close.closest = selector => selector === '#modal_overlay' ? modal : null;
  fire(close);
  assert.equal(modal, null, 'dismissing a finished modal result must not leave an empty dialog');
  assert.deepEqual(owner.operations.subscription, done, 'dismiss never changes the device snapshot');
  assert(managed.operationNode(owner, 'subscription').attrs.hidden);
  const reloaded = controller();
  reloaded.operations = clone(owner.operations);
  assert(managed.operationNode(reloaded, 'subscription').attrs.hidden, 'dismiss survives page reload in the same session');
  assert(!JSON.stringify([...records]).includes('private-name'));
  owner.operations.subscription = { ...done, id: 'operation-2', state: 'running', phase: 'downloading', finished_at: null };
  root = managed.operationNode(owner, 'subscription');
  assert(!root.attrs.hidden);
  assert(!find(root, node => node.attrs['aria-label'] === '关闭机场订阅更新结果'));
  owner.operationError = new Error('disconnected');
  assert(text(managed.operationNode(owner, 'subscription')).includes('执行结果尚未确认'));
  owner.operationError = null;
  owner.operations.subscription = { ...done, id: 'operation-2', state: 'failed', error: 'package_install_failed', recovery: 'failed' };
  root = managed.operationNode(owner, 'subscription');
  assert(text(root).includes('执行失败'));
  assert(text(root).includes('恢复失败'));
  fire(find(root, node => node.attrs['aria-label'] === '关闭机场订阅更新结果'));
  owner.operations.subscription.recovery = 'restored';
  assert(!managed.operationNode(owner, 'subscription').attrs.hidden, 'new recovery evidence must reappear');
  owner.operations.subscription.finished_at = null;
  root = managed.operationNode(owner, 'subscription');
  assert(text(root).includes('记录更新于'));
  assert(!text(root).includes('耗时'));
  managed.notify(null, E('p', {}, '配置已保存'), 'info');
  assert(notifications.at(-1).text.includes('收到反馈'));
});

test('closed component failure keeps current status and diagnostics', () => {
  const managed = loadModule('managed.js', {});
  const owner = controller();
  owner.componentsSection = 'software';
  owner.components = { supported: true, components: [], dependencies: [], feed: { configured: true, checked_at: 102, error: 'feed_check_failed' } };
  owner.operations = { packages: { id: 'feed-1', kind: 'packages', subject: 'feed', state: 'failed', error: 'feed_check_failed', started_at: 100, finished_at: 102 } };
  let root = managed.components(owner);
  assert.equal(all(root, node => node.attrs.class === 'netfleet-result-body').length, 1, 'one visible failure result');
  fire(find(root, node => node.attrs['aria-label'] === '关闭软件包源检查结果'));
  root = managed.components(owner);
  assert.equal(all(root, node => node.attrs.class === 'netfleet-result-body').length, 0);
  assert(text(root).includes('上次检查失败'));
  const detail = find(root, node => node.tag === 'details' && text(node).includes('技术详情'));
  assert(text(detail).includes('更新源检查失败'));
  assert(!detail.open);
  assert(!button(root, '检查更新').disabled, 'dismiss is not a mutation lock');
});

test('components group versions and keep failures actionable', () => {
  const owner = controller();
  owner.componentsSection = 'software';
  const base = { managed: true, update_available: false, reason: null, installed_version: '1.0.0-r1', available_version: '1.0.0-r1' };
  owner.components = {
    supported: true,
    architecture: 'aarch64_generic',
    feed: { configured: true, checked_at: 100, url: 'https://packages.example/netfleet' },
    components: [
      { ...base, id: 'netfleet', label: 'NetFleet' },
      { ...base, id: 'luci', label: 'LuCI 界面' },
      { ...base, id: 'mihomo', label: 'Mihomo', installed_version: '1.19.29', running_version: 'v1.19.30', available_version: '1.19.30-r1', update_available: true },
    ],
    dependencies: [{ label: 'curl', available: false }],
    dashboard: { managed: true, available: true },
  };
  const managed = loadModule('managed.js', {});
  const root = managed.components(owner);
  assert.equal(all(root, node => node.tag === 'tbody')[0].children.length, 4);
  assert(text(root).includes('运行版本与安装记录不一致'));
  assert(text(root).includes('已安装，可使用'));
  assert(!text(root).includes('不适用'));
  assert(!text(root).includes('未提供'));
  assert(!text(root).includes('[object HTMLElement]'));
  const metadata = find(root, node => node.tag === 'dl' && node.attrs.class === 'netfleet-component-meta');
  assert.equal(all(metadata, node => node.tag === 'dt').length, 2);
  assert.equal(all(metadata, node => node.tag === 'dd').length, 2);
  assert(text(metadata).includes('aarch64_generic'));
  assert(text(metadata).includes('https://packages.example/netfleet'));
  assert(find(root, node => node.tag === 'details' && text(node).includes('缺少 1 项')).open);
  fire(button(root, '更新软件包'));
  assert(text(modal.content).includes('当前运行 1.19.30，安装记录 1.19.29'));
  owner.components.components[2].installed_version = '1.19.30-r1';
  assert(!text(managed.components(owner)).includes('运行版本与安装记录不一致'));
  owner.components.components[2].update_available = false;
  owner.components.components[1].installed_version = '0.9.0-r1';
  assert(!text(managed.components(owner)).includes('NetFleet 与 LuCI 安装版本不一致'));
  assert(text(managed.components(owner)).includes('0.9.0-r1'));
  owner.components.components[1].update_available = true;
  owner.components.components[1].available_version = '1.2.0-r1';
  assert(button(managed.components(owner), '更新界面'), 'an older LuCI package must still be updatable with the paired NetFleet package');
  fire(button(managed.components(owner), '更新界面'));
  assert(text(modal.content).includes('LuCI 接入组件 1.2.0'));
  assert(text(modal.content).includes('LuCI 1.2.0-r1'), 'original request identity remains in technical details');
  owner.operations = { packages: { kind: 'packages', state: 'failed', error: 'rollback_runtime_failed', recovery: 'failed', started_at: 100, finished_at: 102 } };
  assert(text(managed.components(owner)).includes('恢复失败'));
  owner.liveDataReady = false;
  assert(button(managed.components(owner), '检查更新').disabled);
});

test('components follow user order and keep plugin actions in scope', () => {
  const owner = controller();
  owner.components = {
    supported: true,
    feed: { configured: true },
    components: [{ id: 'netfleet', label: 'NetFleet', installed_version: '1.0.0' }],
    dependencies: [],
    extensions: [
      {
        id: 'https-compat',
        label: 'HTTPS compatibility',
        presentation: { label: 'HTTPS 兼容', description: '为指定设备和网站提供 HTTPS 协议兼容' },
        product: { required: false, unloadable: true, engine: 'opl-netfleet-https-compat' },
        kind: 'plugin',
        runtime: 'service',
        version: '0.9.2',
        revision: 'r1',
        enabled: true,
      },
      { id: 'custom-plugin', label: 'Custom name', kind: 'plugin', runtime: 'process', version: '1.0.0', revision: 'r2' },
    ],
  };
  const managed = loadModule('managed.js', {});
  let page = managed.components(owner);
  const nav = find(page, node => node.attrs['aria-label'] === '插件与更新分类');
  assert.deepEqual(all(nav, node => node.tag === 'button').map(text), ['基础组件', '功能插件']);
  assert.equal(button(nav, '基础组件').attrs['aria-current'], 'page');
  assert(button(page, '检查更新'));
  assert(text(page).indexOf('NetFleet') < text(page).indexOf('尚未检查更新'));
  assert(!button(page, '运行管理'));
  fire(button(nav, '功能插件'));
  page = managed.components(owner);
  assert(!button(page, '检查更新'), 'plugin package updates use the platform package manager');
  assert(text(page).includes('HTTPS 兼容') && text(page).includes('https-compat') && text(page).includes('为指定设备和网站提供 HTTPS 协议兼容'));
  assert(text(page).includes('Custom name'), 'unknown plugins retain the declared name');
  assert(button(page, '查看状态'));
  assert.deepEqual(all(page, node => node.tag === 'th').map(text), ['插件', '分类与用途', '版本', '配置', '运行管理']);
  assert(!find(page, node => node.tag === 'details' && text(node).includes('编辑服务组合')).open);
});

test('package manager link uses accessible menu route and reads once', async () => {
  const owner = controller();
  owner.componentsSection = 'plugins';
  let menuReads = 0, componentReads = 0;
  const plugin = { id: 'custom', label: 'Custom', kind: 'plugin', version: '1.0.0', revision: 'r1' };
  const snapshot = { supported: true, feed: {}, components: [], dependencies: [], extensions: [plugin] };
  ui.menu = {
    load: async () => {
      menuReads++;
      return {
        children: {
          admin: {
            satisfied: true,
            children: {
              forbidden: { title: 'Restricted', satisfied: false, action: { type: 'view', path: 'system/opkg' } },
              system: { satisfied: true, children: { 'package-manager': { title: 'Software', satisfied: true, action: { type: 'view', path: 'package-manager' } } } },
            },
          },
        },
      };
    },
  };
  const managed = loadModule('managed.js', {
    componentsGet: async () => { componentReads++; return clone(snapshot); },
    pluginRead: async () => ({ loaded: false, revision: 'r1' }),
  });
  await Promise.all([managed.loadComponents(owner), managed.loadComponents(owner)]);
  await managed.loadComponents(owner);
  assert.equal(componentReads, 2);
  assert.equal(menuReads, 1, 'component refresh reuses the current menu');
  let page = managed.components(owner);
  const link = find(page, node => node.tag === 'a' && text(node) === '软件包管理 ↗');
  assert.equal(link.attrs.href, '/cgi-bin/luci/admin/system/package-manager');
  assert(!text(page).includes('此设备未提供软件包管理页面'));
  fire(button(page, '查看状态'));
  await tick();
  assert(!find(modal.content, node => node.tag === 'a'), 'package management stays in the directory, not every runtime dialog');

  ui.menu.load = async () => ({ children: { admin: { children: { hidden: { title: 'Software', satisfied: false, action: { type: 'view', path: 'package-manager' } } } } } });
  const missing = controller();
  missing.componentsSection = 'plugins';
  await managed.loadComponents(missing);
  page = managed.components(missing);
  assert(!find(page, node => node.tag === 'a'), 'an inaccessible menu must not create a guessed link');
  assert(text(page).includes('此设备未提供软件包管理页面'));
  ui.menu.load = async () => { throw new Error('menu unavailable'); };
  const failed = controller();
  failed.componentsSection = 'plugins';
  await managed.loadComponents(failed);
  assert.equal(failed.componentsError, null, 'menu failure does not hide the component inventory');
  assert(!find(managed.components(failed), node => node.tag === 'a'));
});

test('optional component inventory is local readonly and deduplicated', () => {
  const owner = controller();
  owner.componentsSection = 'plugins';
  const extension = {
    id: 'https-compat', label: 'HTTPS 兼容', kind: 'optional', package: 'opl-netfleet-https-compat',
    installed_version: '0.2.0-r1', api_version: 93, compatible: true, available: true, state: 'ready', reason: null,
    dependencies: [{ id: 'mitmproxy', available: true, installed_version: '12.2.3' }], ui: ['config:compatibility'],
  };
  owner.components = {
    supported: true, feed: { configured: false }, components: [], dependencies: [{ id: 'curl', label: 'curl', available: true }],
    extensions: [clone(extension), { ...extension, id: 'zashboard', label: 'Zashboard', kind: 'resource' }],
    dashboard: { available: true, managed: true },
  };
  const managed = loadModule('managed.js', {});
  let root = managed.components(owner);
  assert.deepEqual(all(root, node => node.tag === 'tbody').map(node => node.children.length), [1]);
  assert.equal(all(root, node => node.tag === 'strong' && text(node) === 'Zashboard').length, 0);
  fire(button(root, '基础组件'));
  assert.equal(all(managed.components(owner), node => node.tag === 'strong' && text(node) === 'Zashboard').length, 1);
  fire(button(managed.components(owner), '功能插件'));
  let row = find(root, node => node.tag === 'tr' && text(node).includes('HTTPS 兼容'));
  assert(text(row).includes('0.2.0-r1'));
  assert(text(row).includes('可配置'));
  assert(!text(row).includes('已就绪'));
  assert(!find(row, node => node.tag === 'details').open);
  assert(text(row).includes('mitmproxy：12.2.3'));
  assert(!text(row).includes('93'));
  assert.deepEqual(all(row, node => node.tag === 'button').map(text), [], 'engine payload is managed through its service plugin');
  owner.components.extensions[0] = {
    ...extension, installed_version: null, state: 'not_installed', available: false, reason: 'extension_component_not_installed',
    dependencies: [{ id: 'mitmproxy', available: false, installed_version: null }],
  };
  root = managed.components(owner);
  row = find(root, node => node.tag === 'tr' && text(node).includes('HTTPS 兼容'));
  assert(text(row).includes('未安装'));
  assert(text(row).includes('未安装可选模块'));
  assert(!text(row).includes('extension_component_not_installed'));
  assert(!text(row).includes('mitmproxy'));
  assert(!find(row, node => node.tag === 'details' && text(node).includes('运行依赖')));
  assert.equal(all(row, node => node.attrs.class === 'is-warning').length, 0);
  assert.equal(all(root, node => node.attrs.role === 'alert').length, 0);
  assert(!text(root).includes('运行依赖正常'), 'base dependencies belong to the basic components tab');
  owner.components.extensions[0] = { ...extension, installed_version: null, available: true };
  row = find(managed.components(owner), node => node.tag === 'tr' && text(node).includes('HTTPS 兼容'));
  assert(text(row).includes('安装版本未确认'));
  assert(!text(row).includes('未安装'));
  for (const [state, code, message] of [
    ['incompatible', 'extension_api_incompatible', '模块接口与当前 NetFleet 不兼容'],
    ['dependency_missing', 'extension_dependency_missing', '模块运行依赖缺失'],
    ['unknown', 'extension_manifest_missing', '模块接口声明缺失'],
    ['unknown', 'extension_manifest_invalid', '模块接口声明无效'],
    ['unknown', 'extension_owner_unavailable', '模块状态暂不可读取'],
    ['unknown', 'extension_package_unknown', '模块安装版本尚未确认'],
    ['backend_unsupported', 'extension_backend_unsupported', '当前后端不支持此模块'],
  ]) {
    owner.components.extensions[0] = {
      ...extension, state, reason: code, available: false,
      dependencies: [{ id: 'mitmproxy', available: false, installed_version: null }, { id: 'openssl', available: null, installed_version: null }],
    };
    root = managed.components(owner);
    row = find(root, node => node.tag === 'tr' && text(node).includes('HTTPS 兼容'));
    assert(text(row).includes(message));
    assert(text(row).includes('mitmproxy：缺少'));
    assert(text(row).includes('openssl：未确认'));
    assert(find(row, node => node.tag === 'details' && text(node).includes('mitmproxy')).open);
    assert.equal(all(root, node => node.attrs.role === 'alert').length, 0);
  }
});

test('operating modes use live state revision and read back failures', async () => {
  const calls = [];
  let fail = false;
  const modes = modesModule({
    pluginsList: async () => ({ plugins: [{ id: 'activation', instance: 'default', revision: 'live-r2' }] }),
    pluginCall: async request => { calls.push(request); if (fail) throw new Error('runtime_mode_changed'); },
  });
  const owner = Object.assign(Object.create(modes.controller), controller(), {
    context: { readOnly: false, signal: { aborted: false } },
    status: { operating_mode: 'mihomo', runtime: {} },
  });
  let page = modes.controls(owner);
  assert.equal(all(page, n => n.type === 'radio').length, 3);
  assert.equal(find(page, n => n.type === 'radio' && n.checked).value, 'mihomo');
  assert(button(page, '切换模式').disabled);
  fire(find(page, n => n.value === 'netfleet'), 'change');
  page = modes.controls(owner);
  owner.refreshData = async () => { owner.refreshes++; owner.status.operating_mode = fail ? 'mihomo' : 'netfleet'; };
  await fire(button(page, '切换模式'));
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0], {
    id: 'activation', instance: 'default', action: 'set-mode', revision: 'live-r2', confirm: true,
    params: { mode: 'netfleet', expected_mode: 'mihomo' },
  });
  assert.equal(owner.refreshes, 1);
  assert.equal(owner.busy, false);
  assert(notifications.at(-1).text.includes('NetFleet 增强代理'));
  fail = true;
  await owner.runMode('openwrt', 'netfleet');
  assert.equal(owner.refreshes, 2, 'failed mutations must read current owner state');
  assert(notifications.at(-1).text.includes('Mihomo 原生代理'));
  assert.equal(notifications.at(-1).severity, 'warning');
  owner.liveDataReady = false;
  owner.modeDraft = 'openwrt';
  assert(button(modes.controls(owner), '切换模式').disabled);
  await owner.runMode('openwrt', 'mihomo');
  assert.equal(calls.length, 2, 'cached state cannot authorize a mode change');
  owner.liveDataReady = true;
  owner.context.readOnly = true;
  await owner.runMode('openwrt', 'mihomo');
  assert.equal(calls.length, 2, 'read-only view cannot mutate');
  assert(text(modes.summary({ operating_mode: null, runtime: {} })).includes('状态未确认'));
  assert(!text(modes.summary({ operating_mode: 'mihomo', runtime: { mihomo_running: true } })).includes('已关闭'));
  const runtime = {
    backend_enabled: true, mihomo_running: true, controller_available: true,
    lan_runtime: { lan_proxy_enabled: false, dns_hijack_enabled: false, transparent_proxy_ready: true, dns_ready: true, dashboard_lan_ready: true },
  };
  let summary = text(modes.summary({ runtime }));
  assert(summary.includes('LAN 透明代理未启用') && summary.includes('DNS 接管未启用'), 'readiness does not imply enabled interception');
  runtime.lan_runtime.lan_proxy_enabled = true;
  runtime.lan_runtime.dns_hijack_enabled = true;
  runtime.lan_runtime.dns_ready = false;
  summary = text(modes.summary({ runtime }));
  assert(summary.includes('LAN 透明代理已启用 · 正常') && summary.includes('DNS 接管已启用 · 异常'));
  assert(summary.includes('控制接口正常') && !summary.includes('可读取'));
  delete runtime.lan_runtime.lan_proxy_enabled;
  assert(text(modes.summary({ runtime })).includes('LAN 透明代理状态未确认'));
  runtime.backend_enabled = false;
  runtime.mihomo_running = false;
  summary = text(modes.summary({ runtime }));
  assert(summary.includes('DNS 接管未启用') && summary.includes('控制接口未运行'));
  const direct = { data_path: 'passthrough', alive: true, user_mode: 'native_profile' };
  assert.equal(modes.health(direct), '已直连');
  assert.equal(modes.region({}, direct), '直连');
  assert.equal(modes.mode(direct), '原生直连');
});

test('cached page starts live read without waiting for setup check', async () => {
  let resolveSetup, resolveStatus, resolveEvents;
  const calls = [];
  globalThis.window = {
    localStorage: {
      getItem: () => JSON.stringify({ schema: 1, status: { active: true }, events: { events: [] }, fetched_at_ms: 1 }),
      removeItem: () => {},
    },
  };
  const modes = modesModule({
    onboardingGet: () => { calls.push('setup'); return new Promise(resolve => { resolveSetup = resolve; }); },
    status: () => { calls.push('status'); return new Promise(resolve => { resolveStatus = resolve; }); },
    events: () => { calls.push('events'); return new Promise(resolve => { resolveEvents = resolve; }); },
    nativeSetupGet: async () => ({ available: true }),
  });
  const owner = Object.create(modes.controller);
  owner.pageId = 'overview';
  let rendered = false;
  const loaded = owner.load().then(result => { rendered = true; return result; });
  assert.deepEqual(calls, ['status', 'events', 'setup']);
  assert.equal(rendered, false, 'setup remains authoritative even when a display cache exists');
  resolveSetup({ required: true });
  const initial = await loaded;
  assert.equal(initial.onboarding.required, true);
  assert.equal(initial.status, undefined, 'a removed configuration must not render old active status');
  resolveStatus({ active: false });
  resolveEvents({ events: [] });
  await owner.initialRefresh;
});

test('status display does not wait for events and late events respect scope', async () => {
  let resolveEvents;
  globalThis.window = { localStorage: { getItem: () => null, removeItem() {}, setItem() {} } };
  const modes = modesModule({
    onboardingGet: async () => ({ required: false }),
    status: async () => ({ active: true }),
    events: () => new Promise(resolve => { resolveEvents = resolve; }),
  });
  const owner = Object.create(modes.controller);
  owner.pageId = 'overview';
  owner.context = { signal: { aborted: false } };
  let initial;
  owner.load().then(value => { initial = value; });
  await tick();
  assert(initial && initial.status.active, 'first live status must render before a slow event response');
  assert(owner.eventsLoading, 'pending events retain an explicit loading state');
  const inFlight = owner.eventsRead;
  assert.strictEqual(owner.refreshEvents(), inFlight, 'concurrent event refreshes share one read');
  owner.context.signal.aborted = true;
  resolveEvents({ events: [{ id: 'late-event' }] });
  await inFlight;
  assert.equal(owner.events, undefined, 'disposed page cannot accept a late event response');
});

test('event error does not invalidate successful live status', async () => {
  globalThis.window = { localStorage: { getItem: () => null, removeItem() {}, setItem() {} } };
  const modes = modesModule({
    onboardingGet: async () => ({ required: false }),
    status: async () => ({ active: true }),
    events: async () => { throw new Error('event timeout'); },
  });
  const owner = Object.create(modes.controller);
  owner.pageId = 'overview';
  const initial = await owner.load();
  await tick();
  assert.equal(initial.cached, false);
  assert.equal(initial.status.active, true);
  assert.equal(owner.eventsError.message, 'event timeout');
  assert.equal(owner.refreshError, undefined, 'event failure is separate from current runtime status');
});

test('mode progress survives rpc disconnect and new page scope', async () => {
  let operation = { id: 'older-mode', kind: 'mode', state: 'failed', phase: 'checking_mode', started_at: 1, updated_at: 2 };
  let release;
  const accepted = new Promise(resolve => { release = resolve; });
  const modes = modesModule({
    operationGet: async () => ({ mode: clone(operation) }),
    pluginsList: async () => ({ plugins: [{ id: 'activation', revision: 'live-mode-r1' }] }),
    pluginCall: async () => {
      operation = {
        id: 'mode-current', kind: 'mode', state: 'running', phase: 'resetting_candidates',
        started_at: Date.now() / 1000 - 15, updated_at: Date.now() / 1000, total: 2, completed: 0,
        subject: 'standard', requested_mode: 'netfleet', actual_mode: null,
      };
      await accepted;
      const error = new Error('XHR request aborted by browser');
      error.netfleetKind = 'request_aborted';
      throw error;
    },
  });
  const owner = Object.assign(Object.create(modes.controller), controller(), {
    context: { readOnly: false, signal: { aborted: false } },
    operations: { mode: clone(operation) },
    status: { operating_mode: 'mihomo', capabilities: [{ id: 'standard', display_name: '常规出口' }], runtime: {} },
  });
  Object.defineProperty(owner, 'busy', { get() { return modes.progress.operationBusy(this); } });
  const request = owner.runMode('netfleet', 'mihomo');
  await tick();
  await modes.progress.readOperations(owner);
  assert.equal(modal, null, 'mode switching must not block the page with a modal');
  assert(owner.busy, 'pending owner mutation still disables conflicting writes');
  assert.equal(owner.status.operating_mode, 'mihomo', 'request target is not an effective-mode readback');
  const active = text(modes.progress.operationNode(owner, 'mode'));
  assert(active.includes('初始化候选出口'));
  assert(active.includes('出口：常规出口'));
  assert(active.includes('已完成 0 / 2 个候选组'));
  assert(active.includes('已耗时 15 秒'));
  assert(active.includes('可继续浏览'));
  assert(!active.includes('%'));
  release();
  await request;
  assert(owner.busy && owner.operationTimer, 'RPC disconnect must retain polling while the device operation runs');
  operation = {
    ...operation, state: 'failed', phase: 'rolling_back', finished_at: Date.now() / 1000,
    error: 'candidate_group_reset_failed', actual_mode: 'mihomo', recovery: 'native',
  };
  await modes.progress.readOperations(owner);
  await tick();
  const failed = text(modes.progress.operationNode(owner, 'mode'));
  assert(failed.includes('执行失败'));
  assert(failed.includes('候选出口初始化失败'));
  assert(failed.includes('已恢复 Mihomo 原生代理'));
  assert(failed.includes('完成时确认：Mihomo 原生代理'));
  assert.equal(owner.busy, false);
  assert.equal(owner.refreshes, 2, 'owner terminal transition refreshes actual status after the disconnected response');
  const reopened = Object.assign(controller(), { context: { signal: { aborted: false } } });
  await modes.progress.readOperations(reopened);
  assert(text(modes.progress.operationNode(reopened, 'mode')).includes('已恢复 Mihomo 原生代理'), 'new page scope reads the same persistent failure');
  clearTimeout(owner.operationTimer);
  clearTimeout(owner.resultTimer);
  clearTimeout(reopened.resultTimer);
});

test('region choice uses capability authority and live readback', async () => {
  const calls = [];
  const modes = modesModule(
    { selectRegion: async (...args) => { calls.push(args); return { selected: 'sg' }; } },
    async (owner, request) => { owner.busy = true; try { await request(); await owner.refreshData(); } finally { owner.busy = false; } },
  );
  const owner = controller();
  Object.assign(owner, modes.controller);
  owner.redraw = () => {};
  owner.context = { readOnly: false };
  owner.status = {
    runtime: {},
    regions: [{ id: 'jp', display_name: '日本' }, { id: 'sg', display_name: '新加坡' }],
    capabilities: [
      { id: 'standard', display_name: '常规出口', enabled: true, can_select_region: true, selectable_regions: ['jp', 'sg'], region_id: 'jp' },
      { id: 'ai', display_name: 'AI 出口', enabled: true, can_select_region: true, selectable_regions: ['jp'], region_id: 'jp' },
    ],
  };
  owner.refreshData = async () => { owner.refreshes++; owner.status.capabilities[0].user_mode = 'manual_region'; };
  owner.chooseRegion(null, 'sg');
  assert.equal(modal.title, '指定地区');
  assert.deepEqual(all(modal.content, n => n.tag === 'select')[0].children.map(n => n.attrs.value), ['standard']);
  assert(text(modal.content).includes('整轮后台自动选优暂停'));
  await fire(button(modal.content, '确认切换'));
  assert.deepEqual(calls, [['standard', 'sg']]);
  assert.equal(owner.refreshes, 1);
  assert.equal(owner.status.capabilities[0].user_mode, 'manual_region');
  owner.chooseRegion('standard');
  owner.liveDataReady = false;
  await fire(button(modal.content, '确认切换'));
  assert.equal(calls.length, 1, 'freshness lost after opening modal must reject submission');
  modal = null;
  owner.chooseRegion('standard');
  assert.equal(modal, null, 'cached read cannot open a mutation');
  owner.liveDataReady = true;
  owner.context.readOnly = true;
  owner.chooseRegion('standard');
  assert.equal(modal, null);
});

test('dynamic plugin management uses current identity and confirmation', async () => {
  const calls = [];
  const plugin = {
    id: 'device-info', label: '设备信息', kind: 'plugin', runtime: 'process', version: '1.0.0-r2', revision: 'r1',
    package: 'opl-netfleet-plugin-device-info', actions: { inspect: 'read', reset: 'write' },
  };
  const owner = controller();
  owner.componentsSection = 'plugins';
  owner.components = { supported: true, feed: {}, components: [], dependencies: [], extensions: [plugin] };
  const managed = loadModule('managed.js', {
    pluginRead: async request => { calls.push(['read', request]); return { loaded: calls.some(c => c[0] === 'write'), ready: true, revision: 'r2' }; },
    pluginCall: async request => { calls.push(['write', request]); return { loaded: true, ready: true, revision: 'r3' }; },
    componentsGet: async () => owner.components,
  });
  let page = managed.components(owner);
  assert.equal(calls.length, 0, 'inventory never starts or calls a plugin');
  assert(text(page).includes('device-info') && text(page).includes('进程插件'));
  assert.equal(text(find(page, n => n.tag === 'td' && text(n).startsWith('1.0.0')).children[0]), '1.0.0');
  fire(button(page, '查看状态'));
  await tick();
  assert.equal(calls[0][1].action, 'get');
  assert(!find(modal.content, n => n.tag === 'select' || n.tag === 'textarea'), 'no raw RPC editor');
  assert(button(modal.content, '重新启动').disabled);
  fire(button(modal.content, '启用'));
  assert.equal(modal.title, '确认启用');
  assert.equal(calls.length, 1, 'write waits for confirmation');
  fire(button(modal.content, '确认'));
  await tick();
  assert.equal(calls[1][0], 'write');
  assert.equal(calls[1][1].revision, 'r2', 'writes use fresh owner revision');
  assert.equal(calls[1][1].confirm, true);
  assert(text(modal.content).includes('运行就绪'));
  assert(button(modal.content, '启用').disabled);
  assert(!button(modal.content, '重新启动').disabled);
  assert.equal(calls.at(-1)[1].action, 'load', 'host-confirmed lifecycle result avoids a redundant read');
  assert(text(modal.content).includes('完整版本：1.0.0-r2'));

  const service = {
    ...plugin, id: 'activation', label: 'Activation',
    presentation: { label: '网络启停', description: '切换运行模式，应用或退出代理接管' },
    product: { required: true, unloadable: true }, runtime: 'service', instance: 'review', revision: 'service-r1',
    actions: { 'get-mode': 'read', 'set-mode': 'write' },
  };
  owner.components.extensions = [service];
  const opened = [];
  owner.context = { navigate: id => opened.push(id) };
  page = managed.components(owner);
  fire(button(page, '查看状态'));
  await tick();
  assert.equal(calls.at(-1)[1].instance, 'review');
  assert(!find(modal.content, n => n.tag === 'select' || n.tag === 'textarea'));
  assert(button(modal.content, '启用') && button(modal.content, '禁用') && !button(modal.content, '重新启动'), 'service enable/disable uses host lifecycle');
  assert(text(modal.content).includes('开关由 NetFleet 宿主管理'));
  fire(button(modal.content, '前往概览切换运行模式'));
  assert.deepEqual(opened, ['plugin:product-ui:overview']);
});

test('service switch reads identity and preserves state on dependency failure', async () => {
  const owner = controller();
  owner.componentsSection = 'plugins';
  const plugin = { id: 'sample', label: '示例', kind: 'plugin', runtime: 'service', enabled: true, version: '1.0.0', revision: 'stale', instance: 'review' };
  owner.components = { supported: true, feed: {}, components: [], extensions: [plugin] };
  const calls = [];
  let readFailure = false;
  const managed = loadModule('managed.js', {
    pluginRead: async request => { calls.push(['read', request]); if (readFailure) throw Error('offline'); return { loaded: true, ready: true, revision: 'fresh' }; },
    pluginCall: async request => { calls.push(['write', request]); throw Error('plugin_required_by:consumer'); },
    componentsGet: async () => owner.components,
  });
  await fire(button(managed.components(owner), '禁用'));
  assert.equal(modal.title, '确认禁用');
  assert.equal(calls.length, 1, 'reading does not disable the service');
  assert(text(modal.content).includes('保留软件包和配置'));
  await fire(button(modal.content, '确认'));
  await tick();
  assert.equal(calls[1][1].revision, 'fresh');
  assert.equal(calls[1][1].instance, 'review');
  assert.equal(calls[1][1].action, 'unload');
  assert.equal(plugin.enabled, true, 'dependency rejection cannot optimistically mark disabled');
  assert(text(modal.content).includes('其他已启用插件仍依赖此插件') && text(modal.content).includes('consumer'));
  assert(text(modal.content).includes('未禁用'));
  assert(!button(modal.content, '禁用').disabled, 'automatic readback restores controls without a manual refresh');
  await fire(button(modal.content, '刷新状态'));
  assert(!button(modal.content, '禁用').disabled);
  readFailure = true;
  await fire(button(modal.content, '刷新状态'));
  assert(button(modal.content, '禁用').disabled, 'a failed refresh invalidates the previous state');
  assert(!button(managed.components(owner), '读取状态'));
  await fire(button(managed.components(owner), '查看状态'));
  assert.notEqual(modal.title, '确认禁用');
  assert(button(modal.content, '禁用').disabled);
  assert.equal(calls.filter(c => c[0] === 'write').length, 1, 'failed reads never mutate or retry');
  plugin.id = 'product-ui';
  plugin.product = { required: true, unloadable: false };
  plugin.enabled = true;
  assert(button(managed.components(owner), '禁用').disabled, 'the management page retains a visible protected control');
  assert(text(managed.components(owner)).includes('不可禁用：管理界面必需'));
});

test('plugin switch terminal result and process inventory', async () => {
  const owner = controller();
  owner.componentsSection = 'plugins';
  const plugin = { id: 'device-identity', kind: 'plugin', runtime: 'process', revision: 'r1', enabled: null };
  owner.components = { supported: true, feed: {}, components: [], extensions: [plugin] };
  let loaded = true, failed = false, unavailable = false;
  const calls = [];
  const managed = loadModule('managed.js', {
    componentsGet: async () => owner.components,
    pluginRead: async request => { calls.push(request); if (unavailable) throw Error('offline'); return { loaded, ready: loaded, revision: 'r1' }; },
    pluginCall: async request => { if (failed) throw Error('healthy_connections_still_draining'); loaded = request.action === 'load'; return { loaded, ready: loaded, revision: 'r1' }; },
  });
  assert(text(managed.components(owner)).includes('状态未确认'));
  assert(!button(managed.components(owner), '启用 / 禁用'));
  await managed.loadComponents(owner);
  assert(button(managed.components(owner), '禁用'));
  await fire(button(managed.components(owner), '禁用'));
  await fire(button(modal.content, '确认'));
  await tick();
  assert(text(modal.content).includes('已禁用'));
  assert(button(managed.components(owner), '启用'));
  plugin.runtime = 'service';
  plugin.state = 'unavailable';
  plugin.reason = 'plugin_disabled';
  await fire(button(managed.components(owner), '启用'));
  await fire(button(modal.content, '确认'));
  await tick();
  assert(!text(managed.components(owner)).includes('异常'), 'enabling clears the obsolete disabled reason');
  loaded = true;
  plugin.enabled = true;
  failed = true;
  await fire(button(managed.components(owner), '禁用'));
  await fire(button(modal.content, '确认'));
  await tick();
  assert(text(modal.content).includes('未禁用'));
  assert(text(modal.content).includes('现有连接仍在传输'));
  assert(button(managed.components(owner), '禁用'));
  await fire(button(managed.components(owner), '禁用'));
  unavailable = true;
  await fire(button(modal.content, '确认'));
  await tick();
  assert(text(modal.content).includes('结果未确认'));
  assert(text(managed.components(owner)).includes('状态未确认'));
  assert(button(modal.content, '禁用').disabled);
});

test('plugin state busy read is bounded and instance scoped', async () => {
  const realSetTimeout = globalThis.setTimeout;
  const retryDelays = [];
  globalThis.setTimeout = (fn, ms, ...args) => {
    retryDelays.push(ms);
    queueMicrotask(() => fn(...args));
    return 0;
  };
  try {
    const owner = controller();
    owner.componentsSection = 'plugins';
    const plugin = { id: 'device-identity', kind: 'plugin', runtime: 'process', revision: 'r1', instance: 'review', enabled: null };
    owner.components = { supported: true, feed: {}, components: [], extensions: [plugin] };
    let attempts = 0, busy = 2;
    const managed = loadModule('managed.js', {
      componentsGet: async () => owner.components,
      pluginRead: async request => {
        attempts++;
        assert.equal(request.instance, 'review');
        if (busy-- > 0) throw Error('mutation_busy');
        return { loaded: false, ready: false, revision: 'r1' };
      },
      pluginCall: async () => { throw Error('reads must never write'); },
    });
    await managed.loadComponents(owner);
    assert.equal(attempts, 3);
    assert.equal(plugin.enabled, false, 'brief contention resolves without manual state recovery');
    assert(button(managed.components(owner), '启用'));
    attempts = 0;
    busy = 9;
    await managed.loadComponents(owner);
    assert.equal(attempts, 3, 'persistent contention is bounded');
    assert.equal(plugin.enabled, null, 'failed fresh reads must not retain a stale toggle');
    const page = managed.components(owner);
    assert.equal(all(page, n => n.tag === 'button' && text(n) === '查看状态').length, 1);
    assert(!button(page, '读取状态'));
    assert(!button(page, '启用') && !button(page, '禁用'));
    assert(text(page).includes('暂时无法读取'));
    attempts = 0;
    busy = 0;
    await fire(button(page, '查看状态'));
    await tick();
    assert.equal(attempts, 1);
    assert.equal(plugin.enabled, false);
    assert(!text(managed.components(owner)).includes('暂时无法读取'));
    assert(!button(modal.content, '启用').hidden && button(modal.content, '禁用').hidden);
    assert.deepEqual(retryDelays, [200, 600, 200, 600]);
  } finally {
    globalThis.setTimeout = realSetTimeout;
  }
});

test('https service exposes configuration without loading engine', () => {
  const owner = controller();
  owner.componentsSection = 'plugins';
  const opened = [];
  owner.context = { navigate: id => opened.push(id) };
  const plugin = {
    id: 'https-compat', label: 'HTTPS compatibility',
    presentation: { label: 'HTTPS 兼容', description: '为指定设备和网站提供 HTTPS 协议兼容' },
    product: { required: false, unloadable: true, engine: 'opl-netfleet-https-compat' },
    kind: 'plugin', runtime: 'service', version: '0.8.0', revision: 'https-r1', enabled: true,
    configuration: { read: 'config-get', write: 'config-set' },
    ui: [{ id: 'settings', title: 'HTTPS 兼容', module: 'resources/page.js' }],
  };
  owner.components = { supported: true, feed: {}, components: [], dependencies: [], extensions: [plugin] };
  const managed = loadModule('managed.js', {});
  let page = managed.components(owner);
  fire(button(page, '配置'));
  assert.deepEqual(opened, ['plugin:https-compat:settings']);
  assert(button(page, '查看状态'));
  assert(text(page).includes('运行管理'));
  assert(text(page).includes('已加载 · 未就绪'), 'service plugin request and engine readiness are shown separately');
  assert(!text(page).includes('运行中'));
  plugin.enabled = false;
  page = managed.components(owner);
  assert(button(page, '配置').disabled, 'disabled management plugin must not be loaded by opening its configuration');
  assert(!button(page, '查看状态').disabled);
  plugin.id = 'another-plugin';
  plugin.enabled = true;
  fire(button(managed.components(owner), '配置'));
  assert.equal(opened.at(-1), 'plugin:another-plugin:settings', 'configuration navigation is manifest-driven');
});

test('composition preview binds edits and confirmation', async () => {
  const owner = controller();
  const calls = [];
  owner.componentsSection = 'plugins';
  owner.components = { supported: true, feed: {}, components: [], dependencies: [], extensions: [] };
  const managed = loadModule('managed.js', {
    systemGet: async () => ({
      revision: 'current',
      config: { schema: 'opl-netfleet-system.v1', bindings: {}, enabled: {} },
      defaults: { enabled: { note: true }, bindings: { 'note.store': 'note' } },
      plugins: [{ id: 'note', services: [{ name: 'note.store', version: 1 }] }],
    }),
    systemValidate: async value => { calls.push(['validate', value]); return { valid: true, affected_plugins: ['note'] }; },
    systemApply: async value => { calls.push(['apply', value]); return { applied: true }; },
    componentsGet: async () => owner.components,
  });
  fire(button(managed.components(owner), '编辑服务组合'));
  await tick();
  const editor = find(modal.content, node => node.tag === 'textarea');
  assert(button(modal.content, '应用组合').disabled);
  const enabled = find(modal.content, node => node.attrs?.['aria-label'] === '插件开关 note');
  fire(enabled, 'change', { value: 'false' });
  assert.equal(JSON.parse(editor.value).enabled.note, false);
  fire(find(modal.content, node => node.attrs?.['aria-label'] === '插件开关 note'), 'change', { value: '' });
  assert.equal(JSON.parse(editor.value).enabled.note, undefined, 'inherit removes the override');
  fire(button(modal.content, '校验并预览影响'));
  await tick();
  assert.equal(calls.length, 1);
  assert(text(modal.content).includes('note'));
  editor.value = JSON.stringify({ schema: 'opl-netfleet-system.v1', bindings: {}, enabled: { note: true } });
  fire(button(modal.content, '应用组合'));
  await tick();
  assert.equal(calls.length, 1, 'editing invalidates the old preview even without an input event');
  fire(button(modal.content, '校验并预览影响'));
  await tick();
  fire(button(modal.content, '应用组合'));
  await tick();
  assert.deepEqual(calls.at(-1), ['apply', { revision: 'current', config: JSON.parse(editor.value), confirm: true }]);
  fire(button(modal.content, '关闭'));
  assert.equal(editor.value, '', 'closing clears private configuration');
  owner.context = { readOnly: true };
  assert(button(managed.components(owner), '编辑服务组合').disabled);
});

test('product factories share fetches but keep page guards', async () => {
  globalThis.L = { require: async () => ({}) };
  let fetches = 0, fail = false;
  globalThis.fetch = async url => {
    fetches++;
    if (fail) return { ok: false };
    const name = path.basename(url.pathname);
    const source = name === 'api.js' ? 'return { status: async () => "ok", configSave: async () => "saved" };'
      : name === 'product-pages.js' ? 'return { mount: (ctx, id) => ({ id, api: api }) };' : 'return {};';
    return { ok: true, text: async () => source };
  };
  const source = fs.readFileSync(path.join(RESOURCES, 'entry.js'), 'utf8').replaceAll(
    'import.meta.url', JSON.stringify('file://' + path.join(RESOURCES, 'entry.js')),
  );
  const entry = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
  const first = new AbortController(), second = new AbortController();
  const [a, b] = await Promise.all([
    entry.mountPage({ signal: first.signal, readOnly: false }, 'overview'),
    entry.mountPage({ signal: second.signal, readOnly: true }, 'config'),
  ]);
  assert.equal(fetches, 8, 'parallel pages share resource loading without optional plugin assets');
  assert.notEqual(a.api, b.api, 'each mount has its own permission guard');
  assert.equal(await a.api.configSave(), 'saved');
  await assert.rejects(b.api.configSave(), /plugin_read_only/);
  first.abort();
  await assert.rejects(a.api.status(), /plugin_scope_disposed/);
  assert.equal(await b.api.status(), 'ok');
  await entry.mountPage({ signal: second.signal, readOnly: false }, 'events');
  assert.equal(fetches, 8, 'navigation does not fetch or compile the same revision again');
  const retry = await import('data:text/javascript;base64,' + Buffer.from(source + '\n// different revision').toString('base64'));
  fail = true;
  await assert.rejects(retry.mountPage({ signal: second.signal }, 'overview'), /product_ui_resource_unavailable/);
  fail = false;
  assert.equal((await retry.mountPage({ signal: second.signal }, 'overview')).id, 'overview');
  assert.equal(fetches, 18, 'only failed required factories are retried');
});

test('refresh coalesces and stronger read observes again', async () => {
  const pending = [], calls = [];
  const modes = modesModule({
    status: () => { calls.push('status'); return new Promise(resolve => pending.push(resolve)); },
    configGet: async () => { calls.push('config'); return { revision: 'new' }; },
  });
  const owner = Object.assign(Object.create(modes.controller), {
    currentView: 'config', context: { signal: { aborted: false } }, redraw() {},
    acceptLiveData(result) { this.status = result[0]; this.config = result[2]; },
  });
  const first = owner.refreshData(true);
  assert.strictEqual(owner.refreshData(true), first);
  const stronger = owner.refreshData(true, true);
  assert.deepEqual(calls, ['status']);
  pending.shift()({ generation: 1 });
  await first;
  await tick();
  assert.deepEqual(calls, ['status', 'status', 'config']);
  pending.shift()({ generation: 2 });
  await stronger;
  assert.equal(owner.status.generation, 2);
  assert.equal(owner.config.revision, 'new');
});

test('mutation invalidates old reads and disposed page ignores errors', async () => {
  const pending = [];
  const modes = modesModule({ status: () => new Promise((resolve, reject) => pending.push({ resolve, reject })) });
  const owner = Object.assign(Object.create(modes.controller), {
    currentView: 'config', context: { signal: { aborted: false } }, redraw() {},
    acceptLiveData(result) { this.status = result[0]; },
  });
  const old = owner.refreshData(true);
  owner.invalidateReads();
  const fresh = owner.refreshData(true);
  pending.shift().resolve({ generation: 1 });
  await old;
  await tick();
  assert.equal(owner.status, undefined, 'read started before mutation cannot be published');
  pending.shift().resolve({ generation: 2 });
  await fresh;
  assert.equal(owner.status.generation, 2);
  const late = owner.refreshData(true);
  owner.context.signal.aborted = true;
  pending.shift().reject(new Error('late transport failure'));
  await late;
  assert.equal(owner.refreshError, undefined);
});

test('only event consumers read events and core requests logs', async () => {
  const calls = [];
  globalThis.window = { localStorage: { getItem: () => null, removeItem() {}, setItem() {} } };
  const modes = modesModule({
    onboardingGet: async () => ({ required: false }),
    status: async () => ({ active: true }),
    events: async logs => { calls.push(logs); return { events: [] }; },
  });
  const owner = Object.assign(Object.create(modes.controller), { pageId: 'config', context: { signal: { aborted: false } } });
  await owner.load();
  assert.deepEqual(calls, []);
  owner.currentView = 'events';
  owner.diagnosticSection = 'events';
  await owner.refreshEvents();
  owner.diagnosticSection = 'core';
  await owner.refreshEvents();
  assert.deepEqual(calls, [false, true]);
});

test('http2 website defaults preserve scope and dynamic binding', async () => {
  const owner = controller();
  owner.compatibility = {
    installed: true, requested: true, intercepting: true, revision: 'compat-r1',
    config: { rules: [], devices: [{ id: 'egress', name: 'Shared egress', addresses: ['192.0.2.2'] }] },
    rules: {}, trust: {}, events: [],
  };
  const writes = [];
  const manager = loadModule('compatibility.js', {
    compatibilityGet: async () => clone(owner.compatibility),
    compatibilityApply: async request => { writes.push(request); owner.compatibility.config = clone(request.config); },
    pluginRead: () => { throw Error('must not read another plugin'); },
    pluginCall: () => { throw Error('must not manage another plugin'); },
  });
  let root = manager.render(owner);
  assert(!text(root).includes('目标恢复'));
  assert(!text(root).includes('自动发现'));
  assert(!text(root).includes('转发引擎'), 'diagnostics are not generated until expanded');
  fire(button(root, '添加网站'));
  const field = label => find(find(modal.content, node => node.tag === 'label' && text(node).startsWith(label)), node => node.tag === 'input');
  fire(field('网站域名'), 'input', { value: 'Service.Example' });
  await fire(button(modal.content, '保存'));
  assert.equal(writes.length, 1, 'save needs no second confirmation');
  assert.deepEqual(
    { ...writes[0].config.rules[0], id: 'generated' },
    { id: 'generated', name: 'service.example', domain: 'service.example', match: 'exact', port: 443, strategy: 'h2', enabled: true, devices: ['egress'] },
  );
  owner.compatibility.rule_recovery = { [owner.compatibility.config.rules[0].id]: { admitted: true } };
  root = manager.render(owner);
  assert(text(root).includes('等待请求验证 HTTP/2'));
  owner.compatibility.config.devices.push({ id: 'other', name: 'Other', addresses: ['192.0.2.3'] });
  fire(button(manager.render(owner), '添加网站'));
  fire(field('网站域名'), 'input', { value: 'another.example' });
  await fire(button(modal.content, '保存'));
  assert.equal(writes.length, 1, 'multiple scopes require an explicit selection');
  assert(text(notifications.at(-1).text).includes('请选择接入范围'));
  ui.hideModal();
  owner.compatibility.config.devices[0].identity = { binding: 'a'.repeat(64), mac: '02:00:00:00:00:01' };
  owner.compatibility.config.devices[0].addresses = [];
  owner.accessExpanded = true;
  fire(button(manager.render(owner), '编辑范围'));
  await fire(button(modal.content, '保存'));
  assert.deepEqual(writes.at(-1).config.devices[0].identity, { binding: 'a'.repeat(64), mac: '02:00:00:00:00:01' });
  root = manager.render(owner);
  fire(button(root, '删除'));
  assert(modal, 'deletion still explains its effect');
  owner.compatibilityLive = false;
  await fire(button(modal.content, '删除'));
  assert.equal(writes.length, 2, 'a stale confirmation cannot authorize a write');
});

test('compatibility retains failure when current probes pass', () => {
  const owner = controller();
  owner.diagnosticsExpanded = true;
  owner.compatibility = {
    installed: true, requested: true, intercepting: false, reason: 'manual_recovery_required',
    config: { rules: [], devices: [] }, recovery: { latched: true, faults: [1] }, engine_restart: { attempts: 4 },
    local_probes: { processing: { ok: true, duration_ms: 200, stage: 'http' } },
    last_failure: {
      at: 42, reason: 'processing_chain_failed', health_error: 'health_socket_timeout',
      local_probes: { processing: { ok: false, reason: 'timeout', stage: 'http', duration_ms: 1510, timeout_ms: 1400 } },
    },
  };
  const manager = loadModule('compatibility.js', {});
  let root = manager.render(owner);
  assert(text(root).includes('本地健康接口超时'));
  assert(text(root).includes('1510 ms / 1400 ms'));
  assert(text(root).includes('1 次独立故障'));
  assert(text(root).includes('4 次'));
  assert(button(root, '恢复转发'));
  owner.compatibility.reason = 'maintenance';
  owner.compatibility.recovery.latched = false;
  assert(button(manager.render(owner), '恢复转发'), 'maintenance requires an explicit recovery action');
  owner.compatibility.events = [{ ...owner.compatibility.last_failure }];
  delete owner.compatibility.last_failure;
  root = manager.render(owner);
  assert(text(root).includes('1510 ms / 1400 ms'), 'old engine event still explains the failure');
  owner.compatibilityLive = false;
  root = manager.render(owner);
  assert(!text(root).includes('1510 ms'), 'failure diagnostics are never restored from display cache');
});

test('compatibility cached content is not write authority', async () => {
  const owner = controller();
  owner.accessExpanded = true;
  owner.compatibilityLive = false;
  owner.compatibility = {
    installed: true, requested: true, intercepting: false, reason: 'engine_unavailable',
    config: {
      rules: [{ id: 'site', name: 'Site', domain: 'service.example', port: 443, strategy: 'h2', enabled: true, devices: ['mac'] }],
      devices: [{ id: 'mac', name: 'Mac', addresses: ['192.0.2.2'] }],
    },
    rules: {}, trust: {}, rule_recovery: { site: { intercepting: true } },
  };
  let reads = 0, rejectRead;
  const api = {
    compatibilityGet: () => { reads++; return new Promise((_, reject) => { rejectRead = reject; }); },
    pluginRead: () => { throw new Error('tab must not load another plugin'); },
  };
  const manager = loadModule('compatibility.js', api);
  let root = manager.render(owner);
  assert(button(root, '添加网站').disabled);
  assert(text(root).includes('service.example'));
  assert(!text(root).includes('正在接管'), 'module bypass overrides stale rule interception');
  root = manager.render(owner);
  assert(text(root).includes('Mac'));
  assert(button(root, '添加接入范围').disabled);
  assert.equal(reads, 0);
  const pending = manager.refresh(owner);
  assert.equal(manager.refresh(owner), pending, 'refresh is single-flight');
  rejectRead(new Error('offline'));
  await pending;
  root = manager.render(owner);
  assert(text(root).includes('Mac'));
  assert(text(root).includes('刷新失败'));
  assert(button(root, '添加接入范围').disabled);
  assert.equal(reads, 1);
});

test('compatibility disposal ignores late read', async () => {
  const owner = controller();
  let disposed = false, complete, redraws = 0;
  owner.disposed = () => disposed;
  owner.redraw = () => { redraws++; };
  const manager = loadModule('compatibility.js', { compatibilityGet: () => new Promise(resolve => { complete = resolve; }) });
  const pending = manager.refresh(owner);
  disposed = true;
  complete({ requested: true });
  await pending;
  assert.equal(owner.compatibility, undefined);
  assert.equal(redraws, 0, 'late results must not redraw a departed page');
  await manager.refresh(owner);
  assert.equal(redraws, 0);
});

test('compatibility refresh preserves body until result', async () => {
  const owner = controller();
  owner.compatibility = {
    installed: true, requested: true, intercepting: true,
    config: { rules: [], devices: [{ id: 'egress', name: 'Shared egress', addresses: [] }] },
  };
  let complete, redraws = 0;
  const manager = loadModule('compatibility.js', { compatibilityGet: () => new Promise(resolve => { complete = resolve; }) });
  let root = manager.render(owner);
  owner.redraw = () => { redraws++; root = manager.render(owner); };
  assert(!button(root, '编辑范围'), 'collapsed access content is not constructed');
  const section = find(root, node => node.tag === 'details' && text(node) === '接入与证书');
  fire(section, 'toggle', { open: true });
  assert(button(root, '编辑范围'));
  const body = root;
  redraws = 0;
  const pending = fire(button(root, '刷新状态'));
  assert.equal(redraws, 0, 'starting a read must preserve the body and focus');
  assert.equal(root, body);
  assert(button(root, '刷新状态').disabled);
  assert(text(root).includes('正在刷新'));
  assert.equal(manager.refresh(owner), pending, 'overlapping reads remain single-flight');
  complete(clone(owner.compatibility));
  await pending;
  assert.equal(redraws, 1, 'one result causes one body render');
  assert(!button(root, '刷新状态').disabled);
  assert(!text(root).includes('正在刷新'));
  assert(button(root, '编辑范围'), 'expanded access remains available after refresh');
});

test('compatibility diagnostics expand during summary read', async () => {
  const owner = controller();
  const state = { installed: true, requested: true, intercepting: true, config: { rules: [], devices: [] } };
  owner.compatibility = clone(state);
  owner.compatibilityDiagnostics = false;
  const reads = [], pending = [];
  const manager = loadModule('compatibility.js', {
    compatibilityGet: params => { reads.push(params); return new Promise(resolve => pending.push(resolve)); },
  });
  let root = manager.render(owner);
  owner.redraw = () => { root = manager.render(owner); };
  const first = manager.refresh(owner);
  fire(find(root, node => node.tag === 'details' && text(node) === '技术诊断'), 'toggle', { open: true });
  assert.equal(reads.length, 1, 'expansion cannot overlap a pending read');
  assert(text(root).includes('正在读取诊断记录'));
  assert(!text(root).includes('尚无故障记录'));
  pending.shift()(clone(state));
  await first;
  assert.deepEqual(reads, [{ diagnostics: false }, { diagnostics: true }]);
  const second = owner.compatibilityRead;
  pending.shift()({ ...state, events: [{ at: 1, reason: 'client_cancelled' }] });
  await second;
  assert(text(root).includes('客户端已取消'));
  const details = find(root, node => node.tag === 'details' && text(node).startsWith('技术诊断'));
  fire(details, 'toggle', { open: false });
  assert.equal(reads.length, 2, 'closing diagnostics does not add a request');
  const third = manager.refresh(owner);
  assert.deepEqual(reads[2], { diagnostics: false });
  pending.shift()(clone(state));
  await third;
  assert(!text(root).includes('客户端已取消'));
});

test('compatibility display cache is bounded and redacted', async () => {
  const source = fs.readFileSync(path.join(RESOURCES, '../../https-compat/resources/display.js'), 'utf8');
  const { displayCache } = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
  const values = new Map();
  const storage = () => ({ getItem: key => values.get(key), setItem: (key, value) => values.set(key, value) });
  const cache = displayCache('device-a:revision-a', storage);
  const state = {
    installed: true, requested: true, revision: 'PRIVATE_REVISION', ca_key: 'PRIVATE_KEY',
    config: {
      rules: [{ id: 'site', name: 'Site', domain: 'service.example', devices: ['mac'] }],
      devices: [{ id: 'mac', name: 'Mac', addresses: [], identity: { binding: 'PRIVATE_BINDING' } }],
    },
    device_addresses: { mac: ['2001:db8::2'] },
    address_source: { config: { password: 'PRIVATE_PASSWORD' } },
    trust: { mac: { verified: true, runtimes: { codex_app: true }, token: 'PRIVATE_TOKEN' } },
    events: [{ body: 'PRIVATE_BODY' }],
  };
  cache.write(state, Date.now(), 'devices');
  assert(!values.get('device-a:revision-a').includes('PRIVATE_'));
  const cached = cache.read();
  assert.equal(cached.tab, undefined);
  assert.deepEqual(cached.state.config.devices[0].addresses, ['2001:db8::2']);
  assert.equal(cached.state.revision, undefined);
  assert.equal(displayCache('device-b:revision-a', storage).read(), null);
  assert.equal(displayCache('device-a:revision-b', storage).read(), null);
  values.set('device-a:revision-a', '{');
  assert.equal(cache.read(), null);
  values.set('device-a:revision-a', 'x'.repeat(128 * 1024 + 1));
  assert.equal(cache.read(), null);
  assert.doesNotThrow(() => displayCache('disabled', () => { throw Error('disabled'); }).write(state, Date.now(), 'rules'));
});

test('compatibility page keeps following bypass and cleans up', async () => {
  const source = fs.readFileSync(path.join(RESOURCES, '../../https-compat/resources/page.js'), 'utf8')
    .replace(/^import .*;$/gm, '').replace('export async function mount', 'async function mount')
    .replace('import.meta.url', "'https://router.test/page.js'");
  const timers = new Map();
  let serial = 0, view, dispose, refreshes = 0;
  const signal = { aborted: false };
  const dom = () => ({ append() {}, contains() { return false; }, querySelectorAll() { return []; }, replaceChildren() {}, remove() {} });
  globalThis.document = { hidden: false, createElement: dom, addEventListener() {}, removeEventListener() {} };
  const requirements = [], rpcCalls = [];
  globalThis.L.env = { rpctimeout: 20 };
  globalThis.L.require = async name => {
    requirements.push(name);
    if (name === 'netfleet.api') throw Error('HTTP 404');
    return name === 'rpc' ? { declare: spec => async request => { rpcCalls.push({ spec, request }); return { ok: true, result: { loaded: true } }; } } : {};
  };
  let pageApi;
  const manager = { render: () => ({}), refresh: async c => { view = c; refreshes++; c.follow(); } };
  const mount = new Function('createManager', 'displayCache', 'setTimeout', 'clearTimeout', source + ';return mount;')(
    options => { pageApi = options.api; return manager; }, () => ({ read: () => null, write() {} }),
    (fn, ms) => { timers.set(++serial, { fn, ms }); return serial; }, id => timers.delete(id),
  );
  await mount({ signal, container: dom(), scope: { effect: cb => { dispose = cb; } } });
  assert.deepEqual(requirements, ['ui'], 'plugin uses only its scoped host API');
  assert.equal(pageApi.pluginRead, undefined);
  assert.equal(pageApi.pluginCall, undefined);
  assert.equal(rpcCalls.length, 0);
  assert.equal(globalThis.L.env.rpctimeout, 20, 'transport restores the LuCI timeout');
  assert.equal([...timers.values()][0].ms, 10000, 'failed or initial reads keep following');
  for (const reason of ['lan_access_not_equivalent', 'rules_bypassed', 'future_reason']) {
    view.compatibilityLive = true;
    view.compatibility = { requested: true, intercepting: false, reason };
    view.follow();
    assert.equal(timers.size, 1);
    assert.equal([...timers.values()][0].ms, 3000);
  }
  view.compatibility.intercepting = true;
  view.follow();
  assert.equal([...timers.values()][0].ms, 10000, 'active traffic stats keep refreshing');
  globalThis.document.hidden = true;
  view.follow();
  assert.equal(timers.size, 0);
  globalThis.document.hidden = false;
  view.compatibility = { requested: false, active_connections: 0 };
  view.follow();
  assert.equal(timers.size, 0, 'disabled and drained stays idle');
  view.compatibility.active_connections = 2;
  view.follow();
  assert.equal(timers.size, 1);
  signal.aborted = true;
  dispose();
  assert.equal(timers.size, 0);
  assert.equal(refreshes, 1);
});

test('unmanaged compatibility preserves revision bound disable', async () => {
  const owner = controller();
  const state = {
    installed: true, managed: false, requested: true, intercepting: false, active_connections: 2, revision: 'compat-r1',
    reason: 'engine_unavailable', management_reason: 'extension_api_incompatible',
    config: { rules: [], devices: [] }, rules: {}, trust: {}, events: [],
  };
  owner.compatibility = clone(state);
  let reads = 0;
  const disabled = [];
  const api = {
    compatibilityGet: async () => { reads++; return { ...state, requested: false, revision: 'compat-r2' }; },
    compatibilityDisable: async request => { disabled.push(request); },
    compatibilityEnable: async () => { throw new Error('unmanaged module must not enable'); },
    compatibilityProbe: async () => { throw new Error('unmanaged module must not probe'); },
    compatibilityApply: async () => { throw new Error('unmanaged module must not apply'); },
  };
  const compatibility = loadModule('compatibility.js', api);
  let root = compatibility.render(owner);
  assert(text(root).includes('模块接口与当前 NetFleet 不兼容'));
  assert(button(root, '添加网站').disabled);
  owner.diagnosticsExpanded = true;
  root = compatibility.render(owner);
  assert(!button(root, '连接验证'), 'status-only RPC must not be presented as a connection test');
  assert(!button(root, '导出诊断').disabled);
  assert(!button(root, '恢复转发'));
  const toggle = find(root, node => node.tag === 'input' && node.attrs.type === 'checkbox');
  assert(toggle.checked);
  assert(!toggle.disabled, 'an incompatible installed module must remain stoppable');
  const stopping = fire(toggle, 'change', { checked: false });
  await stopping;
  assert.deepEqual(disabled, [{ revision: 'compat-r1' }]);
  assert.equal(reads, 1);
  root = compatibility.render(owner);
  assert(find(root, node => node.tag === 'input' && node.attrs.type === 'checkbox').disabled);
  assert(text(root).includes('仍有 2 条连接'));
  assert(!button(root, '导出诊断').disabled);
  await fire(button(root, '刷新状态'));
  assert.equal(reads, 2);
});

test('compatibility direct toggle and edit recheck capabilities', async () => {
  const owner = controller();
  owner.compatibility = {
    installed: true, requested: false, intercepting: false, active_connections: 0, revision: 'compat-r1',
    reason: 'disabled', config: { rules: [], devices: [] }, rules: {}, trust: {}, events: [],
  };
  let enables = 0, applies = 0;
  const api = {
    compatibilityEnable: async () => { enables++; },
    compatibilityApply: async () => { applies++; },
    compatibilityGet: async () => clone(owner.compatibility),
  };
  const compatibility = loadModule('compatibility.js', api);
  let root = compatibility.render(owner);
  assert(button(root, '添加网站').disabled, 'a rule requires a device');
  assert(!button(root, '添加接入范围').disabled, 'absence of managed must preserve the existing contract');
  let toggle = find(root, node => node.tag === 'input' && node.attrs.type === 'checkbox');
  assert(!toggle.disabled);
  await fire(toggle, 'change', { checked: true });
  assert.equal(enables, 1, 'explicit toggle applies directly');
  assert.equal(modal, null);
  owner.compatibility.managed = true;
  root = compatibility.render(owner);
  fire(button(root, '添加接入范围'));
  const fields = all(modal.content, node => node.tag === 'input');
  fire(fields[0], 'input', { value: 'Test Mac' });
  fire(fields[1], 'input', { value: '192.0.2.10' });
  owner.compatibility.managed = false;
  await fire(button(modal.content, '保存'));
  assert.equal(applies, 0, 'an open edit must not bypass a refreshed capability denial');
  owner.compatibility.installed = false;
  owner.compatibility.requested = true;
  owner.compatibility.reason = 'extension_component_not_installed';
  root = compatibility.render(owner);
  toggle = find(root, node => node.tag === 'input' && node.attrs.type === 'checkbox');
  assert(toggle.disabled, 'an absent owner cannot receive disable');
  assert(!button(root, '刷新状态').disabled);
  assert(text(root).includes('请在组件列表安装 HTTP/2 转发引擎'));
  assert(!text(root).includes('extension_component_not_installed'));
});

test('native luci uses display cache then revalidates once', async () => {
  const source = fs.readFileSync(path.join(RESOURCES, 'product-pages.js'), 'utf8')
    .split('return baseclass.extend({\n\tmount:')[0] + '\nreturn productController;';
  function domNode(tag, attrs, children) {
    const node = {
      tag,
      attrs: attrs || {},
      children: Array.isArray(children) ? children : children == null ? [] : [children],
      replaceChildren() { this.children = Array.from(arguments); },
      getAttribute(name) { return this.attrs[name] == null ? null : this.attrs[name]; },
      setAttribute(name, value) { this.attrs[name] = String(value); },
      addEventListener(name, callback) { this.attrs[name] = callback; },
      focus() { this.focused = true; },
    };
    node.classList = {
      add: name => { node.attrs.class = [...new Set(String(node.attrs.class || '').split(' ').concat(name))].join(' '); },
      remove: name => { node.attrs.class = String(node.attrs.class || '').split(' ').filter(item => item !== name).join(' '); },
    };
    return node;
  }
  function walkDom(value, visit) {
    if (Array.isArray(value)) { value.forEach(item => walkDom(item, visit)); return; }
    if (!value || typeof value !== 'object') return;
    visit(value);
    walkDom(value.children, visit);
  }
  function nodeText(value) {
    if (Array.isArray(value)) return value.map(nodeText).join('');
    if (value == null) return '';
    return typeof value === 'object' ? nodeText(value.children) : String(value);
  }
  function findNode(root, predicate) {
    let found = null;
    walkDom(root, node => { if (!found && predicate(node)) found = node; });
    return found;
  }
  function deferred() {
    let resolve, reject;
    const promise = new Promise((ok, fail) => { resolve = ok; reject = fail; });
    return { promise, resolve, reject };
  }
  function makeStatus(active, actions) {
    return {
      build: { version: '0.3.0', source_commit: 'a'.repeat(40), source_tree: 'b'.repeat(40) },
      active, actions: actions || {}, capabilities: [], providers: [], regions: [], selection: {},
      runtime: { netfleet_present: active, mihomo_running: active, controller_available: true, supervisor: {}, lan_runtime: { dashboard_lan_ready: active } },
    };
  }
  function makeEvent(index) {
    return {
      at: index + 1, action: 'select', trigger: 'scheduled', initiator: 'supervisor',
      capability: 'ordinary', region_id: 'hk', provider_id: 'primary',
      leaf: 'node-' + String(index), delay_ms: 20 + index, reason: 'fastest_eligible',
    };
  }
  function createStorage(seed) {
    const values = new Map(Object.entries(seed || {}));
    return {
      getItem: key => values.has(key) ? values.get(key) : null,
      setItem: (key, value) => values.set(key, String(value)),
      removeItem: key => values.delete(key),
      value: key => values.get(key),
    };
  }
  function createPage(storage, api, notifications) {
    const styleLink = domNode('link', { id: 'netfleet-native-style' });
    const doc = { body: {}, documentElement: { dataset: {} }, getElementById: () => styleLink, head: { appendChild() {} } };
    const netfleetConfig = { clone: v => JSON.parse(JSON.stringify(v)), dirty: () => false, render: () => domNode('div', {}, 'config') };
    let dashboardOpens = 0;
    const pageUi = {
      addNotification: (_, message, level) => notifications.push({ message: nodeText(message), level }),
      showModal() {}, hideModal() {},
    };
    const managedStub = {
      displayVersion: value => value ? value.replace(/^v/, '').replace(/-r\d+$/, '') : '版本未提供',
      quotaResetLabel: day => Number.isInteger(day) && day >= 1 && day <= 31 ? '每月 ' + day + ' 日重置' : '',
      notify: pageUi.addNotification,
      preloadSubscriptions: () => Promise.resolve(),
      readOperations: () => Promise.resolve(),
      loadComponents: () => Promise.resolve(),
      operationNode: () => null,
    };
    api.nativeSetupGet = () => Promise.resolve({ ready: false });
    api.dashboardGet = () => Promise.resolve({ available: true, port: 9090, protocol: 'http', ui_name: 'zashboard', secret: 'private-secret' });
    const managementLoads = [];
    const managementStub = { load: (_, section) => { managementLoads.push(section); return Promise.resolve(); }, maintenance: () => null, dashboard: () => null };
    const productSource = fs.readFileSync(path.join(RESOURCES, 'product.js'), 'utf8');
    const product = new Function('baseclass', 'E', productSource)({ extend: value => value }, domNode);
    const productViews = new Function('baseclass', 'ui', 'managed', 'E', fs.readFileSync(path.join(RESOURCES, 'product-views.js'), 'utf8'))({ extend: value => value }, pageUi, managedStub, domNode);
    const factory = new Function('view', 'ui', 'managed', 'management', 'netfleet', 'netfleetConfig', 'E', 'L', 'window', 'document', 'compatibility', 'poll', 'product', 'resourceUrl', 'productViews', 'getComputedStyle', source);
    const page = factory(
      { extend: value => value }, pageUi, managedStub, managementStub, api, netfleetConfig, domNode,
      { resource: value => value, url: value => '/cgi-bin/luci/' + value },
      { localStorage: storage, location: { hostname: 'router.example' }, open: () => { dashboardOpens++; return { location: { replace(url) {
        const parsed = new URL(url);
        assert.equal(parsed.hostname, 'router.example');
        assert.equal(parsed.pathname, '/ui/zashboard/');
        assert.equal(parsed.searchParams.get('secret'), 'private-secret');
      } }, close() {} }; } },
      doc, { refresh: () => Promise.resolve(), label: () => '未安装' }, { add() {} }, product,
      name => 'resources/' + name + '?v=revision-1', productViews, () => ({ backgroundColor: 'rgb(255, 255, 255)' }),
    );
    page.pageId = 'overview';
    page.navigated = null;
    page.context = { signal: new AbortController().signal, navigate(id) { page.navigated = id; } };
    page.styleLink = styleLink;
    page.dashboardOpens = () => dashboardOpens;
    page.managementLoads = managementLoads;
    return page;
  }

  const cacheKey = 'opl-netfleet:luci-display:v1';
  const cachedStatus = makeStatus(false, { can_enable: true });
  cachedStatus.providers = [{ id: 'primary', display_name: '正式机场', available_count: 0, available_region_count: 0, candidate_count: 3, region_count: 2 }];
  const storage = createStorage({ [cacheKey]: JSON.stringify({ schema: 1, status: cachedStatus, events: { events: [makeEvent(0)], core_lines: [] }, fetched_at_ms: Date.now() - 60000, read_duration_ms: 1664 }) });
  const liveStatus = deferred(), liveEvents = deferred(), liveConfig = deferred(), notifications = [];
  const page = createPage(storage, { onboardingGet: () => Promise.resolve({ required: false }), status: () => liveStatus.promise, events: () => liveEvents.promise, configGet: () => liveConfig.promise }, notifications);

  let initialResolved = false;
  const initialPromise = page.load().then(value => { initialResolved = true; return value; });
  await tick();
  assert.equal(initialResolved, true, 'cached load must not wait for RPC');
  const root = page.render(await initialPromise);
  assert(nodeText(root).includes('概览'));
  assert(!nodeText(root).includes('NetFleet v0.3.0 · aaaaaaa'), 'build identity belongs in component details, not the page header');
  assert.equal(page.styleLink.attrs.href, 'resources/native.css?v=revision-1');
  assert.equal(page.liveDataReady, false);
  assert(nodeText(root).includes('缓存数据，正在更新'));
  assert(nodeText(root).includes('NetFleet 当前未接管，机场和地区的实时可用性未测量'));
  assert(!nodeText(root).includes('不可用机场：'), 'inactive availability must not be reported as provider outage');
  const cachedEnable = findNode(root, node => node.tag === 'button' && nodeText(node) === '切换模式');
  assert(cachedEnable && cachedEnable.attrs.disabled === true, 'cached actions must stay disabled');

  liveStatus.resolve(makeStatus(true, { can_disable: true }));
  liveEvents.resolve({ events: Array.from({ length: 25 }, (_, index) => makeEvent(index)), core_lines: ['private log'], core_lines_persistent: false });
  liveConfig.resolve({ revision: 'a'.repeat(64), active: true, pending_apply: false });
  await page.initialRefresh;
  await tick();
  assert.equal(page.liveDataReady, true);
  assert.equal(page.readDurationMs >= 0, true);
  const persisted = JSON.parse(storage.value(cacheKey));
  assert.deepEqual(persisted.events.core_lines, [], 'raw logs must not be persisted');
  assert.equal(persisted.status.active, true);
  const runtimeEntry = findNode(root, node => node.tag === 'button' && nodeText(node) === 'Zashboard ↗');
  assert(runtimeEntry && runtimeEntry.attrs['aria-disabled'] !== 'true', 'healthy dashboard entry must be enabled');
  assert.equal(page.dashboardUrl, undefined, 'normal page does not read dashboard credentials');
  await page.prepareDashboard();
  const dashboardUrl = new URL(page.dashboardUrl);
  assert.equal(dashboardUrl.hostname, 'router.example');
  assert.equal(dashboardUrl.pathname, '/ui/zashboard/');
  assert.equal(dashboardUrl.hash, '#/setup', 'saved backend credentials must not bypass the new connection');
  assert.equal(findNode(root, node => node.tag === 'ul' && node.attrs.class === 'cbi-tabmenu'), null, 'plugin pages delegate navigation to the shell');
  assert.equal(dashboardUrl.searchParams.get('secret'), 'private-secret');
  assert.equal(typeof runtimeEntry.attrs.click, 'function', 'Dashboard resolves fresh credentials on demand');
  assert.equal(page.dashboardOpens(), 0, 'normal navigation must not create an intermediate blank window');
  assert(!storage.value(cacheKey).includes('private-secret'), 'dashboard credentials must remain memory-only');
  await tick();
  page.status.runtime.lan_runtime.dashboard_lan_ready = false;
  page.redraw();
  const disabledRuntimeEntry = findNode(root, node => node.tag === 'button' && nodeText(node) === 'Zashboard ↗');
  assert(disabledRuntimeEntry && disabledRuntimeEntry.attrs.disabled === true, 'unready dashboard entry must be disabled');
  assert.equal(disabledRuntimeEntry.attrs.title, 'Zashboard 的局域网访问条件尚未就绪');
  page.status.runtime.lan_runtime.dashboard_lan_ready = true;
  page.redraw();

  page.status.capabilities = [{
    id: 'standard', display_name: '海外加速', base_group: '海外加速', data_path: 'preferred',
    provider_id: 'primary', region_id: 'hk', leaf: '香港-专线(AnyTLS)', alive: true, user_mode: 'automatic',
    reason: { kind: 'automatic_decision', delay_ms: 8, protected_probes_ok: true },
    business_routes: [
      { name: 'Netflix', default_route: 'capability' }, { name: 'Nintendo Switch', default_route: 'capability' },
      { name: 'Steam', default_route: 'direct' }, { name: '国内媒体', default_route: 'direct' },
    ],
    fail_open_stages: [{ kind: 'provider_tier', role: 'primary', provider_ids: ['primary'] }, { kind: 'direct', provider_ids: [] }],
  }];
  page.status.providers = [{ id: 'primary', display_name: 'Alpha 正式机场' }];
  page.status.regions = [{ id: 'hk', display_name: '🇭🇰 香港' }];
  page.currentView = 'exits';
  page.redraw();
  const runningMetrics = findNode(findNode(root, node => node.attrs.class === 'netfleet-page-content'), node => node.tag === 'div' && String(node.attrs.class || '').includes('netfleet-metrics is-five'));
  assert(runningMetrics && runningMetrics.children.length === 5, 'running metrics must use the balanced five-item layout');
  assert(nodeText(root).includes('默认走此出口') && nodeText(root).includes('默认直连，可在 Zashboard 临时切换'));
  assert(nodeText(root).includes('Netflix') && nodeText(root).includes('Steam') && !nodeText(root).includes('接管的原始策略组'));
  assert(String(root.children[root.children.length - 1].children[0].attrs.class).includes('netfleet-source'), 'data source must follow page content');
  assert(findNode(root.children[0], node => node.tag === 'button' && nodeText(node) === '刷新'), 'page actions share the title row');

  page.status.providers = [{
    id: 'primary', display_name: 'Alpha 正式机场', subscription_section: 'primary', selected: true, role: 'primary',
    billing: 'subscription', available_region_count: 2, region_count: 2, available_node_count: 47, node_count: 50,
    node_count_known: true, available_count: 3, candidate_count: 4, last_best_delay_ms: 18,
    average_best_delay_ms: 20, delay_sample_count: 3, delay_sampled_at: 1700000000,
    quota: { state: 'available', remaining_bytes: 1024, expires_at: '2027-01-01' },
  }];
  page.status.subscription_refresh = { enabled: true, interval_seconds: 43200, provider_count: 1, last_run_at: 1700000000, last_result: 'unchanged', last_success_at: 1699999000, next_run_at: 1700043200 };
  page.status.subscriptions = [{ section: 'primary', ref: 'subscription:primary', display_name: 'Alpha 正式机场', cache_present: true, cache_sha256: 'c'.repeat(64), node_count: 52, last_attempt: 1700000000, last_success: 1700000000, last_result: 'updated' }];
  page.currentView = 'providers';
  page.redraw();
  const providerPageText = nodeText(findNode(root, node => node.attrs.class === 'netfleet-page-content'));
  assert(providerPageText.includes('1 / 1 正常') && providerPageText.includes('最近全部更新') && providerPageText.includes('最近尝试') && providerPageText.includes('下次更新'));
  assert(!providerPageText.includes('暂无成功记录') && providerPageText.includes('资源数：当前可用 / 已加载') && providerPageText.includes('47/50 节点 · 订阅 52 条'));
  assert(!providerPageText.includes('3/4 节点') && providerPageText.includes('订阅正常') && providerPageText.includes('管理订阅'));
  const subscriptionLink = findNode(findNode(root, node => node.attrs.class === 'netfleet-page-content'), node => node.tag === 'button' && nodeText(node) === '管理订阅');
  assert(subscriptionLink && subscriptionLink.attrs.class === 'netfleet-inline-link');
  assert(!providerPageText.includes('订阅更新时间') && !providerPageText.includes('更新完成并已重载') && !providerPageText.includes('订阅缓存'));
  const providerDetail = findNode(root, node => node.tag === 'aside' && node.attrs.id === 'netfleet-provider-inspector');
  const providerDetailToggle = findNode(root, node => node.tag === 'button' && nodeText(node) === 'Alpha 正式机场');
  assert(providerDetail && providerDetail.attrs.hidden === true && providerDetailToggle && providerDetailToggle.attrs['aria-expanded'] === 'false');
  providerDetailToggle.attrs.click();
  assert.equal(providerDetail.hidden, false);
  const providerTable = findNode(root, node => String(node.attrs.class || '').includes('netfleet-provider-table'));
  const headers = findNode(providerTable, node => node.tag === 'thead').children[0].children;
  const cells = findNode(providerTable, node => node.tag === 'tbody').children[0].children;
  assert.deepEqual(headers.map(nodeText), ['机场', '定位', '可用资源', '最近一次测速', '订阅状态', '剩余流量', '到期时间']);
  assert.equal(cells.length, headers.length);
  assert.equal(nodeText(cells[4]), '订阅正常');
  assert(nodeText(cells[6]).includes('2027'));
  assert.equal(providerDetailToggle.attrs['aria-expanded'], 'true');
  assert(nodeText(providerDetail).includes('订阅更新时间') && nodeText(providerDetail).includes('cccccccccccc'));
  assert(!findNode(providerDetail, node => node.tag === 'meter'), 'unknown quota totals must not invent a ratio');
  providerDetail.attrs.keydown({ key: 'Escape' });
  assert.equal(providerDetail.hidden, true);
  assert(providerDetailToggle.focused, 'closing detail must return keyboard focus');
  const search = findNode(root, node => node.attrs['aria-label'] === '搜索机场');
  search.attrs.input({ target: { value: '不存在' } });
  assert(nodeText(root).includes('没有匹配的机场'));
  search.attrs.input({ target: { value: 'Alpha' } });
  assert(nodeText(root).includes('47/50 节点'));
  page.status.subscriptions[0].last_attempt = null;
  page.status.subscriptions[0].last_success = null;
  page.redraw();
  findNode(root, node => node.tag === 'button' && nodeText(node) === 'Alpha 正式机场').attrs.click();
  assert(nodeText(root).includes('最近尝试尚未执行') && nodeText(root).includes('订阅更新时间尚未执行'));
  page.status.providers.push({ ...page.status.providers[0], id: 'faster', display_name: 'Beta', selected: false, average_best_delay_ms: 10, delay_sample_count: 2 });
  page.status.providers.push({ ...page.status.providers[0], id: 'single', display_name: 'Gamma', selected: false, average_best_delay_ms: 1, delay_sample_count: 1 });
  page.providerTableState.query = '';
  page.redraw();
  findNode(root, node => node.attrs['aria-label'] === '机场排序').attrs.change({ target: { value: 'average' } });
  let names = [];
  walkDom(root, node => { if (node.tag === 'button' && node.attrs.class === 'netfleet-name-link') names.push(nodeText(node)); });
  assert.deepEqual(names, ['Beta', 'Alpha 正式机场', 'Gamma'], 'one-sample averages must sort after real averages');
  findNode(root, node => node.tag === 'input' && node.attrs.type === 'checkbox').attrs.change({ target: { checked: true } });
  names = [];
  walkDom(root, node => { if (node.tag === 'button' && node.attrs.class === 'netfleet-name-link') names.push(nodeText(node)); });
  assert.deepEqual(names, ['Alpha 正式机场']);

  const refreshConnections = page.refreshConnections;
  let connectionReads = 0;
  page.refreshConnections = () => { connectionReads++; };
  findNode(root, node => node.tag === 'button' && nodeText(node) === '事件与诊断').attrs.click();
  assert.equal(page.navigated, 'events');
  assert.equal(connectionReads, 0, 'new plugin page owns its own reads');
  page.refreshConnections = refreshConnections;
  page.status.regions = [
    { id: 'hk', display_name: 'HK 香港', selected: true, available_count: 1, available_provider_count: 1 },
    { id: 'jp', display_name: 'JP 日本', available_count: 1, available_provider_count: 1 },
    { id: 'ch', display_name: 'CH 瑞士', available_count: 0, available_provider_count: 0 },
  ];
  page.currentView = 'regions';
  page.redraw();
  assert(nodeText(root).includes('已配置 3 个地区') && nodeText(root).includes('显示 3 个') && nodeText(root).includes('CH 瑞士'));
  findNode(root, node => node.attrs['aria-label'] === '搜索地区').attrs.input({ target: { value: '日本' } });
  assert(nodeText(root).includes('已配置 3 个地区') && nodeText(root).includes('显示 1 个'));

  page.currentView = 'events';
  page.redraw();
  const eventPageText = nodeText(findNode(root, node => node.attrs.class === 'netfleet-page-content'));
  assert(eventPageText.includes('选路事件') && !eventPageText.includes('Mihomo 原始日志') && !eventPageText.includes('当前活动连接'));
  page.diagnosticSection = 'core'; page.redraw();
  const diagnosticMetrics = findNode(findNode(root, node => node.attrs.class === 'netfleet-page-content'), node => node.tag === 'div' && String(node.attrs.class || '') === 'netfleet-metrics');
  assert(diagnosticMetrics && diagnosticMetrics.children.length === 4);
  const diagnosticNote = findNode(findNode(root, node => node.attrs.class === 'netfleet-page-content'), node => node.tag === 'div' && String(node.attrs.class || '').includes('netfleet-diagnostic-note'));
  assert(diagnosticNote && nodeText(diagnosticNote).includes('原始日志：临时窗口'));
  page.diagnosticSection = 'website'; page.redraw();
  const connectionDetails = findNode(root, node => node.tag === 'details' && String(node.attrs.class || '').includes('netfleet-connection-details'));
  assert(connectionDetails && connectionDetails.attrs.open === undefined && nodeText(connectionDetails).includes('详细规则命中链、连接流量和实时代理组观察请使用 Zashboard'));
  page.diagnosticSection = 'events'; page.redraw();
  let body = findNode(root, node => node.tag === 'tbody' && node.children.length === 20);
  assert.equal(body.children.length, 20, 'first page must contain 20 events');
  assert(findNode(root, node => node.tag === 'div' && String(node.attrs.class || '').includes('netfleet-event-pagination')));
  const next = findNode(root, node => node.tag === 'button' && nodeText(node) === '下一页');
  assert(next && next.attrs.disabled !== true);
  next.attrs.click();
  body = findNode(root, node => node.tag === 'tbody' && node.children.length === 5);
  assert.equal(body.children.length, 5, 'second page must contain remaining events');
  assert.equal(page.eventPage, 1);

  const failedStatus = deferred(), failedNotifications = [];
  const failedPage = createPage(storage, { onboardingGet: () => Promise.resolve({ required: false }), status: () => failedStatus.promise, events: () => Promise.resolve({ events: [] }), configGet: () => Promise.resolve({ revision: 'b'.repeat(64), active: false, pending_apply: false }) }, failedNotifications);
  const failedInitial = await failedPage.load();
  const failedRoot = failedPage.render(failedInitial);
  failedStatus.reject(new Error('offline'));
  await failedPage.initialRefresh;
  await tick();
  assert.equal(failedPage.liveDataReady, false);
  assert(nodeText(failedRoot).includes('缓存数据，刷新失败'));
  const failedDisable = findNode(failedRoot, node => node.tag === 'button' && nodeText(node) === '切换模式');
  assert(failedDisable && failedDisable.attrs.disabled === true);
  const retry = findNode(failedRoot, node => node.tag === 'button' && nodeText(node) === '刷新');
  assert(retry && retry.attrs.disabled !== true);
  assert.equal(failedNotifications.length, 1);
});

test('native luci config renders real regions and owner actions', () => {
  const config = configModule({});
  const deviceConfig = {
    revision: 'a'.repeat(64), active: true, pending_apply: false,
    backend: { id: 'nikki-mihomo', display_name: 'Nikki + Mihomo' },
    policy_source: { kind: 'bundle', ref: 'bundle:base-v1', display_name: 'NetFleet 内置基础策略' },
    policy_source_options: [{ kind: 'bundle', ref: 'bundle:base-v1', display_name: 'NetFleet 内置基础策略' }],
    policy_groups: ['节点选择', '流媒体'],
    recovery_profile: { ref: 'subscription:base', display_name: '当前原生配置' },
    recovery_profile_options: [{ ref: 'subscription:base', display_name: '当前原生配置' }],
    providers: [],
    provider_options: [{ id: 'alpha', section: 'alpha', display_name: 'Alpha 机场', region_ids: ['japan', 'singapore'] }],
    regions: [{ id: 'japan', flag: '🇯🇵', display_name: '日本', mode: 'automatic' }, { id: 'switzerland', flag: '🇨🇭', display_name: '瑞士', mode: 'automatic' }],
    region_options: [{ id: 'japan', code: 'JP', display_name: '日本', display_order: 10 }, { id: 'singapore', code: 'SG', display_name: '新加坡', display_order: 20 }],
    capabilities: [{ id: 'standard', display_name: '常规出口', enabled: true, mode: 'automatic', region_ids: ['japan', 'switzerland'], entry_group: '节点选择', policy_groups: [], base_groups: ['节点选择'] }],
    routing_rules: [],
    automation: { enabled: true, selection_interval_seconds: 1800, subscription_refresh_enabled: true, subscription_refresh_interval_seconds: 43200 },
    safety: { region_switch_margin_ms: 150, leaf_switch_margin_ms: 150, runtime_grace_seconds: 45, latency_url: 'https://latency.invalid', path_probe_url: 'https://path.invalid', guard_probe_url: 'https://guard.invalid' },
  };
  const owner = {
    config: config.clone(deviceConfig), configDraft: config.clone(deviceConfig), configSection: 'regions',
    status: { providers: [], regions: [{ id: 'japan', available_provider_count: 2, available_node_count: 4 }, { id: 'switzerland', available_provider_count: 0, available_node_count: 0 }], runtime: {} },
    busy: false, liveDataReady: true, redraw() {}, showConfigWizard() {}, discardConfig() {}, previewConfigChanges() {}, saveConfig() {}, confirmConfigApply() {},
  };
  let root = config.render(owner);
  assert(text(root).includes('JP'));
  assert(find(root, node => node.tag === 'input' && node.attrs.value === '日本'));
  assert(find(root, node => node.tag === 'input' && node.attrs.value === '瑞士'), 'configured regions must remain removable even when currently unavailable');
  assert(!find(root, node => node.tag === 'button' && text(node) === '保存配置'), 'active policy offers one apply action rather than an unusable save button');
  let apply = find(root, node => node.tag === 'button' && text(node) === '应用更改');
  assert(apply && apply.disabled === true);

  owner.configSection = 'providers';
  root = config.render(owner);
  const addProvider = find(root, node => node.tag === 'button' && text(node) === '添加机场');
  assert(addProvider, 'an available Nikki subscription must be addable');
  addProvider.attrs.click();
  assert.equal(owner.configDraft.providers.length, 1);
  assert.equal(owner.configDraft.providers[0].section, 'alpha');
  assert(owner.configDraft.regions.some(region => region.id === 'singapore'), 'adding a provider must bring in discovered regions');

  owner.configSection = 'capabilities';
  root = config.render(owner);
  assert(text(root).includes('JP 日本') && text(root).includes('瑞士') && !text(root).includes('null'));

  owner.configDraft.regions[0].display_name = '日本线路';
  root = config.render(owner);
  apply = find(root, node => node.tag === 'button' && text(node) === '应用更改');
  assert(apply && apply.disabled === false);
  assert(config.changeText({ scope: 'region', id: 'japan', field: 'display_name', before: '日本', after: '日本线路' }, owner).includes('日本线路'));
  assert(text(config.wizard(owner, 0)).includes('环境与恢复'));

  owner.configDraft = config.clone(owner.config);
  owner.configDraft.active = false;
  root = config.render(owner);
  apply = find(root, node => node.tag === 'button' && text(node) === '应用并接管');
  assert(apply && apply.disabled === false, 'inactive saved config must remain applicable');
});

test('components page supports batch update preview and auto-update status summary', async () => {
  const owner = controller();
  owner.componentsSection = 'plugins';
  const items = [
    { name: 'opl-netfleet-plugin-compilation', id: 'compilation', installed_version: '0.9.0', available_version: '0.9.1', update_available: true, dependencies: [] },
    { name: 'luci-app-netfleet', id: 'luci', installed_version: '0.9.0', available_version: '0.9.1', update_available: true, dependencies: [] },
  ];
  owner.components = {
    supported: true,
    capabilities: { batch_plugin_update: true },
    feed: { configured: true },
    components: [],
    extensions: [],
    plugin_packages: items,
    auto_update: {
      enabled: true,
      interval_seconds: 86400,
      last_result: 'deferred',
      deferred_packages: [{ name: 'opl-netfleet-kernel', version: '0.9.26' }],
    },
  };
  let plannedRequest = null, executedRequest = null;
  const plan = {
    names: ['opl-netfleet-plugin-compilation', 'luci-app-netfleet'],
    candidates: { 'opl-netfleet-plugin-compilation': '0.9.1', 'luci-app-netfleet': '0.9.1' },
  };
  const managed = loadModule('managed.js', {
    componentsPluginPlan: async request => { plannedRequest = request; return plan; },
    componentsPlugin: async request => { executedRequest = request; return { operation: { id: 'batch-1', state: 'running' } }; },
    operationGet: async () => ({ packages: { id: 'batch-1', state: 'running' } }),
  });
  const root = managed.components(owner);
  assert(text(root).includes('安全插件自动更新：已开启（每 24 小时）'));
  assert(text(root).includes('存在需手动确认的底座更新'));
  assert(text(root).includes('opl-netfleet-kernel → 0.9.26'));
  await fire(button(root, '更新全部可升级插件 (2)'));
  assert.equal(plannedRequest.confirm, false);
  assert.equal(plannedRequest.items.length, 2);
  assert(text(modal.content).includes('opl-netfleet-plugin-compilation → 0.9.1'));
  await fire(button(modal.content, '确认全部更新'));
  assert.equal(executedRequest.confirm, true);
  assert.deepEqual(executedRequest.plan, plan);
  clearTimeout(owner.operationTimer);
  clearTimeout(owner.resultTimer);

  // Without backend batch capability flag (e.g. v0.9.25 components), batch button stays hidden.
  const legacyOwner = controller();
  legacyOwner.componentsSection = 'plugins';
  legacyOwner.components = {
    supported: true,
    feed: { configured: true },
    components: [],
    extensions: [],
    plugin_packages: items,
  };
  const legacyRoot = managed.components(legacyOwner);
  assert(!all(legacyRoot, node => node.tag === 'button' && text(node).includes('更新全部可升级插件')).length);
  assert(all(legacyRoot, node => node.tag === 'button' && text(node) === '更新').length >= 2);
});

test('config page renders plugin auto-update controls and change labels', () => {
  const config = configModule({});
  const deviceConfig = {
    revision: 'a'.repeat(64), active: true, pending_apply: false,
    backend: { id: 'native-mihomo', display_name: 'NetFleet + Mihomo', features: { rule_refresh: false } },
    policy_source: { kind: 'bundle', ref: 'bundle:base-v1', display_name: 'NetFleet 内置基础策略' },
    policy_source_options: [{ kind: 'bundle', ref: 'bundle:base-v1', display_name: 'NetFleet 内置基础策略' }],
    policy_groups: ['OUTBOUND'],
    recovery_profile: { ref: 'subscription:base', display_name: '当前原生配置' },
    recovery_profile_options: [{ ref: 'subscription:base', display_name: '当前原生配置' }],
    providers: [],
    provider_options: [],
    regions: [{ id: 'japan', flag: '🇯🇵', display_name: '日本', mode: 'automatic' }],
    region_options: [{ id: 'japan', code: 'JP', display_name: '日本', display_order: 10 }],
    capabilities: [{ id: 'standard', display_name: '常规出口', enabled: true, mode: 'automatic', region_ids: ['japan'], entry_group: 'OUTBOUND', policy_groups: [], base_groups: ['OUTBOUND'] }],
    routing_rules: [],
    automation: {
      enabled: true, selection_interval_seconds: 1800,
      subscription_refresh_enabled: true, subscription_refresh_interval_seconds: 43200,
      plugin_auto_update_enabled: false, plugin_auto_update_interval_seconds: 86400,
    },
    safety: { region_switch_margin_ms: 150, leaf_switch_margin_ms: 150, runtime_grace_seconds: 45, latency_url: 'https://latency.invalid', path_probe_url: 'https://path.invalid', guard_probe_url: 'https://guard.invalid' },
  };
  const owner = {
    config: config.clone(deviceConfig), configDraft: config.clone(deviceConfig), configSection: 'automation',
    status: { providers: [], regions: [], runtime: {} },
    busy: false, liveDataReady: true, redraw() {}, showConfigWizard() {}, discardConfig() {}, previewConfigChanges() {}, saveConfig() {}, confirmConfigApply() {},
  };
  let root = config.render(owner);
  assert(text(root).includes('定期自动更新安全插件'));
  assert(text(root).includes('插件自动更新周期'));
  const toggleRow = find(root, node => text(node).includes('定期自动更新安全插件') && all(node, child => child.tag === 'input').length === 1);
  const checkboxInput = find(toggleRow, node => node.tag === 'input' && node.attrs.type === 'checkbox');
  const intervalRow = find(root, node => text(node).includes('插件自动更新周期') && all(node, child => child.tag === 'select').length === 1);
  const intervalSelect = find(intervalRow, node => node.tag === 'select');
  assert.equal(checkboxInput.checked, false);
  assert.equal(intervalSelect.disabled, true);
  checkboxInput.attrs.change({ target: { checked: true } });
  assert.equal(owner.configDraft.automation.plugin_auto_update_enabled, true);
  root = config.render(owner);
  const enabledRow = find(root, node => text(node).includes('插件自动更新周期') && all(node, child => child.tag === 'select').length === 1);
  const enabledSelect = find(enabledRow, node => node.tag === 'select');
  assert.equal(enabledSelect.disabled, false);
  enabledSelect.attrs.change({ target: { value: '21600' } });
  assert.equal(owner.configDraft.automation.plugin_auto_update_interval_seconds, 21600);
  assert(config.changeText({ scope: 'automation', field: 'plugin_auto_update_enabled', before: false, after: true }, owner).includes('自动更新安全插件'));
  assert(config.changeText({ scope: 'automation', field: 'plugin_auto_update_interval_seconds', before: 86400, after: 21600 }, owner).includes('插件自动更新周期'));
});
