import { execFileSync } from 'node:child_process';
import { it } from 'vitest';

it('mounts the packaged product page through its actual ESM and LuCI module adapter', () => {
  const page = new URL('../../../openwrt/files/usr/libexec/opl-netfleet/plugins/product-ui/resources/pages/overview.js', import.meta.url).href;
  const host = new URL('../../../openwrt/luci-app-netfleet/htdocs/luci-static/resources/netfleet/plugin-host.js', import.meta.url).href;
  execFileSync(process.execPath, ['--input-type=module', '-e', `
    import assert from 'node:assert/strict';
    import { readFile } from 'node:fs/promises';
    const { createScope } = await import(${JSON.stringify(host)});
    const nodes = new Map();
    globalThis.E = (tag, attrs = {}, children = []) => {
      const node = { tag, attrs, children: Array.isArray(children) ? children : [children],
        replaceChildren(...values) { this.children = values; }, appendChild(value) { this.children.push(value); },
        getAttribute(name) { return this.attrs[name]; }, setAttribute(name, value) { this.attrs[name] = value; },
        remove() { this.removed = true; if (attrs.id) nodes.delete(attrs.id); } };
      if (attrs.id) nodes.set(attrs.id, node);
      return node;
    };
    globalThis.document = { head: E('head'), getElementById(id) { return nodes.get(id); }, querySelectorAll() { return []; } };
    globalThis.window = { localStorage: { getItem() { return null; }, setItem() {}, removeItem() {} }, location: { hostname: 'router.example' } };
    const polls = new Set();
    const poll = { add(callback) { polls.add(callback); }, remove(callback) { polls.delete(callback); } };
    const ui = { addNotification() {}, showModal() {}, hideModal() {} };
    const baseclass = { extend(properties) { return class { constructor() { Object.assign(this, properties); } }; } };
    const api = {
      async onboardingGet() { return { required: true, ready: false }; }, async nativeSetupGet() { return null; },
      async subscriptionsGet() { return { sources: [] }; }, async operationGet() { return {}; },
      async configGet() { return { revision: 'config-1' }; }, async dashboardGet() { return { available: false }; }
    };
    const methods = { onboarding_get: 'onboardingGet', native_setup_get: 'nativeSetupGet', subscriptions_get: 'subscriptionsGet', operation_get: 'operationGet', config_get: 'configGet', dashboard_get: 'dashboardGet' };
    const rpc = { declare({ method }) { return async (...params) => ({ ok: true, result: await api[methods[method]](...params) }); } };
    globalThis.L = { env: { rpctimeout: 20 }, require: async name => ({ baseclass, ui, poll, rpc, fs: {}, request: {}, 'netfleet.api': {} })[name] };
    globalThis.fetch = async url => ({ ok: true, text: () => readFile(new URL(url), 'utf8') });
    const scope = createScope(undefined, error => { throw error; });
    const container = E('section');
    const { mount } = await import(${JSON.stringify(page)});
    await mount({ container, scope, signal: scope.signal, readOnly: true });
    await new Promise(resolve => setImmediate(resolve));
    const text = node => typeof node === 'string' ? node : (node?.children || []).map(text).join('');
    assert.match(text(container), /首次设置 NetFleet/);
    assert.equal(nodes.get('netfleet-native-style').attrs.href.endsWith('/product-ui/resources/native.css'), true);
    assert.equal(polls.size, 1);
    const content = container.children[0];
    await scope.dispose();
    assert.equal(polls.size, 0);
    assert.equal(content.removed, true);
    assert.equal(nodes.has('netfleet-native-style'), false);
  `], { stdio: 'pipe' });
});
