import { readFileSync } from 'node:fs';
import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, it } from 'vitest';
import { fixtureScenarios } from '../data/fixtures';
import { OverviewDigest } from '../components/OverviewDigest';
import { EventsView } from '../views/EventsView';
import { eventDelay, eventResult, latestDecision } from './format';
import type { DecisionEvent, EventsSnapshot } from '../types';

const nativeSource = readFileSync(new URL('../../../openwrt/luci-app-netfleet/htdocs/luci-static/resources/view/netfleet/overview.js', import.meta.url), 'utf8');
const native = new Function('E', nativeSource.replace('return view.extend({',
  'return { latestDecision, eventResult, eventDelay, overviewDigest, eventsPage };\nview.extend({'))(
  (tag: string, attrs: object, children: unknown) => ({ tag, attrs, children }),
);
const status = fixtureScenarios.healthy.status;
const route: DecisionEvent = { at: 100, action: 'select', trigger: 'refresh', capability: 'standard', region_id: 'japan', provider_id: 'alpha', delay_ms: 10, reason: 'current_region_fastest' };
const refresh: DecisionEvent = { at: 101, action: 'refresh', reason: 'updated', changed_count: 3, failed_count: 0 };
const snapshot: EventsSnapshot = { ...fixtureScenarios.healthy.events, events: [route, refresh] };

describe.each([
  ['React', { latestDecision, eventResult, eventDelay }],
  ['LuCI', native],
] as const)('%s 事件语义', (_name, surface) => {
  it('订阅摘要不覆盖最近选路，同秒按最后写入取值', () => {
    expect(surface.latestDecision(snapshot.events)).toEqual(route);
    const second = { ...route, capability: 'ai-compatible' };
    expect(surface.latestDecision([route, second, refresh])).toEqual(second);
    expect(surface.latestDecision([refresh])).toBeNull();
    expect(surface.latestDecision([])).toBeNull();
  });
  it('更新缺少路由和延迟不是恢复原生或测量失败', () => {
    expect(surface.eventResult(snapshot, refresh)).toBe('更新 3 个机场，失败 0 个');
    expect(surface.eventDelay(refresh)).toBe('不适用');
    expect(surface.eventResult(snapshot, { at: 1, action: 'select' })).toBe('未记录选路结果');
    expect(surface.eventResult(snapshot, { ...refresh, reason: 'update_failed', changed_count: 0, failed_count: 3 })).toBe('更新 0 个机场，失败 3 个');
    expect(surface.eventResult(snapshot, { ...refresh, reason: 'rollback_restored' })).toBe('更新未生效，已恢复更新前状态');
    expect(surface.eventResult(snapshot, { ...route, to_group: 'DIRECT', region_id: null, provider_id: null })).toBe('直连');
  });
  it('真实恢复仍展示原生或直通，不用当前状态改写历史', () => {
    const restored = { at: 102, action: 'disable', reason: 'native_restored' };
    expect(surface.latestDecision([...snapshot.events, restored])).toEqual(restored);
    expect(surface.eventResult(snapshot, restored)).toBe('已恢复原生配置');
    expect(surface.eventDelay(restored)).toBe('不适用');
    expect(surface.eventResult(snapshot, { ...restored, reason: 'native_restore_failed_passthrough' })).toBe('已恢复网络直通');
  });
});

it('React 与 LuCI 的概览及事件真实渲染使用事件类型', () => {
  const overviews = [
    renderToStaticMarkup(<OverviewDigest status={status} events={snapshot} onOpen={() => undefined} />),
    JSON.stringify(native.overviewDigest(status, snapshot, () => undefined)),
  ];
  for (const output of overviews) {
    expect(output).toContain('10 ms');
    expect(output).toContain('当前地区仍为最快');
    expect(output).not.toContain('订阅更新完成并重载');
    expect(output).not.toContain('Nikki 原生配置');
  }
  const eventPages = [
    renderToStaticMarkup(<EventsView status={status} snapshot={snapshot} connections={{ connections: [], count: 0, truncated: false }} connectionsLoading={false} />),
    JSON.stringify(native.eventsPage(status, snapshot, { connections: [] }, false, null, 0, () => undefined)),
  ];
  for (const output of eventPages) {
    expect(output).toContain('更新 3 个机场，失败 0 个');
    expect(output).toContain('订阅更新后选优');
    expect(output).toContain('不适用');
    expect(output).not.toContain('Nikki 原生配置');
  }
});
