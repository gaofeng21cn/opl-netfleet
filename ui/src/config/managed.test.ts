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

const E = (tag: string, attrs: Record<string, any> = {}, children: Element | string | Array<Element | string> = []): Element => {
  const items = Array.isArray(children) ? children : [children];
  const selected = tag === 'select' ? items.find((item) => typeof item !== 'string' && item.attrs.selected) as Element | undefined : undefined;
  return { tag, attrs, children: items, value: attrs.value || selected?.attrs.value || '' };
};
const all = (elements: Array<Element | string>): Element[] => elements.flatMap((item) => typeof item === 'string' ? [] : [item, ...all(item.children)]);
const label = (element: Element): string => element.children.map((item) => typeof item === 'string' ? item : label(item)).join('');

function harness(active = false) {
  let modal: Array<Element | string> = [];
  const state = { managed_by: 'netfleet', revision: 'revision-1', sources: [{ id: 'alpha', name: 'Alpha', node_count: 8, has_url: true, has_info_url: true, url: 'https://example.test/subscription', user_agent: 'custom-client/1.0', info_url: 'https://example.test/quota' }] };
  const api = { operationGet: vi.fn(async (): Promise<any> => ({ subscription: null, packages: null })), componentsGet: vi.fn(async (): Promise<any> => ({ supported: true, components: [], dependencies: [], feed: {} })), componentsCheck: vi.fn(async (): Promise<any> => ({})), componentsUpdate: vi.fn(async (): Promise<any> => ({})), subscriptionsGet: vi.fn(async () => state), subscriptionsSet: vi.fn(async (_request: unknown) => ({})), subscriptionsRefresh: vi.fn(async (_id: string) => ({})), migrationGet: vi.fn(async () => ({ ready: true, revision: 'migration-1' })), migrationApply: vi.fn(async (_request: unknown) => ({})) };
  const ui = { showModal: (_title: string, children: Array<Element | string>) => { modal = children; }, hideModal: vi.fn(), addNotification: vi.fn(), Combobox: class {
    input: Element;
    constructor(value: string, choices: Record<string, string>, options: Record<string, unknown>) { this.input = E('input', { ...options, value, choices, role: 'combobox' }); }
    render() { return this.input; }
    getValue() { return this.input.value; }
  } };
  const source = readFileSync(new URL('../../../openwrt/luci-app-netfleet/htdocs/luci-static/resources/netfleet/managed.js', import.meta.url), 'utf8');
  const managed = new Function('baseclass', 'ui', 'api', 'E', 'L', source)({ extend: (value: unknown) => value }, ui, api, E, { url: (path: string) => path });
  const controller: Record<string, any> = { status: { active }, refreshData: vi.fn(async () => ({})), redraw: vi.fn() };
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

  it('prefills authenticated source fields and preserves a custom User-Agent on save', async () => {
    const h = harness();
    await h.managed.subscriptions(h.controller);
    h.button('编辑').attrs.click();
    const inputs = h.nodes().filter((node) => node.tag === 'input');
    expect(inputs.map((input) => input.value)).toEqual(['alpha', 'Alpha', 'https://example.test/subscription', 'custom-client/1.0', 'https://example.test/quota']);
    expect(inputs[3].attrs.choices).toEqual({ clash: 'clash', 'clash.meta': 'clash.meta', mihomo: 'mihomo' });
    inputs[1].value = 'New Name';
    h.button('保存订阅').attrs.click();
    await vi.waitFor(() => expect(h.api.subscriptionsSet).toHaveBeenCalledWith({ revision: 'revision-1', source: { id: 'alpha', name: 'New Name', url: 'https://example.test/subscription', user_agent: 'custom-client/1.0', info_url: 'https://example.test/quota', quota_reset_day: null } }));
  });

  it('allows choosing a preset and clearing the usage address without changing the subscription', async () => {
    const h = harness();
    await h.managed.subscriptions(h.controller);
    h.button('编辑').attrs.click();
    const inputs = h.nodes().filter((node) => node.tag === 'input');
    inputs[3].value = 'mihomo';
    inputs[4].value = '';
    h.button('保存订阅').attrs.click();
    await vi.waitFor(() => expect(h.api.subscriptionsSet).toHaveBeenCalledWith({ revision: 'revision-1', source: { id: 'alpha', name: 'Alpha', url: 'https://example.test/subscription', user_agent: 'mihomo', info_url: '', quota_reset_day: null } }));
  });

  it('reads, edits and clears the monthly quota reset day without refreshing subscriptions', async () => {
    const h = harness(true);
    await h.managed.subscriptions(h.controller);
    h.controller.subscriptionState.sources[0].quota_reset_day = 15;
    h.api.subscriptionsSet.mockImplementation(async (request: any) => {
      h.controller.subscriptionState.sources[0] = { ...h.controller.subscriptionState.sources[0], ...request.source };
      return h.controller.subscriptionState;
    });
    h.button('编辑').attrs.click();
    const reset = () => h.nodes().find((node) => node.attrs.id === 'netfleet-source-reset-day')!;
    expect(reset().value).toBe('15');
    expect(reset().children).toHaveLength(32);
    reset().value = '31';
    h.button('保存订阅').attrs.click();
    await vi.waitFor(() => expect(h.button('编辑')).toBeDefined());
    expect(h.nodes().some((node) => label(node).includes('每月 31 日重置'))).toBe(true);
    h.button('编辑').attrs.click();
    expect(reset().value).toBe('31');
    reset().value = '';
    h.button('保存订阅').attrs.click();
    await vi.waitFor(() => expect(h.button('编辑')).toBeDefined());
    expect(h.controller.subscriptionState.sources[0].quota_reset_day).toBeNull();
    expect(h.api.subscriptionsRefresh).not.toHaveBeenCalled();
    h.button('关闭').attrs.click();
    expect(h.controller.refreshData).toHaveBeenCalledWith(true, true);
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
    expect(h.controller.subscriptionState).toBeNull();
    expect(h.api.operationGet).toHaveBeenCalled();
    expect(h.button('收起进度')).toBeDefined();
  });

  it('keeps subscription progress available after its dialog is collapsed and reports actual stages', async () => {
    const h = harness();
    h.controller.operations = { subscription: { id: 'subscription-2', kind: 'subscription', state: 'running', phase: 'compiling', subject: 'Alpha', completed: 1, total: 3, started_at: Date.now() / 1000 - 12 }, packages: null };
    const progress = h.managed.operationNode(h.controller, 'subscription');
    expect(label(progress)).toContain('生成运行配置');
    expect(label(progress)).toContain('Alpha');
    expect(label(progress)).toContain('已处理 1 / 3 个机场');
    expect(label(progress)).not.toContain('%');
    h.controller.operationError = new Error('network');
    expect(label(h.managed.operationNode(h.controller, 'subscription'))).toContain('执行结果尚未确认');
    expect(label(h.managed.operationNode(h.controller, 'subscription'))).not.toContain('执行失败');
  });

  it('does not confuse a queued package update with the previous successful operation', async () => {
    const h = harness();
    const queued = { id: 'new', kind: 'packages', state: 'queued', phase: 'checking', started_at: 1 };
    h.controller.operations = { packages: queued, subscription: null };
    h.controller.packageOperationId = 'new';
    h.api.operationGet.mockResolvedValueOnce({ packages: { id: 'old', state: 'succeeded' }, subscription: null });
    await h.managed.readOperations(h.controller);
    clearTimeout(h.controller.operationTimer);
    expect(h.controller.operations.packages).toBe(queued);
    expect(h.api.componentsGet).not.toHaveBeenCalled();
    expect(label(h.managed.operationNode(h.controller, 'packages'))).toContain('等待设备执行');
  });

  it('polls only an active operation and stops polling when it finishes, including on the provider page', async () => {
    vi.useFakeTimers();
    try {
      const h = harness();
      h.controller.currentView = 'providers';
      await h.managed.readOperations(h.controller);
      expect(vi.getTimerCount()).toBe(0);
      h.api.operationGet.mockResolvedValueOnce({ subscription: { id: 'current', state: 'running' }, packages: null });
      await h.managed.readOperations(h.controller);
      expect(vi.getTimerCount()).toBe(1);
      await vi.advanceTimersByTimeAsync(1000);
      expect(h.api.operationGet).toHaveBeenCalledTimes(3);
      expect(vi.getTimerCount()).toBe(0);
    } finally { vi.useRealTimers(); }
  });

  it('shows restoration without describing a failed subscription update as successful', () => {
    const h = harness();
    for (const [recovery, expected] of [['restored', '已恢复更新前状态'], ['failed', '恢复失败'], ['direct', '已恢复网络直通']]) {
      h.controller.operations = { subscription: { id: 'failed', state: 'failed', recovery, started_at: 1, completed: 1, total: 3 } };
      const progress = label(h.managed.operationNode(h.controller, 'subscription'));
      expect(progress).toContain('执行失败');
      expect(progress).toContain(expected);
      expect(progress).not.toContain('已完成');
    }
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
