import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { renderToStaticMarkup } from 'react-dom/server';
import { afterEach, expect, it, vi } from 'vitest';
import { createPageHost, createScope, pluginPages, resourceUrl, type PluginContext, type PluginsSnapshot } from '../../../openwrt/luci-app-netfleet/htdocs/luci-static/resources/netfleet/plugin-host.js';
import { PluginApplication } from './PluginApplication';

const snapshot = (revision = 'revision-1'): PluginsSnapshot => ({ plugins: [{ id: 'example', revision, enabled: true, runtime: 'ucode', ui: [{ id: 'settings', title: '独立配置', module: 'resources/page.js' }], configuration: { read: 'settings_get', write: 'settings_save' } }] });
const page = () => pluginPages(snapshot())[0];
const container = () => ({}) as HTMLElement;
const api = () => ({ pluginsList: vi.fn(async () => snapshot()), pluginRead: vi.fn(async () => ({ count: 1 })), pluginCall: vi.fn(async () => ({ saved: true })) });
afterEach(() => vi.useRealTimers());

it('discovers enabled plugin pages and refuses resource traversal or external scripts', () => {
  const value = snapshot();
  value.plugins.push({ id: 'disabled', revision: '1', enabled: false, ui: [{ id: 'settings', title: 'Disabled', module: 'resources/page.js' }] });
  value.plugins.push({ id: 'unavailable', revision: '1', enabled: true, state: 'unavailable', ui: [{ id: 'settings', title: 'Unavailable', module: 'resources/page.js' }] });
  value.plugins[0].ui!.push({ id: 'unsafe', title: 'Unsafe', module: 'resources/../api.js' }, { id: 'remote', title: 'Remote', module: 'https://example.test/page.js' });
  expect(pluginPages(value)).toHaveLength(1);
  expect(resourceUrl(page())).toBe('/luci-static/resources/netfleet/plugins/example/revision-1/resources/page.js');
});

it('routes configuration and actions with revision, instance and write confirmation', async () => {
  const client = api();
  let context!: PluginContext;
  const selected = page();
  selected.plugin.instance = 'secondary';
  const host = createPageHost({ api: client, loadModule: async () => ({ mount: ctx => { context = ctx; } }) });
  await host.show(selected, container());
  await expect(context.configuration!.read()).resolves.toEqual({ count: 1 });
  await expect(context.configuration!.write({ count: 2 })).resolves.toEqual({ saved: true });
  expect(client.pluginRead).toHaveBeenCalledWith({ id: 'example', action: 'settings_get', params: {}, revision: 'revision-1', instance: 'secondary' });
  expect(client.pluginCall).toHaveBeenCalledWith({ id: 'example', action: 'settings_save', params: { count: 2 }, revision: 'revision-1', instance: 'secondary', confirm: true });
  await host.dispose();
  await expect(context.api.read('settings_get')).rejects.toThrow('plugin_scope_disposed');
});

it('keeps configured instances distinct in navigation and action scope', async () => {
  const value = snapshot();
  value.plugins.push({ ...value.plugins[0], instance: 'secondary' });
  const pages = pluginPages(value);
  expect(pages.map(item => item.id)).toEqual(['plugin:example:settings', 'plugin:example:secondary:settings']);
  expect(pages[1].title).toBe('独立配置 (secondary)');
  const navigate = vi.fn();
  const host = createPageHost({ api: api(), navigate, loadModule: async () => ({ mount: context => { context.navigate('other'); } }) });
  await host.show(pages[1], container());
  expect(navigate).toHaveBeenCalledWith('plugin:example:secondary:other', undefined);
  await host.dispose();
});

it('enforces changing read-only admission and discards pending results after disposal', async () => {
  let readOnly = false;
  let context!: PluginContext;
  let resolve!: (value: unknown) => void;
  const client = { ...api(), pluginRead: vi.fn(() => new Promise(done => { resolve = done; })) };
  const host = createPageHost({ api: client, readOnly: () => readOnly, loadModule: async () => ({ mount: ctx => { context = ctx; } }) });
  await host.show(page(), container());
  readOnly = true;
  expect(context.readOnly).toBe(true);
  await expect(context.configuration!.write({})).rejects.toThrow('plugin_read_only');
  expect(client.pluginCall).not.toHaveBeenCalled();
  const result = context.api.read('settings_get');
  await host.dispose();
  resolve({ count: 2 });
  await expect(result).rejects.toThrow('plugin_scope_disposed');
});

it('replaces revisions only after cleanup and releases subscriptions and timers', async () => {
  vi.useFakeTimers();
  const calls: string[] = [];
  const tick = vi.fn();
  const listener = vi.fn();
  const host = createPageHost({ api: api(), loadModule: async url => ({ mount: context => {
    calls.push('mount:' + url.split('/').at(-3));
    context.scope.interval(tick, 10);
    context.scope.on('update', listener);
    return () => { calls.push('cleanup'); };
  } }) });
  const element = container();
  await host.show(page(), element);
  await host.show(page(), element);
  vi.advanceTimersByTime(10);
  expect(tick).toHaveBeenCalledTimes(1);
  await host.show(pluginPages(snapshot('revision-2'))[0], container());
  expect(calls).toEqual(['mount:revision-1', 'cleanup', 'mount:revision-2']);
  await host.dispose();
  vi.advanceTimersByTime(100);
  expect(tick).toHaveBeenCalledTimes(1);
  const emitter = createScope();
  emitter.emit('update', {});
  expect(listener).not.toHaveBeenCalled();
  await emitter.dispose();
});

