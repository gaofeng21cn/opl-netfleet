import { describe, expect, it } from 'vitest';
import { hostState } from './hostState';
import { fixtureScenarios } from '../data/fixtures';
import type { DesktopSnapshot } from './types';

// The status-item menu and the page must read the same facts: these cases pin
// the projection the AppKit host renders, including the stopped state where a
// menu must not offer a region switch the page would refuse.
const snapshot = (scenario: keyof typeof fixtureScenarios, runtime: Partial<DesktopSnapshot['runtime']> = {}): DesktopSnapshot => {
  const fixture = fixtureScenarios[scenario];
  return {
    runtime: {
      platform: 'macos', running: true, configured: true, mode: 'netfleet', requestedMode: 'netfleet',
      networkMode: 'explicit', ports: { mixed: 7890, controller: 9090, dns: 1053 },
      controllerReady: true, clean: true, pid: 4242, version: 'v1.19.30', lastError: null,
      ...runtime,
    },
    policy: {}, subscriptions: {}, status: fixture.status, events: fixture.events, config: null, configError: null,
    network: { helper: 'installed', ready: true, clean: true, authorized: true, owned: true },
  } as DesktopSnapshot;
};

describe('宿主菜单状态投影', () => {
  it('运行中按出口给出当前路径、测量与可选地区', () => {
    const state = hostState(snapshot('healthy'), false);
    expect(state.running).toBe(true);
    expect(state.summary).toContain(state.exits[0].name);
    expect(state.exits.length).toBeGreaterThan(0);
    const exit = state.exits[0];
    expect(exit.current).not.toBe('未接管');
    expect(exit.detail).toMatch(/ms|未测量|健康|不可用/);
    expect(exit.regions.length).toBeGreaterThan(0);
    expect(exit.regions.every(region => region.id && region.name)).toBe(true);
  });

  it('未接管时明确说明，不把未测量写成可用', () => {
    const state = hostState(snapshot('healthy', { running: false, mode: 'direct' }), false);
    expect(state.summary).toBe('代理已停止');
    expect(state.exits.every(exit => exit.current === '未接管' && exit.detail === '未测量')).toBe(true);
  });

  it('只提供后端标记为可选的地区，且标出当前保持的地区', () => {
    const base = snapshot('healthy');
    const target = base.status!.capabilities[0];
    const restricted = {
      ...base,
      status: {
        ...base.status!,
        capabilities: [{ ...target, user_mode: 'manual_region', manual_region_id: 'japan', selectable_regions: ['japan', 'singapore'] }],
      },
    };
    const exit = hostState(restricted, false).exits[0];
    expect(exit.regions.map(region => region.id)).toEqual(['japan', 'singapore']);
    expect(exit.regions.filter(region => region.selected).map(region => region.id)).toEqual(['japan']);
    expect(exit.automatic).toBe(false);
  });

  it('忙碌与网络接管方式直接投影，供宿主决定可用性', () => {
    const state = hostState(snapshot('healthy', { networkMode: 'tun' }), true);
    expect(state.busy).toBe(true);
    expect(state.networkMode).toBe('tun');
    expect(state.address).toBe('127.0.0.1:7890');
  });
});
