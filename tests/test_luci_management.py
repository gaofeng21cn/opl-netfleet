import pathlib
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "openwrt/files/usr/libexec/opl-netfleet/plugins/product-ui/resources"
SHELL_RESOURCES = ROOT / "openwrt/luci-app-netfleet/htdocs/luci-static/resources/netfleet"

HARNESS = r"""
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const resources = process.argv[1];
const shellResources = process.argv[2];
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
        Object.defineProperty(node, name, { get: () => node.attrs[name] != null, set: value => { if (value) node.attrs[name] = ''; else delete node.attrs[name]; } });
    }
    node.setAttribute = (name, value) => { node.attrs[name] = String(value); };
    node.getAttribute = name => node.attrs[name] ?? null;
    Object.defineProperty(node, 'textContent', { get: () => text(node), set: value => { node.children = [value]; } });
    function parent(items) { items.forEach(item => { if (Array.isArray(item)) parent(item); else if (item && typeof item === 'object') item.parent = node; }); }
    parent(node.children);
    node.remove = () => {};
    node.click = () => node.attrs.click && node.attrs.click({ target: node });
    node.replaceChildren = (...items) => { node.children = items; parent(items); };
    node.reportValidity = () => !node.required || !!node.value;
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
global.L = { url: (...parts) => '/cgi-bin/luci/' + parts.join('/') };
global.crypto = require('node:crypto').webcrypto;
const baseclass = { extend: value => value };
function module(name, api) {
    if (name === 'compatibility.js') {
        const source = fs.readFileSync(path.join(resources, '../../https-compat/resources/manager.js'), 'utf8');
        return new Function('E', source.replace('export function', 'function') + '\nreturn createManager;')(E)({ api, ui, readOnly: () => false });
    }
    const product = new Function('baseclass', fs.readFileSync(path.join(resources, 'product.js'), 'utf8'))(baseclass);
    const advanced = new Function('baseclass', 'ui', 'E', fs.readFileSync(path.join(resources, 'advanced.js'), 'utf8'))(baseclass, ui, E);
    return new Function('baseclass', 'ui', 'api', 'E', 'managed', 'product', 'advanced', fs.readFileSync(path.join(resources, name), 'utf8'))(baseclass, ui, api, E, name === 'managed.js' ? null : module('managed.js', api), product, advanced);
}
function configModule(management) {
    return new Function('baseclass', 'ui', 'management', 'E', 'compatibility', fs.readFileSync(path.join(resources, 'config.js'), 'utf8'))(baseclass, ui, management, E, { render: () => null });
}
function modesModule(api, selectionRunner) {
    const source = fs.readFileSync(path.join(resources, 'product-pages.js'), 'utf8');
    const exports = source.slice(0, source.lastIndexOf('return baseclass.extend({')) +
        'return { progress: managed, regions: regionsPage, controls: operatingModeControls, controller: productController, summary: statusSummary, health: pathHealthLabel, region: currentRegion, mode: modeName };';
    const managed = module('managed.js', { operationGet: async () => ({}), ...api });
    if (selectionRunner) managed.runSelection = selectionRunner;
    const views = new Function('baseclass', 'ui', 'managed', 'E', fs.readFileSync(path.join(resources, 'product-views.js'), 'utf8'))(baseclass, ui, managed, E);
    return new Function('baseclass', 'ui', 'netfleet', 'E', 'managed', 'productViews', exports)(baseclass, ui, api, E, managed, views);
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
        showConfigWizard() {}, discardConfig() {}, previewConfigChanges() {}, saveConfig() {}, confirmConfigApply() {} };
}
"""