it('continues cleanup after failures and disposes late mount results', async () => {
  const failed = vi.fn();
  const cleaned = vi.fn();
  const scope = createScope(undefined, failed);
  scope.effect(cleaned);
  scope.scope().effect(() => { throw new Error('cleanup_failed'); });
  await scope.dispose();
  expect(failed).toHaveBeenCalledOnce();
  expect(cleaned).toHaveBeenCalledOnce();
  let finish!: (value: () => void) => void;
  const host = createPageHost({ api: api(), loadModule: async () => ({ mount: () => new Promise(resolve => { finish = resolve; }) }) });
  const mounting = host.show(page(), container());
  await Promise.resolve();
  await host.dispose();
  const lateCleanup = vi.fn();
  finish(lateCleanup);
  await mounting;
  expect(lateCleanup).toHaveBeenCalledOnce();
});

it('cannot remove a new host page when an older asynchronous cleanup finishes', async () => {
  const root: any = { child: null, replaceChildren(child: any) { this.child = child; }, ownerDocument: { createElement() { return { remove() { if (root.child === this) root.child = null; } }; } } };
  let finish!: () => void;
  const previous = createPageHost({ api: api(), loadModule: async () => ({ mount: context => { context.scope.effect(() => new Promise<void>(resolve => { finish = resolve; })); } }) });
  const next = createPageHost({ api: api(), loadModule: async () => ({ mount: () => {} }) });
  await previous.show(page(), root);
  const disposal = previous.dispose();
  await next.show(page(), root);
  const newPage = root.child;
  finish();
  await disposal;
  expect(root.child).toBe(newPage);
  await next.dispose();
  expect(root.child).toBeNull();
});

it('prevents a superseded async module from mounting and reports invalid modules', async () => {
  const staleMount = vi.fn();
  let finish!: (value: { mount: typeof staleMount }) => void;
  const error = vi.fn();
  const host = createPageHost({ api: api(), onError: error, loadModule: url => url.includes('revision-1') ? new Promise(resolve => { finish = resolve; }) : Promise.resolve({} as any) });
  const stale = host.show(page(), container());
  await Promise.resolve();
  await host.show(pluginPages(snapshot('revision-2'))[0], container());
  finish({ mount: staleMount });
  await stale;
  expect(staleMount).not.toHaveBeenCalled();
  expect(error.mock.calls[0][0].message).toBe('plugin_mount_missing');
});

it('reloads the complete static ES module graph through the native ESM loader', () => {
  const module = new URL('../../../openwrt/luci-app-netfleet/htdocs/luci-static/resources/netfleet/plugin-host.js', import.meta.url).href;
  const fixtures = new URL('./fixtures/', import.meta.url).href;
  execFileSync(process.execPath, ['--input-type=module', '-e', `
    import assert from 'node:assert/strict';
    const { createPageHost, pluginPages } = await import(${JSON.stringify(module)});
    const host = createPageHost({ api: {}, onError(error) { throw error; },
      loadModule: url => import(new URL(url.split('/').at(-3) + '/page.js', ${JSON.stringify(fixtures)}).href) });
    const selected = revision => pluginPages({ plugins: [{ id: 'example', revision, enabled: true,
      ui: [{ id: 'settings', title: 'Settings', module: 'resources/page.js' }] }] })[0];
    const first = { dataset: {} }, second = { dataset: {} };
    await host.show(selected('revision-1'), first);
    assert.equal(first.dataset.helper, 'helper-1');
    await host.show(selected('revision-2'), second);
    assert.equal(first.dataset.helper, undefined);
    assert.equal(second.dataset.helper, 'helper-2');
    await host.dispose();
  `], { stdio: 'pipe' });
});

it('renders independent React plugin navigation without status or product methods', () => {
  const html = renderToStaticMarkup(<PluginApplication client={api()} initialPlugins={snapshot()} readOnly />);
  expect(html).toContain('独立配置');
  expect(html).toContain('只读');
  expect(html).not.toContain('网络概览');
});

it('loads and replaces independent LuCI pages without product status or onboarding', async () => {
  const createNode = (tag: string, attrs: Record<string, any> = {}, children: any = []) => ({ tag, attrs, children: Array.isArray(children) ? children : [children], replaceChildren(...values: any[]) { this.children = values; }, appendChild(value: any) { this.children.push(value); } });
  const host = { show: vi.fn(async () => {}), dispose: vi.fn(async () => {}) };
  const client = api();
  const poll = { add: vi.fn(), remove: vi.fn() };
  let permitted = true;
  let options: any;
  const source = readFileSync(new URL('../../../openwrt/luci-app-netfleet/htdocs/luci-static/resources/view/netfleet/overview.js', import.meta.url), 'utf8');
  const shell = new Function('view', 'poll', 'api', 'E', 'window', 'document', 'MutationObserver', 'L', source)({ extend: (value: any) => value }, poll, client, createNode, { addEventListener() {}, removeEventListener() {} }, { body: {} }, class { observe() {} disconnect() {} }, { hasViewPermission: () => permitted });
  shell.render([{ pluginPages, resourceUrl, createPageHost: (value: any) => { options = value; return host; } }, { snapshot: snapshot() }]);
  expect(options.readOnly()).toBe(false);
  permitted = false;
  expect(options.readOnly()).toBe(true);
  expect(host.show).toHaveBeenCalledOnce();
  client.pluginsList.mockResolvedValueOnce(snapshot('revision-2'));
  await shell.refreshPlugins();
  expect(host.show).toHaveBeenCalledTimes(2);
  client.pluginsList.mockResolvedValueOnce({ plugins: [] });
  await shell.refreshPlugins();
  expect(host.dispose).toHaveBeenCalled();
  expect(shell.pages).toEqual([]);
});
