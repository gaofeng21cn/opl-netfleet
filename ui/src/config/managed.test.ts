import { readFileSync } from 'node:fs';
import { describe, expect, it, vi } from 'vitest';

interface Element {
  tag: string;
  attrs: Record<string, any>;
  children: Array<Element | string>;
  value: string;
  disabled?: boolean;
  textContent?: string;
}

const E = (tag: string, attrs: Record<string, any> = {}, children: Element | string | Array<Element | string> = []): Element => ({ tag, attrs, children: Array.isArray(children) ? children : [children], value: attrs.value || '' });
const all = (elements: Array<Element | string>): Element[] => elements.flatMap((item) => typeof item === 'string' ? [] : [item, ...all(item.children)]);
const label = (element: Element): string => element.children.map((item) => typeof item === 'string' ? item : label(item)).join('');

function harness(active = false) {
  let modal: Array<Element | string> = [];
  const state = { managed_by: 'netfleet', revision: 'revision-1', sources: [{ id: 'alpha', name: 'Alpha', node_count: 8, has_url: true, has_info_url: true }] };
  const api = { subscriptionsGet: vi.fn(async () => state), subscriptionsSet: vi.fn(async (_request: unknown) => ({})), subscriptionsRefresh: vi.fn(async (_id: string) => ({})), migrationGet: vi.fn(async () => ({ ready: true, revision: 'migration-1' })), migrationApply: vi.fn(async (_request: unknown) => ({})) };
  const ui = { showModal: (_title: string, children: Array<Element | string>) => { modal = children; }, hideModal: vi.fn(), addNotification: vi.fn() };
  const source = readFileSync(new URL('../../../openwrt/luci-app-netfleet/htdocs/luci-static/resources/netfleet/managed.js', import.meta.url), 'utf8');
  const managed = new Function('baseclass', 'ui', 'api', 'E', 'L', source)({ extend: (value: unknown) => value }, ui, api, E, { url: (path: string) => path });
  const controller = { status: { active }, refreshData: vi.fn(async () => ({})), redraw: vi.fn() };
  return { managed, api, ui, controller, nodes: () => all(modal), button: (name: string) => all(modal).find((node) => node.tag === 'button' && label(node) === name)! };
}

describe('native LuCI managed operations', () => {
  it('opens a prefetched subscription list synchronously and reuses it on return', async () => {
    const h = harness();
    await h.managed.preloadSubscriptions(h.controller);
    const opening = h.managed.subscriptions(h.controller);
    expect(h.button('编辑')).toBeDefined();
    await opening;
    h.button('编辑').attrs.click();
    h.button('返回').attrs.click();
    expect(h.button('编辑')).toBeDefined();
    expect(h.api.subscriptionsGet).toHaveBeenCalledTimes(1);
    h.button('关闭').attrs.click();
    expect(h.controller.refreshData).not.toHaveBeenCalled();
  });

  it('does not resurrect a loading dialog after the user closes it', async () => {
    const h = harness();
    let finish!: (value: any) => void;
    h.api.subscriptionsGet.mockImplementationOnce(() => new Promise(resolve => { finish = resolve; }));
    const opening = h.managed.subscriptions(h.controller);
    h.button('关闭').attrs.click();
    finish({ managed_by: 'netfleet', sources: [], revision: 'new' });
    await opening;
    expect(h.button('新增订阅')).toBeUndefined();
    expect(h.ui.hideModal).toHaveBeenCalledOnce();
  });

  it('shares the in-flight prefetch with the first click and supports explicit reload', async () => {
    const h = harness();
    const prefetch = h.managed.preloadSubscriptions(h.controller);
    await h.managed.subscriptions(h.controller);
    await prefetch;
    expect(h.api.subscriptionsGet).toHaveBeenCalledTimes(1);
    await h.button('刷新列表').attrs.click();
    expect(h.api.subscriptionsGet).toHaveBeenCalledTimes(2);
  });

  it('edits a source without exposing or resubmitting stored secrets', async () => {
    const h = harness();
    await h.managed.subscriptions(h.controller);
    h.button('编辑').attrs.click();
    const inputs = h.nodes().filter((node) => node.tag === 'input');
    expect(inputs.filter((input) => input.attrs.type === 'password').map((input) => input.value)).toEqual(['', '']);
    inputs[1].value = 'New Name';
    h.button('保存订阅').attrs.click();
    await vi.waitFor(() => expect(h.api.subscriptionsSet).toHaveBeenCalledWith({ revision: 'revision-1', source: { id: 'alpha', name: 'New Name' } }));
  });

  it('allows source edits while active without implicitly refreshing or stopping the runtime', async () => {
    const h = harness(true);
    await h.managed.subscriptions(h.controller);
    for (const name of ['编辑', '删除', '新增订阅']) expect(h.button(name).attrs.disabled).not.toBe(true);
    expect(h.api.subscriptionsSet).not.toHaveBeenCalled();
  });

  it('requires migration confirmation and reads live owner status after success', async () => {
    const h = harness();
    await h.managed.migration(h.controller);
    expect(h.api.migrationApply).not.toHaveBeenCalled();
    h.button('确认迁移').attrs.click();
    await vi.waitFor(() => expect(h.controller.refreshData).toHaveBeenCalledWith(true, true));
    expect(h.api.migrationApply).toHaveBeenCalledWith({ revision: 'migration-1', confirmed: true, backend: 'native-mihomo' });
  });

  it('refreshes a single source only after confirmation then reloads real config resources', async () => {
    const h = harness(true);
    await h.managed.subscriptions(h.controller);
    h.button('更新').attrs.click();
    expect(h.api.subscriptionsRefresh).not.toHaveBeenCalled();
    h.button('确认更新').attrs.click();
    await vi.waitFor(() => expect(h.controller.refreshData).toHaveBeenCalledWith(true, true));
    expect(h.api.subscriptionsRefresh).toHaveBeenCalledWith('alpha');
    expect(h.api.subscriptionsGet.mock.calls.length).toBeGreaterThan(1);
  });

  it('reports failed owner outcome and does not announce successful migration', async () => {
    const h = harness();
    h.api.migrationApply.mockRejectedValueOnce(Object.assign(new Error('migration_failed'), { detail: { rollback: { ok: true } } }));
    await h.managed.migration(h.controller);
    h.button('确认迁移').attrs.click();
    await vi.waitFor(() => expect(h.ui.addNotification).toHaveBeenCalled());
    expect(h.controller.refreshData).not.toHaveBeenCalled();
    expect(label(h.ui.addNotification.mock.calls[0][1])).toContain('已恢复更新前状态');
    expect(h.ui.addNotification.mock.calls[0][2]).toBe('error');
  });
});
