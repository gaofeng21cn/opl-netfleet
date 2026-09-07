import pathlib
import subprocess
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "openwrt/luci-app-netfleet/htdocs/luci-static/resources/netfleet"

HARNESS = r"""
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const resources = process.argv[1];
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
    for (const name of ['disabled', 'checked', 'open']) {
        if (node.attrs[name] != null) node.attrs[name] = String(node.attrs[name]);
        Object.defineProperty(node, name, { get: () => node.attrs[name] != null, set: value => { if (value) node.attrs[name] = ''; else delete node.attrs[name]; } });
    }
    node.setAttribute = (name, value) => { node.attrs[name] = String(value); };
    Object.defineProperty(node, 'textContent', { get: () => text(node), set: value => { node.children = [value]; } });
    function parent(items) { items.forEach(item => { if (Array.isArray(item)) parent(item); else if (item && typeof item === 'object') item.parent = node; }); }
    parent(node.children);
    node.remove = () => {};
    node.click = () => node.attrs.click && node.attrs.click({ target: node });
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
let modal = null;
const notifications = [];
const ui = {
    showModal(title, content) { modal = { title, content }; },
    hideModal() { modal = null; },
    addNotification(_, content, severity) { notifications.push({ text: text(content), severity }); },
};
const storage = new Proxy({}, { get() { throw new Error('secret storage access is forbidden'); } });
global.localStorage = storage;
global.sessionStorage = storage;
global.document = { body: { appendChild() {} }, querySelectorAll() { return []; } };
const baseclass = { extend: value => value };
function module(name, api) {
    return new Function('baseclass', 'ui', 'api', 'E', 'managed', fs.readFileSync(path.join(resources, name), 'utf8'))(baseclass, ui, api, E, name === 'managed.js' ? null : module('managed.js', api));
}
function configModule(management) {
    return new Function('baseclass', 'ui', 'management', 'E', 'compatibility', fs.readFileSync(path.join(resources, 'config.js'), 'utf8'))(baseclass, ui, management, E, { render: () => null });
}
function networkState() {
    return { available: true, backend: 'native-mihomo', revision: 'network-r1', running: true,
        settings: {
            dns: { nameservers: ['1.1.1.1'], default_nameservers: ['9.9.9.9'], proxy_nameservers: ['https://resolver.example/dns-query'], direct_nameservers: [], policies: [{ domain: 'service.example', nameservers: ['1.0.0.1'] }], proxy_policies: [] },
            lan: { enabled: true, interfaces: ['br-lan'], rules: [{ id: 'device-a', enabled: true, ipv4: ['192.0.2.10'], ipv6: ['2001:db8::10'], mac: [], proxy: false, dns: true }] },
            router: { enabled: true },
            listeners: { mixed_port: 7890, http_port: 0, socks_port: 0, authentication_enabled: true, credentials: [{ id: 'login-a', username: 'operator', password_configured: true }] },
        }, resources: { interfaces: [{ name: 'br-lan', up: true, device: 'br-lan' }], preserved_dns_policy_count: 0, preserved_proxy_policy_count: 0 } };
}
function maintenanceState() {
    return { supported: true, revision: 'maintenance-r1', profiles: [{ id: 'custom.json', ref: 'file:custom.json', format: 'json', size_bytes: 64, modified_at: 100, referenced: false, editable: true }],
        core: { running: true, controller_available: true, running_version: 'v1.19.30', actions: ['restart', 'reload'] }, backup: { format: 'netfleet-backup-v1', contains_credentials: true } };
}
function policyConfig() {
    return { revision: 'policy-r1', active: true, pending_apply: false, backend: { id: 'native-mihomo', display_name: 'NetFleet + Mihomo' },
        policy_source: { kind: 'bundle', ref: 'bundle:base-v1', display_name: '默认策略' }, policy_source_options: [], policy_groups: ['OUTBOUND'],
        recovery_profile: { ref: 'file:custom.json', display_name: '本地配置' }, recovery_profile_options: [], providers: [], provider_options: [], regions: [], region_options: [],
        capabilities: [{ id: 'standard', display_name: '常规出口', enabled: true, mode: 'automatic', region_ids: [], entry_group: 'OUTBOUND', policy_groups: [] }], routing_rules: [],
        automation: { enabled: true, selection_interval_seconds: 1800, subscription_refresh_enabled: true, subscription_refresh_interval_seconds: 43200 },
        safety: { region_switch_margin_ms: 150, leaf_switch_margin_ms: 150, runtime_grace_seconds: 120, latency_url: 'https://latency.example', path_probe_url: 'https://probe.example', guard_probe_url: 'https://guard.example' } };
}
function controller() {
    const policy = policyConfig();
    return { busy: false, liveDataReady: true, redraw() {}, refreshes: 0, async refreshData() { this.refreshes++; },
        config: policy, configDraft: clone(policy), configSection: 'network', status: { providers: [], regions: [], runtime: {} },
        showConfigWizard() {}, discardConfig() {}, validateConfig() {}, previewConfigChanges() {}, saveConfig() {}, confirmConfigApply() {} };
}
"""