class LuciManagementTests(unittest.TestCase):
    def test_staged_modules_resolve_every_versioned_dependency(self):
        with tempfile.TemporaryDirectory(prefix="netfleet-luci-assets-") as directory:
            resources = pathlib.Path(directory) / "resources"
            package = ROOT / "openwrt/luci-app-netfleet"
            installs = re.findall(r"\$\(INSTALL_DATA\) \./htdocs/luci-static/resources/(\S+) \$\(1\)/www/luci-static/resources/(\S+)", (package / "Makefile").read_text())
            self.assertTrue(installs)
            for source, destination in installs:
                target = resources / destination
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(SHELL_RESOURCES.parent / source, target)
            result = subprocess.run(["sh", str(ROOT / "openwrt/luci-app-netfleet/stage-assets.sh"), str(resources), "vtest"], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            for script in resources.rglob("*.js"):
                for dependency in re.findall(r"require (netfleet\.[A-Za-z0-9_.]+)", script.read_text()):
                    self.assertTrue((resources / (dependency.replace(".", "/") + ".js")).is_file(), dependency)

    def run_js(self, source):
        result = subprocess.run(
            ["node", "-e", HARNESS + "\n(async () => {\n" + source + "\n})().catch(error => { console.error(error.stack || error); process.exit(1); });", str(RESOURCES), str(SHELL_RESOURCES)],
            text=True, capture_output=True, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_advanced_json_invalid_draft_blocks_owner_call_and_omissions_are_preserved(self):
        self.run_js(r"""
const owner = controller();
owner.networkState = networkState();
owner.networkState.settings.advanced = { 'sniffer.sniff': { TLS: { port: [443] } }, 'tcp-concurrent': true };
owner.networkState.resources.advanced_fields = [{ id: 'sniffer.sniff', label: '协议与端口', kind: 'sniff', group: '嗅探' }];
owner.networkDraft = clone(owner.networkState.settings);
let calls = 0;
const management = module('management.js', { networkValidate: async () => { calls++; return { changes: [] }; } });
let root = management.network(owner);
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
""")

    def test_network_default_rule_is_explicit_and_new_device_precedes_it(self):
        self.run_js(r"""
const state = networkState();
const fallback = { id: 'default', enabled: true, ipv4: [], ipv6: [], mac: [], proxy: true, dns: true };
state.settings.lan.rules.push(fallback);
const management = module('management.js', { networkGet: async () => state });
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
""")

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
""")

    def test_no_change_skips_write_and_read_failure_does_not_retry_success(self):
        self.run_js(r"""
let writes = 0;
const api = { networkGet: async () => networkState(), networkApply: async () => { writes++; return { state: 'applied' }; } };
const management = module('management.js', api);
const owner = controller(); await management.load(owner, 'network');
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
""")

    def test_subscription_and_selection_read_failure_keep_execution_result(self):
        self.run_js(r"""
const managed = module('managed.js', { operationGet: async () => ({ subscription: null, selection: null, packages: null }) });
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
owner.previewConfigChanges = () => api.configValidate(config.request(owner.configDraft));
await fire(button(config.render(owner), '校验与变更'));
assert.equal(wire[0].method, 'config_validate');
assert.deepEqual(wire[0].args[0].routing_rules, [{ kind: 'ip_cidr', value: '2001:db8::/32', capability: 'standard' }]);
owner.configDraft.routing_rules.push({ kind: 'domain_suffix', value: 'example.test', target: 'direct' });
root = config.render(owner);
fire(all(root, n => n.attrs['aria-label'] === '上移规则')[1]);
assert.equal(config.request(owner.configDraft).routing_rules[0].value, 'example.test');
assert.equal(config.request(owner.configDraft).routing_rules[1].value, '2001:db8::/32');

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
const owner = controller(); owner.componentsSection = 'software'; owner.components = { dashboard: clone(initial), components: [], dependencies: [], feed: { configured: false } };
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

    def test_component_first_read_is_pending_not_unsupported(self):
        self.run_js(r"""
const managed = module('managed.js', {});
const owner = controller();
let root = managed.components(owner);
assert(text(root).includes('正在读取已安装组件'));
assert(!text(root).includes('未提供组件管理接口'));
owner.componentsError = new Error('read failed');
root = managed.components(owner);
assert(text(root).includes('组件信息未能确认'));
assert(!text(root).includes('正在读取已安装组件'));
""")

    def test_component_checks_serialize_sources_and_preserve_partial_failure(self):
        self.run_js(r"""
const calls = [];
const owner = controller(); owner.componentsSection = 'software';
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
clearTimeout(owner.resultTimer);
""")

    def test_regions_rank_current_measurement_without_pinning_the_selected_region(self):
        self.run_js(r"""
const view = modesModule({});
const region = (id, selected, measured, historic) => ({id, display_name: id, selected, mode: 'automatic', available_count: 1,
 available_provider_count: 1, available_node_count: 1, measurement: measured == null ? null : {best_delay_ms: measured, measured_count: 1},
 last_best_delay_ms: historic, delay_sample_count: 2});
const status = {regions: [region('Japan', true, 93, 20), region('Singapore', false, 49, 99), region('Old', false, null, 1)]};
const page = view.regions(status, {});
const rows = all(page, node => node.tag === 'tr').filter(row => all(row, node => node.tag === 'td').length);
assert(text(rows[0]).startsWith('Singapore'));
assert(text(rows[1]).startsWith('Japan'));
assert.equal(rows[1].attrs.class, 'cbi-rowstyle-1');
assert(text(rows[2]).startsWith('Old'));
""")

    def test_measurement_keeps_success_quota_and_candidate_diagnostics_visible(self):
        self.run_js(r"""
const view = modesModule({});
const status = {providers: [{id:'airport', display_name:'示例机场'}], regions: [{id:'region', display_name:'示例地区', available_count:1, available_provider_count:1,
 measurement: {sampled_at:1788947164, best_delay_ms:41, measured_count:1, exclusions:{quota_exhausted:1}, entries:[
 {provider_id:'airport',region_id:'region',ok:true,delay_ms:41,quota_state:'available'},
 {provider_id:'other',region_id:'region',ok:false,quota_state:'exhausted',measurement_reason:'leaf_latency_unrecorded'}]}}]};
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
""")

    def test_measurement_current_quota_precedes_stale_health_and_recovers(self):
        self.run_js(r"""
const view = modesModule({});
const provider = {id:'airport', display_name:'机场', subscription_section:'source', quota:{state:'exhausted'}};
const entry = {provider_id:'airport', region_id:'region', ok:false, quota_state:'available', measurement_reason:'group_latency_failed'};
const status = {providers:[provider], subscriptions:[{section:'source',last_success:1789000000}], regions:[{id:'region',available_count:1,available_provider_count:1,
 measurement:{sampled_at:1788947164,measured_count:0,entries:[entry]}}]};
let item = all(view.regions(status,{}), n=>n.tag==='li').find(n=>text(n).includes('该次测速记录'));
assert.equal(text(item.children[1]),'流量已耗尽，不参与选优');
assert(text(item).includes('订阅更新于') && text(item).includes('未提供底层错误'));
// A later quota reset must not present the old exhausted sample as a current ban.
provider.quota = {state:'available',remaining_bytes:1073741824}; entry.quota_state='exhausted';
item = all(view.regions(status,{}), n=>n.tag==='li').find(n=>text(n).includes('该次测速记录'));
assert.equal(text(item.children[1]),'订阅配额记录：剩余 1.0 GiB');
assert(text(item).includes('该次测速时流量已耗尽'));
assert(!item.children.some(n=>text(n)==='流量已耗尽，不参与选优'));
""")

    def test_subscription_selection_is_one_operation_feedback(self):
        self.run_js(r"""
const managed = module('managed.js', {});
const owner = controller();
owner.operations = {
 subscription: { id: 'subscription-1', state: 'running', phase: 'selecting', started_at: 100, total: 3, completed: 3 },
 selection: { id: 'selection-1', parent_id: 'subscription-1', state: 'running', phase: 'checking', started_at: 110, total: 2, completed: 0 }
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
""")

    def test_operation_results_dismiss_without_changing_owner_or_hiding_new_work(self):
        self.run_js(r"""
const records = new Map();
global.sessionStorage = { getItem: key => records.get(key), setItem: (key, value) => records.set(key, value) };
const managed = module('managed.js', {});
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
const owner = controller(); owner.componentsSection = 'software';
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
const owner = controller(); owner.componentsSection = 'software';
const base = { managed: true, update_available: false, reason: null, installed_version: '1.0.0-r1', available_version: '1.0.0-r1' };
owner.components = { supported: true, architecture: 'aarch64_generic', feed: { configured: true, checked_at: 100, url: 'https://packages.example/netfleet' }, components: [
  { ...base, id: 'netfleet', label: 'NetFleet' }, { ...base, id: 'luci', label: 'LuCI 界面' },
  { ...base, id: 'mihomo', label: 'Mihomo', installed_version: '1.19.29', running_version: 'v1.19.30', available_version: '1.19.30-r1', update_available: true }
], dependencies: [{ label: 'curl', available: false }], dashboard: { managed: true, available: true } };
const managed = module('managed.js', {});
let root = managed.components(owner);
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
assert(text(modal.content).includes('LuCI 界面 1.2.0'));
assert(text(modal.content).includes('LuCI 1.2.0-r1'), 'original request identity remains in technical details');
owner.operations = { packages: { kind: 'packages', state: 'failed', error: 'rollback_runtime_failed', recovery: 'failed', started_at: 100, finished_at: 102 } };
assert(text(managed.components(owner)).includes('恢复失败'));
owner.liveDataReady = false;
assert(button(managed.components(owner), '检查更新').disabled);
""")

    def test_components_follow_user_order_and_keep_plugin_actions_in_scope(self):
        self.run_js(r"""
const owner = controller();
owner.components = { supported: true, feed: { configured: true }, components: [
  { id: 'netfleet', label: 'NetFleet', installed_version: '1.0.0' }
], dependencies: [], extensions: [
  { id: 'https-compat', label: 'HTTPS compatibility', kind: 'plugin', runtime: 'service', version: '0.9.2', revision: 'r1', enabled: true },
  { id: 'custom-plugin', label: 'Custom name', kind: 'plugin', runtime: 'process', version: '1.0.0', revision: 'r2' }
] };
const managed = module('managed.js', {});
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
assert(text(page).includes('HTTPS compatibility') && text(page).includes('https-compat') && text(page).includes('为指定设备和网站提供 HTTPS 协议兼容'));
assert(text(page).includes('Custom name'), 'unknown plugins retain the declared name');
assert(button(page, '查看状态'));
assert.deepEqual(all(page, node => node.tag === 'th').map(text), ['插件', '分类与用途', '版本', '配置', '运行管理']);
assert(!find(page, node => node.tag === 'details' && text(node).includes('编辑服务组合')).open);
""")

    def test_package_manager_link_uses_accessible_menu_route_and_reads_once(self):
        self.run_js(r"""
const owner = controller(); owner.componentsSection = 'plugins';
let menuReads = 0, componentReads = 0;
const plugin = { id: 'custom', label: 'Custom', kind: 'plugin', version: '1.0.0', revision: 'r1' };
const snapshot = { supported: true, feed: {}, components: [], dependencies: [], extensions: [plugin] };
ui.menu = { load: async () => {
  menuReads++;
  return { children: { admin: { satisfied: true, children: {
    forbidden: { title: 'Restricted', satisfied: false, action: { type: 'view', path: 'system/opkg' } },
    system: { satisfied: true, children: { 'package-manager': { title: 'Software', satisfied: true, action: { type: 'view', path: 'package-manager' } } } }
  } } } };
} };
const managed = module('managed.js', {
  componentsGet: async () => { componentReads++; return clone(snapshot); },
  pluginRead: async () => ({ loaded: false, revision: 'r1' })
});
await Promise.all([managed.loadComponents(owner), managed.loadComponents(owner)]);
await managed.loadComponents(owner);
assert.equal(componentReads, 2);
assert.equal(menuReads, 1, 'component refresh reuses the current menu');
let page = managed.components(owner);
const link = find(page, node => node.tag === 'a' && text(node) === '软件包管理 ↗');
assert.equal(link.attrs.href, '/cgi-bin/luci/admin/system/package-manager');
assert(!text(page).includes('此设备未提供软件包管理页面'));
fire(button(page, '查看状态')); await tick();
assert(!find(modal.content, node => node.tag === 'a'), 'package management stays in the directory, not every runtime dialog');

ui.menu.load = async () => ({ children: { admin: { children: { hidden: { title: 'Software', satisfied: false, action: { type: 'view', path: 'package-manager' } } } } } });
const missing = controller(); missing.componentsSection = 'plugins';
await managed.loadComponents(missing);
page = managed.components(missing);
assert(!find(page, node => node.tag === 'a'), 'an inaccessible menu must not create a guessed link');
assert(text(page).includes('此设备未提供软件包管理页面'));
ui.menu.load = async () => { throw new Error('menu unavailable'); };
const failed = controller(); failed.componentsSection = 'plugins';
await managed.loadComponents(failed);
assert.equal(failed.componentsError, null, 'menu failure does not hide the component inventory');
assert(!find(managed.components(failed), node => node.tag === 'a'));
""")

    def test_optional_component_inventory_is_local_readonly_and_deduplicated(self):
        self.run_js(r"""
const owner = controller(); owner.componentsSection = 'plugins';
const extension = { id: 'https-compat', label: 'HTTPS 兼容', kind: 'optional', package: 'opl-netfleet-https-compat',
  installed_version: '0.2.0-r1', api_version: 93, compatible: true, available: true, state: 'ready', reason: null,
  dependencies: [{ id: 'mitmproxy', available: true, installed_version: '12.2.3' }], ui: ['config:compatibility'] };
owner.components = { supported: true, feed: { configured: false }, components: [], dependencies: [{ id: 'curl', label: 'curl', available: true }],
  extensions: [clone(extension), { ...extension, id: 'zashboard', label: 'Zashboard', kind: 'resource' }], dashboard: { available: true, managed: true } };
const managed = module('managed.js', {});
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
owner.components.extensions[0] = { ...extension, installed_version: null, state: 'not_installed', available: false, reason: 'extension_component_not_installed',
  dependencies: [{ id: 'mitmproxy', available: false, installed_version: null }] };
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
  ['backend_unsupported', 'extension_backend_unsupported', '当前后端不支持此模块']
]) {
  owner.components.extensions[0] = { ...extension, state, reason: code, available: false,
    dependencies: [{ id: 'mitmproxy', available: false, installed_version: null }, { id: 'openssl', available: null, installed_version: null }] };
  root = managed.components(owner);
  row = find(root, node => node.tag === 'tr' && text(node).includes('HTTPS 兼容'));
  assert(text(row).includes(message));
  assert(text(row).includes('mitmproxy：缺少'));
  assert(text(row).includes('openssl：未确认'));
  assert(find(row, node => node.tag === 'details' && text(node).includes('mitmproxy')).open);
  assert.equal(all(root, node => node.attrs.role === 'alert').length, 0);
}
""")

    def test_operating_modes_use_live_state_revision_and_read_back_failures(self):
        self.run_js(r"""
let calls = [], fail = false;
const modes = modesModule({
  pluginsList: async () => ({ plugins: [{ id: 'activation', instance: 'default', revision: 'live-r2' }] }),
  pluginCall: async request => { calls.push(request); if (fail) throw new Error('runtime_mode_changed'); }
});
const owner = Object.assign(Object.create(modes.controller), controller(), { context: { readOnly: false, signal: { aborted: false } }, status: { operating_mode: 'mihomo', runtime: {} } });
let page = modes.controls(owner);
assert.equal(all(page, n => n.type === 'radio').length, 3);
assert.equal(find(page, n => n.type === 'radio' && n.checked).value, 'mihomo');
assert(button(page, '切换模式').disabled);
fire(find(page, n => n.value === 'netfleet'), 'change');
page = modes.controls(owner);
owner.refreshData = async () => { owner.refreshes++; owner.status.operating_mode = fail ? 'mihomo' : 'netfleet'; };
await fire(button(page, '切换模式'));
assert.equal(calls.length, 1);
assert.deepEqual(calls[0], { id: 'activation', instance: 'default', action: 'set-mode', revision: 'live-r2', confirm: true,
  params: { mode: 'netfleet', expected_mode: 'mihomo' } });
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
owner.liveDataReady = true; owner.context.readOnly = true;
await owner.runMode('openwrt', 'mihomo');
assert.equal(calls.length, 2, 'read-only view cannot mutate');
assert(text(modes.summary({ operating_mode: null, runtime: {} })).includes('状态未确认'));
assert(!text(modes.summary({ operating_mode: 'mihomo', runtime: { mihomo_running: true } })).includes('已关闭'));
const direct = { data_path: 'passthrough', alive: true, user_mode: 'native_profile' };
assert.equal(modes.health(direct), '已直连');
assert.equal(modes.region({}, direct), '直连');
assert.equal(modes.mode(direct), '原生直连');
""")

    def test_mode_progress_survives_rpc_disconnect_and_new_page_scope(self):
        self.run_js(r"""
let operation = { id: 'older-mode', kind: 'mode', state: 'failed', phase: 'checking_mode', started_at: 1, updated_at: 2 };
let release;
const accepted = new Promise(resolve => { release = resolve; });
const modes = modesModule({
  operationGet: async () => ({ mode: clone(operation) }),
  pluginsList: async () => ({ plugins: [{ id: 'activation', revision: 'live-mode-r1' }] }),
  pluginCall: async () => {
    operation = { id: 'mode-current', kind: 'mode', state: 'running', phase: 'resetting_candidates',
      started_at: Date.now() / 1000 - 15, updated_at: Date.now() / 1000, total: 2, completed: 0,
      subject: 'standard', requested_mode: 'netfleet', actual_mode: null };
    await accepted;
    const error = new Error('XHR request aborted by browser'); error.netfleetKind = 'request_aborted'; throw error;
  }
});
const owner = Object.assign(Object.create(modes.controller), controller(), {
  context: { readOnly: false, signal: { aborted: false } }, operations: { mode: clone(operation) },
  status: { operating_mode: 'mihomo', capabilities: [{ id: 'standard', display_name: '常规出口' }], runtime: {} }
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
release(); await request;
assert(owner.busy && owner.operationTimer, 'RPC disconnect must retain polling while the device operation runs');
operation = { ...operation, state: 'failed', phase: 'rolling_back', finished_at: Date.now() / 1000,
  error: 'candidate_group_reset_failed', actual_mode: 'mihomo', recovery: 'native' };
await modes.progress.readOperations(owner); await tick();
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
clearTimeout(owner.operationTimer); clearTimeout(owner.resultTimer); clearTimeout(reopened.resultTimer);
""")

    def test_region_choice_uses_capability_authority_and_live_readback(self):
        self.run_js(r"""
const calls = [];
const modes = modesModule({ selectRegion: async (...args) => { calls.push(args); return { selected: 'sg' }; } },
    async (owner, request) => { owner.busy = true; try { await request(); await owner.refreshData(); } finally { owner.busy = false; } });
const owner = controller(); Object.assign(owner, modes.controller);
owner.redraw = () => {};
owner.context = { readOnly: false };
owner.status = { runtime: {}, regions: [{id:'jp',display_name:'日本'}, {id:'sg',display_name:'新加坡'}], capabilities: [
    { id:'standard', display_name:'常规出口', enabled:true, can_select_region:true, selectable_regions:['jp','sg'], region_id:'jp' },
    { id:'ai', display_name:'AI 出口', enabled:true, can_select_region:true, selectable_regions:['jp'], region_id:'jp' }
] };
owner.refreshData = async () => { owner.refreshes++; owner.status.capabilities[0].user_mode = 'manual_region'; };
owner.chooseRegion(null, 'sg');
assert.equal(modal.title, '指定地区');
assert.deepEqual(all(modal.content, n => n.tag === 'select')[0].children.map(n => n.attrs.value), ['standard']);
assert(text(modal.content).includes('整轮后台自动选优暂停'));
await fire(button(modal.content, '确认切换'));
assert.deepEqual(calls, [['standard','sg']]);
assert.equal(owner.refreshes, 1);
assert.equal(owner.status.capabilities[0].user_mode, 'manual_region');
owner.chooseRegion('standard');
owner.liveDataReady = false;
await fire(button(modal.content, '确认切换'));
assert.equal(calls.length, 1, 'freshness lost after opening modal must reject submission');
modal = null;
owner.chooseRegion('standard');
assert.equal(modal, null, 'cached read cannot open a mutation');
owner.liveDataReady = true; owner.context.readOnly = true;
owner.chooseRegion('standard');
assert.equal(modal, null);
""")

    def test_dynamic_plugin_management_uses_current_identity_and_confirmation(self):
        self.run_js(r"""
const calls = [];
const plugin = { id: 'device-info', label: '设备信息', kind: 'plugin', runtime: 'process', version: '1.0.0-r2', revision: 'r1',
  package: 'opl-netfleet-plugin-device-info', actions: { inspect: 'read', reset: 'write' } };
const owner = controller(); owner.componentsSection = 'plugins';
owner.components = { supported: true, feed: {}, components: [], dependencies: [], extensions: [plugin] };
const managed = module('managed.js', {
  pluginRead: async request => { calls.push(['read', request]); return { loaded: false, ready: true, revision: 'r2' }; },
  pluginCall: async request => { calls.push(['write', request]); return { loaded: true, ready: true, revision: 'r3' }; },
  componentsGet: async () => owner.components,
});
let page = managed.components(owner);
assert.equal(calls.length, 0, 'inventory never starts or calls a plugin');
assert(text(page).includes('device-info') && text(page).includes('进程插件'));
assert.equal(text(find(page, n => n.tag === 'td' && text(n).startsWith('1.0.0')).children[0]), '1.0.0');
fire(button(page, '查看状态')); await tick();
assert.equal(calls[0][1].action, 'get');
assert(!find(modal.content, n => n.tag === 'select' || n.tag === 'textarea'), 'no raw RPC editor');
assert(button(modal.content, '重新加载').disabled);
fire(button(modal.content, '加载进程'));
assert.equal(modal.title, '确认加载进程');
assert.equal(calls.length, 1, 'write waits for confirmation');
fire(button(modal.content, '确认')); await tick();
assert.equal(calls[1][0], 'write');
assert.equal(calls[1][1].revision, 'r2', 'writes use fresh owner revision');
assert.equal(calls[1][1].confirm, true);
assert(text(modal.content).includes('运行就绪'));
assert(button(modal.content, '加载进程').disabled);
assert(!button(modal.content, '重新加载').disabled);
assert(text(modal.content).includes('完整版本：1.0.0-r2'));

const service = { ...plugin, id: 'activation', label: 'Activation', runtime: 'service', instance: 'review', revision: 'service-r1',
  actions: { 'get-mode': 'read', 'set-mode': 'write' } };
owner.components.extensions = [service];
const opened = []; owner.context = { navigate: id => opened.push(id) };
page = managed.components(owner);
fire(button(page, '查看状态')); await tick();
assert.equal(calls.at(-1)[1].instance, 'review');
assert(!find(modal.content, n => n.tag === 'select' || n.tag === 'textarea'));
assert(!button(modal.content, '加载进程') && !button(modal.content, '重新加载') && !button(modal.content, '卸载进程'),
  'service lifecycle belongs to the host');
assert(text(modal.content).includes('由 NetFleet 自动管理'));
fire(button(modal.content, '前往概览切换运行模式'));
assert.deepEqual(opened, ['plugin:product-ui:overview']);
""")

    def test_https_service_exposes_configuration_without_loading_engine(self):
        self.run_js(r"""
const owner = controller(); owner.componentsSection = 'plugins';
const opened = [];
owner.context = { navigate: id => opened.push(id) };
const plugin = { id: 'https-compat', label: 'HTTPS compatibility', kind: 'plugin', runtime: 'service',
  version: '0.8.0', revision: 'https-r1', enabled: true, configuration: { read: 'config-get', write: 'config-set' },
  ui: [{ id: 'settings', title: 'HTTPS 兼容', module: 'resources/page.js' }] };
owner.components = { supported: true, feed: {}, components: [], dependencies: [], extensions: [plugin] };
const managed = module('managed.js', {});
let page = managed.components(owner);
fire(button(page, '配置'));
assert.deepEqual(opened, ['plugin:https-compat:settings']);
assert(button(page, '查看状态'));
assert(text(page).includes('运行管理'));
assert(!text(page).includes('已启用'));
plugin.enabled = false;
page = managed.components(owner);
assert(button(page, '配置').disabled, 'disabled management plugin must not be loaded by opening its configuration');
assert(!button(page, '查看状态').disabled);
plugin.id = 'another-plugin'; plugin.enabled = true;
fire(button(managed.components(owner), '配置'));
assert.equal(opened.at(-1), 'plugin:another-plugin:settings', 'configuration navigation is manifest-driven');
""")

    def test_composition_preview_binds_edits_and_confirmation(self):
        self.run_js(r"""
const owner = controller(), calls = [];
owner.componentsSection = 'plugins';
owner.components = { supported: true, feed: {}, components: [], dependencies: [], extensions: [] };
const managed = module('managed.js', {
  systemGet: async () => ({ revision: 'current', config: { schema: 'opl-netfleet-system.v1', bindings: {}, enabled: {} }, defaults: { enabled: { note: true }, bindings: { 'note.store': 'note' } }, plugins: [{ id: 'note', services: [{ name: 'note.store', version: 1 }] }] }),
  systemValidate: async value => { calls.push(['validate', value]); return { valid: true, affected_plugins: ['note'] }; },
  systemApply: async value => { calls.push(['apply', value]); return { applied: true }; },
  componentsGet: async () => owner.components,
});
fire(button(managed.components(owner), '编辑服务组合')); await tick();
const editor = find(modal.content, node => node.tag === 'textarea');
assert(button(modal.content, '应用组合').disabled);
const enabled = find(modal.content, node => node.attrs?.['aria-label'] === '插件开关 note');
fire(enabled, 'change', { value: 'false' });
assert.equal(JSON.parse(editor.value).enabled.note, false);
fire(find(modal.content, node => node.attrs?.['aria-label'] === '插件开关 note'), 'change', { value: '' });
assert.equal(JSON.parse(editor.value).enabled.note, undefined, 'inherit removes the override');
fire(button(modal.content, '校验并预览影响')); await tick();
assert.equal(calls.length, 1); assert(text(modal.content).includes('note'));
editor.value = JSON.stringify({ schema: 'opl-netfleet-system.v1', bindings: {}, enabled: { note: true } });
fire(button(modal.content, '应用组合')); await tick();
assert.equal(calls.length, 1, 'editing invalidates the old preview even without an input event');
fire(button(modal.content, '校验并预览影响')); await tick();
fire(button(modal.content, '应用组合')); await tick();
assert.deepEqual(calls.at(-1), ['apply', { revision: 'current', config: JSON.parse(editor.value), confirm: true }]);
fire(button(modal.content, '关闭')); assert.equal(editor.value, '', 'closing clears private configuration');
owner.context = { readOnly: true };
assert(button(managed.components(owner), '编辑服务组合').disabled);
""")

    def test_product_factories_share_fetches_but_keep_page_guards(self):
        self.run_js(r"""
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
const source = fs.readFileSync(path.join(resources, 'entry.js'), 'utf8').replaceAll('import.meta.url', JSON.stringify('file://' + path.join(resources, 'entry.js')));
const entry = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
const first = new AbortController(), second = new AbortController();
const [a, b] = await Promise.all([entry.mountPage({ signal: first.signal, readOnly: false }, 'overview'), entry.mountPage({ signal: second.signal, readOnly: true }, 'config')]);
assert.equal(fetches, 8, 'parallel pages share resource loading without optional plugin assets');
assert.notEqual(a.api, b.api, 'each mount has its own permission guard');
assert.equal(await a.api.configSave(), 'saved');
await assert.rejects(b.api.configSave(), /plugin_read_only/);
first.abort(); await assert.rejects(a.api.status(), /plugin_scope_disposed/);
assert.equal(await b.api.status(), 'ok');
await entry.mountPage({ signal: second.signal, readOnly: false }, 'events');
assert.equal(fetches, 8, 'navigation does not fetch or compile the same revision again');
const retry = await import('data:text/javascript;base64,' + Buffer.from(source + '\n// different revision').toString('base64'));
fail = true; await assert.rejects(retry.mountPage({ signal: second.signal }, 'overview'), /product_ui_resource_unavailable/);
fail = false; assert.equal((await retry.mountPage({ signal: second.signal }, 'overview')).id, 'overview');
assert.equal(fetches, 24, 'failed load retries with a new resource batch');
""")

    def test_identity_source_setup_and_dynamic_device_binding(self):
        self.run_js(r"""
const owner = controller();
owner.compatibilityTab = 'devices';
owner.compatibility = { installed: true, requested: false, active_connections: 0, revision: 'compat-r1',
  config: { rules: [], devices: [{ id: 'mac', name: 'Mac', addresses: ['192.0.2.2'] }] }, trust: {}, rules: {}, events: [] };
let source = { loaded: false, ready: false, source_ready: false, revision: 'code-r1', config_revision: null,
  config: { source: 'local', enabled: false, interfaces: [] }, devices: [], binding: '1'.repeat(64) };
const calls = [];
const api = { compatibilityGet: async () => clone(owner.compatibility),
  pluginRead: async request => {
    calls.push(request);
    if (request.action === 'sync') source = { ...source, source_ready: true,
      devices: [{ mac: '02:00:00:00:00:01', name: 'Mac', addresses: ['192.0.2.2', '2001:db8::2'] }] };
    return clone(source);
  }, pluginCall: async request => {
    calls.push(request);
    assert.equal(request.revision, 'code-r1');
    if (request.action === 'load') source = { ...source, loaded: true, ready: true, config_revision: 'private-r1' };
    else {
      assert.equal(request.params.config_revision, 'private-r1', 'first configure uses revision returned by load');
      assert.deepEqual(request.params.config, { source: 'local', enabled: true, interfaces: ['br-lan'] });
      source = { ...source, config: request.params.config, config_revision: 'private-r2' };
    }
    return clone(source);
  }, compatibilityApply: async request => {
    assert.equal(request.revision, 'compat-r1');
    assert.deepEqual(request.config.devices[0].identity, { binding: '1'.repeat(64), mac: '02:00:00:00:00:01' });
    assert.deepEqual(request.config.devices[0].addresses, []);
    calls.push({ action: 'bound' });
  } };
owner.identitySource = clone(source);
const compatibility = module('compatibility.js', api);
let root = compatibility.render(owner);
fire(button(root, '管理来源'));
fire(find(modal.content, node => node.tag === 'input' && node.type === 'checkbox'), 'change', { checked: true });
const field = label => find(find(modal.content, node => node.tag === 'label' && text(node).startsWith(label)), node => node.tag === 'input');
assert(!find(modal.content, node => node.tag === 'input' && node.type === 'password'));
assert(!text(modal.content).includes('UniFi 控制器'));
fire(field('局域网观察接口'), 'input', { value: 'br-lan' });
await fire(button(modal.content, '保存并验证'));
assert.deepEqual(calls.filter(call => ['load', 'configure', 'sync'].includes(call.action)).map(call => call.action), ['load', 'configure', 'sync']);
assert.equal(owner.identitySource.source_ready, true);
root = compatibility.render(owner);
assert(!text(root).includes('fixture-secret'));
fire(button(root, '编辑'));
fire(find(modal.content, node => node.tag === 'select'), 'change', { value: '02:00:00:00:00:01' });
await fire(button(modal.content, '保存'));
assert.equal(calls.at(-1).action, 'bound', 'compatibility refresh must not reread another plugin');
assert(calls.some(call => call.action === 'bound'));
""")

    def test_compatibility_retains_failure_when_current_probes_pass(self):
        self.run_js(r"""
const owner = controller();
owner.compatibilityTab = 'diagnostics';
owner.compatibility = { installed: true, requested: true, intercepting: false, reason: 'manual_recovery_required',
  config: { rules: [], devices: [] }, recovery: { latched: true, faults: [1] }, engine_restart: { attempts: 4 },
  local_probes: { processing: { ok: true, duration_ms: 200, stage: 'http' } },
  last_failure: { at: 42, reason: 'processing_chain_failed', health_error: 'health_socket_timeout',
    local_probes: { processing: { ok: false, reason: 'timeout', stage: 'http', duration_ms: 1510, timeout_ms: 1400 } } } };
const manager = module('compatibility.js', {});
let root = manager.render(owner);
assert(text(root).includes('本地健康接口超时'));
assert(text(root).includes('1510 ms / 1400 ms'));
assert(text(root).includes('1 次独立故障'));
assert(text(root).includes('4 次'));
assert(button(root, '恢复模块'));
owner.compatibility.reason = 'maintenance';
owner.compatibility.recovery.latched = false;
assert(button(manager.render(owner), '恢复模块'), 'maintenance requires an explicit recovery action');
owner.compatibility.events = [{ ...owner.compatibility.last_failure }];
delete owner.compatibility.last_failure;
root = manager.render(owner);
assert(text(root).includes('1510 ms / 1400 ms'), 'old engine event still explains the failure');
owner.compatibilityLive = false;
root = manager.render(owner);
assert(!text(root).includes('1510 ms'), 'failure diagnostics are never restored from display cache');
""")

    def test_compatibility_cached_content_is_not_write_authority(self):
        self.run_js(r"""
const owner = controller();
owner.compatibilityLive = false;
owner.compatibility = { installed: true, requested: true, intercepting: false, reason: 'engine_unavailable',
  config: { rules: [{ id: 'site', name: 'Site', domain: 'service.example', port: 443, strategy: 'h2', enabled: true, devices: ['mac'] }],
    devices: [{ id: 'mac', name: 'Mac', addresses: ['192.0.2.2'] }] },
  rules: {}, trust: {}, rule_recovery: { site: { intercepting: true } } };
let reads = 0, rejectRead;
const api = { compatibilityGet: () => { reads++; return new Promise((_, reject) => { rejectRead = reject; }); },
  pluginRead: () => { throw new Error('tab must not load another plugin'); } };
const manager = module('compatibility.js', api);
let root = manager.render(owner);
assert(button(root, '新增规则').disabled);
assert(text(root).includes('Site'));
assert(!text(root).includes('正在接管'), 'module bypass overrides stale rule interception');
await fire(button(root, '设备与信任'));
root = manager.render(owner);
assert(text(root).includes('Mac'));
assert(button(root, '新增设备').disabled);
assert.equal(reads, 0);
const pending = manager.refresh(owner);
assert.equal(manager.refresh(owner), pending, 'refresh is single-flight');
rejectRead(new Error('offline'));
await pending;
root = manager.render(owner);
assert(text(root).includes('Mac'));
assert(text(root).includes('刷新失败'));
assert(button(root, '新增设备').disabled);
assert.equal(reads, 1);
""")

    def test_compatibility_disposal_ignores_late_read(self):
        self.run_js(r"""
const owner = controller();
let disposed = false, complete, redraws = 0;
owner.disposed = () => disposed;
owner.redraw = () => { redraws++; };
const manager = module('compatibility.js', { compatibilityGet: () => new Promise(resolve => { complete = resolve; }) });
const pending = manager.refresh(owner);
disposed = true;
complete({ requested: true });
await pending;
assert.equal(owner.compatibility, undefined);
assert.equal(redraws, 1, 'late results must not redraw a departed page');
await manager.refresh(owner);
assert.equal(redraws, 1);
""")

    def test_compatibility_display_cache_is_bounded_and_redacted(self):
        self.run_js(r"""
const source = fs.readFileSync(path.join(resources, '../../https-compat/resources/display.js'), 'utf8');
const { displayCache } = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
const values = new Map();
const storage = () => ({ getItem: key => values.get(key), setItem: (key, value) => values.set(key, value) });
const cache = displayCache('device-a:revision-a', storage);
const state = { installed: true, requested: true, revision: 'PRIVATE_REVISION', ca_key: 'PRIVATE_KEY',
  config: { rules: [{ id: 'site', name: 'Site', domain: 'service.example', devices: ['mac'] }],
    devices: [{ id: 'mac', name: 'Mac', addresses: [], identity: { binding: 'PRIVATE_BINDING' } }] },
  device_addresses: { mac: ['2001:db8::2'] }, address_source: { config: { password: 'PRIVATE_PASSWORD' } },
  trust: { mac: { verified: true, runtimes: { codex_app: true }, token: 'PRIVATE_TOKEN' } },
  events: [{ body: 'PRIVATE_BODY' }] };
cache.write(state, Date.now(), 'devices');
assert(!values.get('device-a:revision-a').includes('PRIVATE_'));
const cached = cache.read();
assert.equal(cached.tab, 'devices');
assert.deepEqual(cached.state.config.devices[0].addresses, ['2001:db8::2']);
assert.equal(cached.state.revision, undefined);
assert.equal(displayCache('device-b:revision-a', storage).read(), null);
assert.equal(displayCache('device-a:revision-b', storage).read(), null);
values.set('device-a:revision-a', '{');
assert.equal(cache.read(), null);
values.set('device-a:revision-a', 'x'.repeat(128 * 1024 + 1));
assert.equal(cache.read(), null);
assert.doesNotThrow(() => displayCache('disabled', () => { throw Error('disabled'); }).write(state, Date.now(), 'rules'));
""")

    def test_compatibility_page_keeps_following_bypass_and_cleans_up(self):
        self.run_js(r"""
const source = fs.readFileSync(path.join(resources, '../../https-compat/resources/page.js'), 'utf8')
 .replace(/^import .*;$/gm, '').replace('export async function mount', 'async function mount')
 .replace('import.meta.url', "'https://router.test/page.js'");
const timers = new Map(); let serial = 0, view, dispose, refreshes = 0;
const signal = { aborted: false };
const dom = () => ({ append() {}, contains() { return false; }, querySelectorAll() { return []; }, replaceChildren() {}, remove() {} });
global.document = { hidden: false, createElement: dom, addEventListener() {}, removeEventListener() {} };
global.L.require = async () => ({});
const manager = { render: () => ({}), refresh: async c => { view = c; refreshes++; c.follow(); } };
const mount = new Function('createManager', 'displayCache', 'setTimeout', 'clearTimeout', source + ';return mount;')(
 () => manager, () => ({ read: () => null, write() {} }),
 (fn, ms) => { timers.set(++serial, {fn, ms}); return serial; }, id => timers.delete(id));
await mount({signal, container: dom(), scope: {effect: cb => { dispose = cb; }}});
assert.equal([...timers.values()][0].ms, 10000, 'failed or initial reads keep following');
for (const reason of ['lan_access_not_equivalent', 'rules_bypassed', 'future_reason']) {
 view.compatibilityLive = true; view.compatibility = {requested: true, intercepting: false, reason}; view.follow();
 assert.equal(timers.size, 1); assert.equal([...timers.values()][0].ms, 3000);
}
view.compatibility.intercepting = true; view.follow();
assert.equal([...timers.values()][0].ms, 10000, 'active traffic stats keep refreshing');
document.hidden = true; view.follow(); assert.equal(timers.size, 0);
document.hidden = false; view.compatibility = {requested: false, active_connections: 0}; view.follow();
assert.equal(timers.size, 0, 'disabled and drained stays idle');
view.compatibility.active_connections = 2; view.follow(); assert.equal(timers.size, 1);
signal.aborted = true; dispose(); assert.equal(timers.size, 0);
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
assert(button(root, '新增规则').disabled);
await fire(button(root, '诊断'));
root = compatibility.render(owner);
assert(!button(root, '连接验证'), 'status-only RPC must not be presented as a connection test');
assert(!button(root, '导出诊断').disabled);
assert(!button(root, '恢复模块'));
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
await fire(find(root, node => node.attrs['aria-label'] === '刷新兼容状态'));
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
assert(button(root, '新增规则').disabled, 'a rule requires a device');
assert(!button(root, '添加接入设备').disabled, 'absence of managed must preserve the existing contract');
let toggle = find(root, node => node.tag === 'input' && node.attrs.type === 'checkbox');
assert(!toggle.disabled);
const enabling = fire(toggle, 'change', { checked: true });
owner.compatibility.managed = false;
await fire(button(modal.content, '确认'));
await enabling;
assert.equal(enables, 0, 'a newly blocked module must not enable from an old confirmation');
owner.compatibility.managed = true;
root = compatibility.render(owner);
fire(button(root, '添加接入设备'));
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
assert(!find(root, node => node.attrs['aria-label'] === '刷新兼容状态').disabled);
assert(text(root).includes('未安装可选模块'));
assert(!text(root).includes('extension_component_not_installed'));
""")


if __name__ == "__main__":
    unittest.main()
