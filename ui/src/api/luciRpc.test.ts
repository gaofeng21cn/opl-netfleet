import { readFileSync } from 'node:fs';
import { expect, it, vi } from 'vitest';

it('dispatches reads and mutations without depending on a visible-tab animation frame', async () => {
  const dispatch = vi.fn(async () => ({ ok: true, result: { available: true } }));
  const declarations: Record<string, any>[] = [];
  const rpc = { declare: (options: Record<string, any>) => {
    declarations.push(options);
    return options.nobatch ? dispatch : () => new Promise(() => {});
  } };
  const source = readFileSync(new URL('../../../openwrt/files/usr/libexec/opl-netfleet/plugins/product-ui/resources/api.js', import.meta.url), 'utf8');
  const api = new Function('baseclass', 'rpc', 'L', source)({ extend: (value: unknown) => value }, rpc, { env: { rpctimeout: 20 } });
  await expect(api.dashboardGet()).resolves.toEqual({ available: true });
  await expect(api.subscriptionsGet()).resolves.toEqual({ available: true });
  await expect(api.status()).resolves.toEqual({ available: true });
  await api.subscriptionsSet({ revision: 'r1', source: { id: 'alpha', name: 'Alpha' } });
  await api.pluginsList();
  await api.pluginRead({ id: 'example', action: 'get' });
  await api.pluginCall({ id: 'example', action: 'set', confirm: true, revision: 'r1' });
  expect(declarations.every(options => options.nobatch === true)).toBe(true);
  expect(declarations.filter(options => ['plugins_list', 'plugin_read', 'plugin_call'].includes(options.method)).every(options => options.object === 'opl-netfleet.plugins')).toBe(true);
  expect(dispatch).toHaveBeenCalledTimes(7);
});

it('keeps the kernel transport limited to generic plugin RPC methods', async () => {
  const declarations: Record<string, any>[] = [];
  const dispatch = vi.fn(async () => ({ ok: true, result: { plugins: [] } }));
  const rpc = { declare: (options: Record<string, any>) => { declarations.push(options); return dispatch; } };
  const source = readFileSync(new URL('../../../openwrt/luci-app-netfleet/htdocs/luci-static/resources/netfleet/api.js', import.meta.url), 'utf8');
  const api = new Function('baseclass', 'rpc', 'L', source)({ extend: (value: unknown) => value }, rpc, { env: { rpctimeout: 20 } });
  await expect(api.pluginsList()).resolves.toEqual({ plugins: [] });
  expect(declarations.map(options => options.method)).toEqual(['plugins_list', 'plugin_read', 'plugin_call']);
  expect(declarations.every(options => options.object === 'opl-netfleet.plugins' && options.nobatch)).toBe(true);
});