class LuciManagementTests(unittest.TestCase):
    def run_js(self, source):
        result = subprocess.run(
            ["node", "-e", HARNESS + "\n(async () => {\n" + source + "\n})().catch(error => { console.error(error.stack || error); process.exit(1); });", str(RESOURCES)],
            text=True, capture_output=True, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_network_form_sends_complete_revision_bound_request(self):
        self.run_js(r"""
const sent = [];
let reads = 0;
const api = { networkGet: async () => { reads++; return networkState(); }, networkValidate: async request => { sent.push(['validate', request]); }, networkApply: async request => { sent.push(['apply', request]); return { ok: true }; } };
const management = module('management.js', api);
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
await fire(button(modal.content, '确认'));
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
owner.maintenanceState = maintenanceState(); owner.configSection = 'files';
root = config.render(owner);
assert(button(root, '导入配置'));
assert(!button(root, '应用配置'));
""")

    def test_stale_live_state_blocks_writes_and_failed_apply_preserves_recovery(self):
        self.run_js(r"""
let writes = 0;
const api = { networkGet: async () => networkState(), networkApply: async () => { writes++; const error = new Error('network_revision_conflict'); error.detail = { rollback: { ok: true } }; throw error; } };
const management = module('management.js', api);
const owner = controller(); await management.load(owner, 'network');
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
root = management.network(owner);
fire(button(root, '应用网络配置'));
owner.liveDataReady = false;
await fire(button(modal.content, '确认'));
assert.equal(writes, 0, 'confirmation must recheck live state');
owner.liveDataReady = true;
fire(button(management.network(owner), '应用网络配置'));
await fire(button(modal.content, '确认'));
assert.equal(writes, 1);
assert.equal(owner.busy, false);
assert(notifications.some(item => item.text.includes('网络配置已变化') && item.text.includes('已恢复操作前状态')));
owner.networkState = { available: false, reason: 'native_backend_required' };
assert(!button(management.network(owner), '应用网络配置'));
""")

    def test_profile_import_is_memory_only_and_clears_after_save_or_cancel(self):
        self.run_js(r"""
const saved = [];
const api = { maintenanceGet: async () => maintenanceState(), profileSave: async value => { saved.push(clone(value)); }, profileGet: async () => ({ revision: 'maintenance-r1', profile: { id: 'custom.json', content: 'private-profile-body' } }) };
const management = module('management.js', api);
const owner = controller(); await management.load(owner, 'maintenance');
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
""")

    def test_config_rules_send_cidr_and_exclusive_direct_target(self):
        self.run_js(r"""
const config = configModule({});
const owner = controller(); owner.configSection = 'routing';
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
const api = new Function('baseclass', 'rpc', 'fs', 'request', 'L', 'window', fs.readFileSync(path.join(resources, 'api.js'), 'utf8'))(baseclass, rpc, {}, {}, { env: { rpctimeout: 20 } }, {});
owner.validateConfig = () => api.configValidate(config.request(owner.configDraft));
await fire(button(config.render(owner), '校验配置'));
assert.equal(wire[0].method, 'config_validate');
assert.deepEqual(wire[0].args[0].routing_rules, [{ kind: 'ip_cidr', value: '2001:db8::/32', capability: 'standard' }]);
""")

    def test_luci_file_transport_uses_authenticated_upload_and_small_rpc_reference(self):
        self.run_js(r"""
const calls = [], posts = [], reads = [];
let uploadFails = false, envelopeFails = false;
const rpc = { getSessionID: () => 'fixture-session', declare: options => (...args) => { calls.push({ method: options.method, args, nobatch: options.nobatch }); return Promise.resolve({ ok: true, result: { saved: true } }); } };
const request = { post: async (url, form) => { posts.push({ url, form }); return { ok: !uploadFails, json: () => envelopeFails ? { failure: [1, 'Operation not permitted'] } : uploadFails ? { error: 'denied' } : {} }; } };
const localFs = { exec_direct: async (...args) => { reads.push(args); return { ok: true, result: { filename: 'netfleet-backup.json', backup: {} } }; } };
const L = { env: { rpctimeout: 20, cgi_base: '/cgi-bin' } };
const window = { crypto: { getRandomValues: value => { value.fill(7); return value; } } };
const api = new Function('baseclass', 'rpc', 'fs', 'request', 'L', 'window', fs.readFileSync(path.join(resources, 'api.js'), 'utf8'))(baseclass, rpc, localFs, request, L, window);
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
await api.profileGet('local.json'); await api.backupExport();
assert.deepEqual(reads, [['/usr/libexec/opl-netfleet-transfer', ['profile-get', 'local.json'], 'json'], ['/usr/libexec/opl-netfleet-transfer', ['backup-export'], 'json']]);
uploadFails = true;
await assert.rejects(api.profileSave(profile), /transfer_upload_failed/);
uploadFails = false; envelopeFails = true;
await assert.rejects(api.profileSave(profile), /transfer_upload_failed/);
assert.equal(calls.length, 2, 'failed upload must not invoke mutation RPC');
assert.equal(L.env.rpctimeout, 20);
""")

    def test_dashboard_updates_only_the_confirmed_resource_version(self):
        self.run_js(r"""
let checks = 0, updates = [];
const initial = { id: 'zashboard', available: true, managed: true, installed_version: null, available_version: null, update_available: false, checked_at: null };
const candidate = { ...initial, available_version: 'v3.0.0', update_available: true, checked_at: 100 };
const api = { dashboardCheck: async () => { checks++; return clone(candidate); }, dashboardUpdate: async version => { updates.push(version); return { ...candidate, installed_version: version, update_available: false }; }, coreAction: async () => { throw new Error('dashboard must not restart core'); } };
const managed = module('managed.js', api);
const owner = controller(); owner.components = { dashboard: clone(initial), components: [], dependencies: [], feed: { configured: false } };
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
""")

    def test_component_checks_serialize_sources_and_preserve_partial_failure(self):
        self.run_js(r"""
const calls = [];
const owner = controller();
const snapshot = { supported: true, components: [], dependencies: [], feed: { configured: true, checked_at: 100 }, dashboard: { managed: true, available: true } };
owner.components = clone(snapshot);
const operation = { id: 'check-1', kind: 'packages', subject: 'feed', state: 'running', phase: 'checking', started_at: 100 };
let releaseDashboard;
const api = {
  dashboardCheck: () => { calls.push('dashboard'); return new Promise((resolve, reject) => { releaseDashboard = () => reject(new Error('dashboard_release_check_failed')); }); },
  componentsCheck: async () => { calls.push('packages'); return { operation }; },
  operationGet: async () => ({ packages: { ...operation, state: 'succeeded', finished_at: 101 } }),
  componentsGet: async () => clone(snapshot),
};
const managed = module('managed.js', api);
let root = managed.components(owner);
assert.equal(all(root, node => node.tag === 'button' && text(node) === '检查更新').length, 1);
const pending = fire(button(root, '检查更新'));
assert.deepEqual(calls, ['dashboard']);
assert(button(managed.components(owner), '正在检查更新…').disabled);
releaseDashboard();
await pending; await tick();
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
""")

    def test_operation_results_dismiss_without_changing_owner_or_hiding_new_work(self):
        self.run_js(r"""
const records = new Map();
global.sessionStorage = { getItem: key => records.get(key), setItem: (key, value) => records.set(key, value) };
const managed = module('managed.js', {});
const owner = controller();
const done = { id: 'operation-1', kind: 'subscription', state: 'succeeded', phase: 'done', started_at: 100, finished_at: 137, updated_at: 137, total: 3, completed: 3, subject: 'private-name' };
owner.operations = { subscription: clone(done) };
let root = managed.operationNode(owner, 'subscription');
assert(text(root).includes('完成于 ' + new Date(137000).toLocaleString()));
assert(text(root).includes('耗时 37 秒'));
assert(!text(root).includes('[object HTMLElement]'));
fire(find(root, node => node.attrs['aria-label'] === '关闭机场订阅更新结果'));
assert.deepEqual(owner.operations.subscription, done, 'dismiss never changes the device snapshot');
assert(managed.operationNode(owner, 'subscription').attrs.hidden);
const reloaded = controller(); reloaded.operations = clone(owner.operations);
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
""")

    def test_closed_component_failure_keeps_current_status_and_diagnostics(self):
        self.run_js(r"""
const managed = module('managed.js', {});
const owner = controller();
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
""")

    def test_components_group_versions_and_keep_failures_actionable(self):
        self.run_js(r"""
const owner = controller();
const base = { managed: true, update_available: false, reason: null, installed_version: '1.0.0-r1', available_version: '1.0.0-r1' };
owner.components = { supported: true, architecture: 'aarch64_generic', feed: { configured: true, checked_at: 100, url: 'https://packages.example/netfleet' }, components: [
  { ...base, id: 'netfleet', label: 'NetFleet' }, { ...base, id: 'luci', label: 'LuCI 界面' },
  { ...base, id: 'mihomo', label: 'Mihomo', installed_version: '1.19.29', running_version: 'v1.19.30', available_version: '1.19.30-r1', update_available: true }
], dependencies: [{ label: 'curl', available: false }], dashboard: { managed: true, available: true } };
const managed = module('managed.js', {});
let root = managed.components(owner);
assert.equal(all(root, node => node.tag === 'tbody')[0].children.length, 3);
assert(text(root).includes('运行版本与安装记录不一致'));
assert(text(root).includes('已安装，可使用'));
assert(!text(root).includes('不适用'));
assert(!text(root).includes('未提供'));
assert(!text(root).includes('[object HTMLElement]'));
const metadata = find(root, node => node.tag === 'dl' && node.attrs.class === 'netfleet-component-meta');
assert.equal(all(metadata, node => node.tag === 'dt').length, 3);
assert.equal(all(metadata, node => node.tag === 'dd').length, 3);
assert(text(metadata).includes('aarch64_generic'));
assert(text(metadata).includes('https://packages.example/netfleet'));
assert(find(root, node => node.tag === 'details' && text(node).includes('缺少 1 项')).open);
fire(button(root, '更新软件包'));
assert(text(modal.content).includes('当前运行 v1.19.30，安装记录 1.19.29'));
owner.components.components[2].installed_version = '1.19.30-r1';
assert(!text(managed.components(owner)).includes('运行版本与安装记录不一致'));
owner.components.components[2].update_available = false;
owner.components.components[1].installed_version = '0.9.0-r1';
owner.components.components[1].update_available = true;
assert(button(managed.components(owner), '更新'), 'an older LuCI package must still be updatable with the paired NetFleet package');
owner.operations = { packages: { kind: 'packages', state: 'failed', error: 'rollback_runtime_failed', recovery: 'failed', started_at: 100, finished_at: 102 } };
assert(text(managed.components(owner)).includes('恢复失败'));
owner.liveDataReady = false;
assert(button(managed.components(owner), '检查更新').disabled);
""")

    def test_optional_component_inventory_is_local_readonly_and_deduplicated(self):
        self.run_js(r"""
const owner = controller();
const extension = { id: 'https-compat', label: 'HTTPS 兼容', kind: 'optional', package: 'opl-netfleet-https-compat',
  installed_version: '0.2.0-r1', api_version: 93, compatible: true, available: true, state: 'ready', reason: null,
  dependencies: [{ id: 'mitmproxy', available: true, installed_version: '12.2.3' }], ui: ['config:compatibility'] };
owner.components = { supported: true, feed: { configured: false }, components: [], dependencies: [{ id: 'curl', label: 'curl', available: true }],
  extensions: [clone(extension), { ...extension, id: 'zashboard', label: 'Zashboard', kind: 'resource' }], dashboard: { available: true, managed: true } };
const managed = module('managed.js', {});
let root = managed.components(owner);
assert.equal(all(root, node => node.tag === 'tbody')[0].children.length, 2);
assert.equal(all(root, node => node.tag === 'strong' && text(node) === 'Zashboard').length, 1);
let row = find(root, node => node.tag === 'tr' && text(node).includes('HTTPS 兼容'));
assert(text(row).includes('0.2.0-r1'));
assert(text(row).includes('可配置'));
assert(!text(row).includes('已就绪'));
assert(!find(row, node => node.tag === 'details').open);
assert(text(row).includes('mitmproxy：12.2.3'));
assert(!text(row).includes('93'));
assert.deepEqual(all(row, node => node.tag === 'button').map(text), ['配置']);
fire(button(row, '配置'));
assert.equal(owner.currentView, 'config');
assert.equal(owner.configSection, 'compatibility');
owner.components.extensions[0] = { ...extension, installed_version: null, state: 'not_installed', available: false, reason: 'extension_component_not_installed',
  dependencies: [{ id: 'mitmproxy', available: false, installed_version: null }] };
root = managed.components(owner);
row = find(root, node => node.tag === 'tr' && text(node).includes('HTTPS 兼容'));
assert(text(row).includes('未安装'));
assert(text(row).includes('未安装可选模块'));
assert(!text(row).includes('extension_component_not_installed'));
assert(!text(row).includes('mitmproxy'));
assert(!find(row, node => node.tag === 'details'));
assert.equal(all(row, node => node.attrs.class === 'is-warning').length, 0);
assert.equal(all(root, node => node.attrs.role === 'alert').length, 0);
assert(text(root).includes('运行依赖正常'));
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
  ['backend_unsupported', 'extension_backend_unsupported', '当前后端不支持此模块']
]) {
  owner.components.extensions[0] = { ...extension, state, reason: code, available: false,
    dependencies: [{ id: 'mitmproxy', available: false, installed_version: null }, { id: 'openssl', available: null, installed_version: null }] };
  root = managed.components(owner);
  row = find(root, node => node.tag === 'tr' && text(node).includes('HTTPS 兼容'));
  assert(text(row).includes(message));
  assert(text(row).includes('mitmproxy：缺少'));
  assert(text(row).includes('openssl：未确认'));
  assert(find(row, node => node.tag === 'details').open);
  assert.equal(all(root, node => node.attrs.role === 'alert').length, 0);
}
""")

    def test_unmanaged_compatibility_preserves_revision_bound_disable(self):
        self.run_js(r"""
const owner = controller();
const state = { installed: true, managed: false, requested: true, intercepting: false, active_connections: 2, revision: 'compat-r1',
  reason: 'engine_unavailable', management_reason: 'extension_api_incompatible', config: { rules: [], devices: [] }, rules: {}, trust: {}, events: [] };
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
const compatibility = module('compatibility.js', api);
let root = compatibility.render(owner);
assert(text(root).includes('模块接口与当前 NetFleet 不兼容'));
assert(text(root).includes('兼容引擎未就绪'));
for (const name of ['连接验证', '人工恢复', '新增规则', '新增设备']) assert(button(root, name).disabled, name);
for (const name of ['刷新状态', '导出诊断']) assert(!button(root, name).disabled, name);
const toggle = find(root, node => node.tag === 'input' && node.attrs.type === 'checkbox');
assert(toggle.checked);
assert(!toggle.disabled, 'an incompatible installed module must remain stoppable');
const stopping = fire(toggle, 'change', { checked: false });
assert(text(modal.content).includes('停止接管新连接'));
await fire(button(modal.content, '确认'));
await stopping;
assert.deepEqual(disabled, [{ revision: 'compat-r1' }]);
assert.equal(reads, 1);
root = compatibility.render(owner);
assert(find(root, node => node.tag === 'input' && node.attrs.type === 'checkbox').disabled);
assert(text(root).includes('仍有 2 条连接'));
assert(!button(root, '导出诊断').disabled);
await fire(button(root, '刷新状态'));
assert.equal(reads, 2);
""")

    def test_compatibility_keeps_legacy_capabilities_and_rechecks_confirmation(self):
        self.run_js(r"""
const owner = controller();
owner.compatibility = { installed: true, requested: false, intercepting: false, active_connections: 0, revision: 'compat-r1',
  reason: 'disabled', config: { rules: [], devices: [] }, rules: {}, trust: {}, events: [] };
let enables = 0, applies = 0;
const api = { compatibilityEnable: async () => { enables++; }, compatibilityApply: async () => { applies++; },
  compatibilityGet: async () => clone(owner.compatibility) };
const compatibility = module('compatibility.js', api);
let root = compatibility.render(owner);
assert(!button(root, '新增规则').disabled, 'absence of managed must preserve the existing contract');
let toggle = find(root, node => node.tag === 'input' && node.attrs.type === 'checkbox');
assert(!toggle.disabled);
const enabling = fire(toggle, 'change', { checked: true });
owner.compatibility.managed = false;
await fire(button(modal.content, '确认'));
await enabling;
assert.equal(enables, 0, 'a newly blocked module must not enable from an old confirmation');
owner.compatibility.managed = true;
root = compatibility.render(owner);
fire(button(root, '新增规则'));
const saving = fire(button(modal.content, '保存'));
owner.compatibility.managed = false;
await fire(button(modal.content, '确认'));
await saving;
assert.equal(applies, 0, 'an open edit must not bypass a refreshed capability denial');
owner.compatibility.installed = false;
owner.compatibility.requested = true;
owner.compatibility.reason = 'extension_component_not_installed';
root = compatibility.render(owner);
toggle = find(root, node => node.tag === 'input' && node.attrs.type === 'checkbox');
assert(toggle.disabled, 'an absent owner cannot receive disable');
assert(!button(root, '刷新状态').disabled);
assert(text(root).includes('未安装可选模块'));
assert(!text(root).includes('extension_component_not_installed'));
""")


if __name__ == "__main__":
    unittest.main()
