import { describe, expect, it } from 'vitest';
import { fixtureScenarios } from '../data/fixtures';
import { averageDelay, capabilityRoute, countPair, delay, delayClass, displayEventName, eventReason, failOpenOrder, providerExpiry, quota, reasonText, recoveryPreferredLabel, regionName, regionalDisplayName, sortProvidersForDisplay, sortRegionsForDisplay, sourceFreshness, sourceTargetLabel } from './format';

describe('运行时网络退路', () => {
  it('按运行角色显示完整退路，不使用计费属性推断角色', () => {
    const snapshot = structuredClone(fixtureScenarios.healthy.status);
    snapshot.providers.find((provider) => provider.id === 'gamma')!.billing = 'buyout';
    const capability = snapshot.capabilities[0];
    expect(failOpenOrder(snapshot, capability)).toEqual([
      '当前优选',
      '主用机场',
      '备用机场',
      '直连',
    ]);
  });

  it('没有 reserve stage 时保留明确的空层', () => {
    const snapshot = fixtureScenarios.healthy.status;
    const capability = snapshot.capabilities[1];
    expect(failOpenOrder(snapshot, capability)).toEqual([
      '当前优选',
      '主用机场',
      '备用机场（未配置）',
      '直连',
    ]);
  });

  it('未知计数和延迟不伪装为零值', () => {
    expect(delay(null)).toBe('未测量');
    expect(countPair(null, 5)).toBe('未提供');
  });

  it('延迟着色读取 status 门槛，不写死 150', () => {
    const snapshot = structuredClone(fixtureScenarios.healthy.status);
    snapshot.selection = { ...snapshot.selection, region_switch_margin_ms: 100 };
    expect(delayClass(78, snapshot.selection?.region_switch_margin_ms)).toBe('is-ok');
    expect(delayClass(168, snapshot.selection?.region_switch_margin_ms)).toBe('is-warning');
    expect(delayClass(100, snapshot.selection?.region_switch_margin_ms)).toBe('is-ok');
    expect(delayClass(168, null)).toBe('');
    expect(delayClass(null, 100)).toBe('');
  });

  it('跟随能力说明读取依赖能力显示名，不写死能力名称', () => {
    const snapshot = structuredClone(fixtureScenarios.healthy.status);
    const capability = snapshot.capabilities[1];
    capability.reason = { kind: 'automatic_decision', decision_reason: 'followed_capability_region' };
    expect(reasonText(snapshot, capability)).toContain('跟随海外加速的合规地区');
    snapshot.capabilities[0].display_name = '根出口';
    expect(reasonText(snapshot, capability)).toContain('跟随根出口的合规地区');
    capability.prefer_region_from = 'missing';
    expect(reasonText(snapshot, capability)).toContain('跟随依赖能力的合规地区');
  });

  it('事件跟随原因读取依赖能力显示名，不写死能力名称', () => {
    const status = structuredClone(fixtureScenarios.healthy.status);
    const events = fixtureScenarios.healthy.events;
    const event = { at: 1, action: 'select', capability: 'ai-compatible', reason: 'followed_capability_region' };
    expect(eventReason(status, event)).toBe('跟随海外加速地区');
    status.capabilities[0].display_name = '根出口';
    expect(eventReason(status, event)).toBe('跟随根出口地区');
    status.capabilities[1].prefer_region_from = 'missing';
    expect(eventReason(status, event)).toBe('跟随依赖能力地区');
    expect(eventReason(status, events.events[0])).toBe('同轮最快合格候选');
    expect(eventReason(status, { at: 2, action: 'disable', reason: 'native_restored' })).toBe('已恢复 Nikki 原生配置');
  });

  it('新鲜度只反映本次本机读取成败，不用轮询或 TTL', () => {
    const live = { mode: 'live' as const, label: '设备实时只读', target_label: '示例设备', read_only: true, connected: true, fetched_at: 1_788_000_000 };
    expect(sourceFreshness(live)).toBe('刚刚更新');
    expect(sourceFreshness({ ...live, connected: false })).toBe('读取失败');
    expect(sourceFreshness(live, '设备状态读取失败')).toBe('读取失败');
    expect(sourceFreshness({ ...live, fetched_at: null, connected: true })).toBe('尚未读取');
    expect(sourceTargetLabel(live)).toBe('示例设备');
    expect(sourceTargetLabel({ ...live, target_label: 'R76S' })).toBe('R76S');
    expect(sourceTargetLabel({ ...live, target_label: undefined })).not.toBe('当前 OpenWrt');
  });

  it('恢复区优先恢复使用显示名加原生配置，缺名时回退当前原生配置', () => {
    const snapshot = structuredClone(fixtureScenarios.healthy.status);
    expect(recoveryPreferredLabel(snapshot)).toBe('示例恢复配置 原生配置');
    snapshot.recovery_profile_display_name = null;
    expect(recoveryPreferredLabel(snapshot)).toBe('当前原生配置');
    snapshot.recovery_profile_display_name = '   ';
    expect(recoveryPreferredLabel(snapshot)).toBe('当前原生配置');
  });

  it('机场回退链不伪造地区', () => {
    const snapshot = fixtureScenarios.degraded.status;
    expect(capabilityRoute(snapshot, snapshot.capabilities[0])).toEqual([
      'OUTBOUND',
      '机场回退',
      'Gamma 备用机场',
      'US-LosAngeles-01',
    ]);
  });
});

