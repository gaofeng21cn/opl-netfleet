import { readFileSync } from 'node:fs';
import { expect, it, vi } from 'vitest';

it('dispatches reads and mutations without depending on a visible-tab animation frame', async () => {
  const dispatch = vi.fn(async () => ({ ok: true, result: { available: true } }));
  const declarations: Record<string, any>[] = [];
  const rpc = { declare: (options: Record<string, any>) => {
    declarations.push(options);
    return options.nobatch ? dispatch : () => new Promise(() => {});
  } };
  const source = readFileSync(new URL('../../../openwrt/luci-app-netfleet/htdocs/luci-static/resources/netfleet/api.js', import.meta.url), 'utf8');
  const api = new Function('baseclass', 'rpc', 'L', source)({ extend: (value: unknown) => value }, rpc, { env: { rpctimeout: 20 } });
  await expect(api.dashboardGet()).resolves.toEqual({ available: true });
  await expect(api.subscriptionsGet()).resolves.toEqual({ available: true });
  await expect(api.status()).resolves.toEqual({ available: true });
  await api.subscriptionsSet({ revision: 'r1', source: { id: 'alpha', name: 'Alpha' } });
  expect(declarations.every(options => options.nobatch === true)).toBe(true);
  expect(dispatch).toHaveBeenCalledTimes(4);
});
