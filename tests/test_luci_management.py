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
    const node = { tag, attrs: attrs || {}, children: Array.isArray(children) ? children : children == null ? [] : [children] };
    node.value = node.attrs.value == null ? tag === 'textarea' ? text(node.children) : '' : String(node.attrs.value);
    Object.defineProperty(node, 'disabled', { get: () => !!node.attrs.disabled, set: value => { node.attrs.disabled = value; } });
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
global.document = { body: { appendChild() {} } };
const baseclass = { extend: value => value };
function module(name, api) {
    return new Function('baseclass', 'ui', 'api', 'E', fs.readFileSync(path.join(resources, name), 'utf8'))(baseclass, ui, api, E);
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
const management = module('management.js', api);
const owner = controller(); owner.components = { dashboard: clone(initial) };
let root = management.dashboard(owner);
assert.equal(checks, 0, 'render must not query upstream');
assert(text(root).includes('版本未记录'));
assert(button(root, '更新资源').disabled);
await fire(button(root, '检查更新'));
assert.equal(checks, 1);
root = management.dashboard(owner);
fire(button(root, '更新资源'));
owner.liveDataReady = false;
await fire(button(modal.content, '确认'));
assert.deepEqual(updates, [], 'a confirmation opened before disconnect must not authorize an update');
owner.liveDataReady = true;
fire(button(management.dashboard(owner), '更新资源'));
await fire(button(modal.content, '确认'));
assert.deepEqual(updates, ['v3.0.0']);
assert.equal(owner.components.dashboard.installed_version, 'v3.0.0');
assert.equal(owner.dashboardBusy, false);
""")


if __name__ == "__main__":
    unittest.main()