describe('地区显示与统计口径', () => {
  it('通用转换地区旗帜，不硬编码单个地区', () => {
    expect(regionalDisplayName('🇯🇵 日本')).toBe('JP 日本');
    expect(regionalDisplayName('🇹🇼 台湾')).toBe('TW 台湾');
    expect(regionalDisplayName('🇭🇰 香港')).toBe('HK 香港');
    expect(regionalDisplayName('JP 日本')).toBe('JP 日本');
  });

  it('统一地区表、能力路径和事件显示', () => {
    const snapshot = fixtureScenarios.healthy.status;
    expect(regionName(snapshot, 'japan')).toBe('JP 日本');
    expect(capabilityRoute(snapshot, snapshot.capabilities[0])).toContain('JP 日本');
    expect(displayEventName(fixtureScenarios.healthy.events, 'regions', 'japan')).toBe('JP 日本');
  });

  it('单样本不重复显示平均值，多个样本显示真实平均', () => {
    expect(averageDelay(96, 1)).toBe('样本不足');
    expect(averageDelay(84, 24)).toBe('84 ms');
    expect(averageDelay(78, 2)).toBe('78 ms');
  });

  it('机场平均最优沿用同一有效样本口径', () => {
    const providers = fixtureScenarios.healthy.status.providers;
    expect(averageDelay(providers[0].average_best_delay_ms, providers[0].delay_sample_count)).toBe('84 ms');
    expect(averageDelay(providers[2].average_best_delay_ms, providers[2].delay_sample_count)).toBe('样本不足');
  });

  it('订阅到期时间使用 status owner 投影，买断制不猜测', () => {
    expect(providerExpiry({ id: 'subscription', role: 'primary', billing: 'subscription', quota: { state: 'available', remaining_bytes: 10, expires_at: '2027-03-12 16:00:00' } })).toBe('2027-03-12');
    expect(providerExpiry({ id: 'missing', role: 'primary', billing: 'subscription', quota: { state: 'unknown' } })).toBe('未提供');
    expect(providerExpiry({ id: 'buyout', role: 'reserve', billing: 'buyout', quota: { state: 'unknown', expires_at: '2027-03-12' } })).toBe('不限时间');
    expect(providerExpiry({ id: 'unknown', role: 'reserve', billing: 'unknown', quota: { state: 'unknown' } })).toBe('未提供');
    expect(quota({ state: 'available', remaining_bytes: 1024 })).toBe('1.0 KiB');
  });

  it('地区与机场只按显示合同排序，不改变运行选择', () => {
    const snapshot = structuredClone(fixtureScenarios.healthy.status);
    snapshot.regions = [
      { id: 'z', display_name: '🇿🇦 南非', mode: 'automatic', available_node_count: 4, available_provider_count: 2, last_best_delay_ms: 80, average_best_delay_ms: 90 },
      { id: 'b', display_name: '🇧🇷 巴西', mode: 'automatic', available_node_count: 5, available_provider_count: 2, last_best_delay_ms: 80, average_best_delay_ms: 90 },
      { id: 'a', display_name: '🇦🇷 阿根廷', mode: 'automatic', available_node_count: 5, available_provider_count: 3, last_best_delay_ms: 80, average_best_delay_ms: 90 },
      { id: 'selected', display_name: '🇯🇵 日本', mode: 'automatic', selected: true, available_node_count: 1, available_provider_count: 1, last_best_delay_ms: 999, average_best_delay_ms: 999 },
    ];
    snapshot.providers = [
      { id: 'z', display_name: 'Zulu', role: 'primary', billing: 'subscription', available_region_count: 2, best_delay_ms: 20 },
      { id: 'a', display_name: 'Alpha', role: 'primary', billing: 'subscription', available_region_count: 2, best_delay_ms: 20 },
      { id: 'selected', display_name: 'Selected', role: 'primary', billing: 'subscription', selected: true, available_region_count: 0, best_delay_ms: 999 },
    ];

    expect(sortRegionsForDisplay(snapshot).map((region) => region.id)).toEqual(['selected', 'a', 'b', 'z']);
    expect(sortProvidersForDisplay(snapshot).map((provider) => provider.id)).toEqual(['selected', 'a', 'z']);
  });
});
