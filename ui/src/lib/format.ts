import type { Capability, DataSourceInfo, DecisionEvent, EventsSnapshot, FailOpenStage, NullableNumber, Provider, Region, StatusSnapshot } from '../types';

const REGIONAL_INDICATOR_PAIR = /^([\u{1F1E6}-\u{1F1FF}])([\u{1F1E6}-\u{1F1FF}])\s*/u;

export const providerName = (snapshot: StatusSnapshot, id?: string | null) =>
  snapshot.providers.find((item) => item.id === id)?.display_name || id || '未提供';

export function regionalDisplayName(value?: string | null): string {
  const text = value?.trim() || '';
  const match = text.match(REGIONAL_INDICATOR_PAIR);
  if (!match) return text;
  const first = match[1].codePointAt(0);
  const second = match[2].codePointAt(0);
  if (first === undefined || second === undefined) return text;
  const code = String.fromCharCode(65 + first - 0x1F1E6, 65 + second - 0x1F1E6);
  const name = text.slice(match[0].length).trim();
  return name ? `${code} ${name}` : code;
}

export const regionName = (snapshot: StatusSnapshot, id?: string | null) =>
  regionalDisplayName(snapshot.regions.find((item) => item.id === id)?.display_name || id || '未提供');

export const capabilityName = (capability: Capability) => capability.display_name || capability.id;

const finite = (value: NullableNumber, fallback: number) =>
  value !== null && value !== undefined && Number.isFinite(Number(value)) ? Number(value) : fallback;

export const sortProvidersForDisplay = (snapshot: StatusSnapshot): Provider[] => snapshot.providers.slice().sort((a, b) =>
  Number(Boolean(b.selected)) - Number(Boolean(a.selected)) ||
  finite(b.available_region_count, -1) - finite(a.available_region_count, -1) ||
  finite(a.last_best_delay_ms ?? a.best_delay_ms, Infinity) - finite(b.last_best_delay_ms ?? b.best_delay_ms, Infinity) ||
  providerName(snapshot, a.id).localeCompare(providerName(snapshot, b.id), 'zh-CN')
);

export const sortRegionsForDisplay = (snapshot: StatusSnapshot): Region[] => snapshot.regions
  .filter((region) => finite(region.available_count, 0) > 0 && finite(region.available_provider_count, 0) > 0)
  .slice()
  .sort((a, b) =>
    Number(Boolean(b.selected)) - Number(Boolean(a.selected)) ||
    finite(a.last_best_delay_ms, Infinity) - finite(b.last_best_delay_ms, Infinity) ||
    finite(a.average_best_delay_ms, Infinity) - finite(b.average_best_delay_ms, Infinity) ||
    finite(b.available_count, -1) - finite(a.available_count, -1) ||
    finite(b.available_node_count, -1) - finite(a.available_node_count, -1) ||
    finite(b.available_provider_count, -1) - finite(a.available_provider_count, -1) ||
    regionName(snapshot, a.id).localeCompare(regionName(snapshot, b.id), 'zh-CN')
  );

export function delay(value: NullableNumber, missing = '未测量'): string {
  return value !== null && value !== undefined && Number.isFinite(Number(value))
    ? `${Number(value)} ms`
    : missing;
}

export function delayClass(value?: number | null, margin?: number | null): string {
  if (value == null || !Number.isFinite(Number(value))) return '';
  if (margin == null || !Number.isFinite(Number(margin))) return '';
  return Number(value) > Number(margin) ? 'is-warning' : 'is-ok';
}

export function countPair(available: NullableNumber, total: NullableNumber): string {
  return available !== null && available !== undefined &&
    total !== null && total !== undefined &&
    Number.isFinite(Number(available)) && Number.isFinite(Number(total))
    ? `${Number(available)}/${Number(total)}`
    : '未提供';
}

export function averageDelay(value: NullableNumber, sampleCount: NullableNumber): string {
  if (sampleCount === null || sampleCount === undefined || !Number.isFinite(Number(sampleCount))) {
    return '统计暂不可读';
  }
  return Number(sampleCount) === 0 ? '暂无有效测量' : Number(sampleCount) < 2 ? '仅 1 次测量' : delay(value);
}

export function quota(state?: { state?: string; remaining_bytes?: number | null }): string {
  if (state?.state === 'exhausted') return '已耗尽';
  if (state?.state !== 'available' || state.remaining_bytes == null || !Number.isFinite(Number(state.remaining_bytes))) return '机场未返回用量';
  let amount = Number(state.remaining_bytes);
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  let unit = 0;
  while (amount >= 1024 && unit < units.length - 1) {
    amount /= 1024;
    unit += 1;
  }
  return `${amount >= 100 ? amount.toFixed(0) : amount.toFixed(1)} ${units[unit]}`;
}

export function providerExpiry(provider: Provider): string {
  if (provider.billing === 'buyout') return '不限时间';
  if (provider.billing !== 'subscription') return '计费方式未确认';
  const value = provider.quota?.expires_at?.trim();
  return value ? value.slice(0, 10) : '机场未返回到期时间';
}

export function quotaResetLabel(day?: number | null): string {
  return day != null && Number.isInteger(day) && day >= 1 && day <= 31 ? `每月 ${day} 日重置` : '';
}

const stageName = (snapshot: StatusSnapshot, stage: FailOpenStage) => {
  if (stage.kind === 'preferred') return '当前优选';
  if (stage.kind === 'direct') return '直连';
  const configured = (stage.provider_ids || []).length > 0;
  return `${stage.role === 'reserve' ? '备用机场' : '主用机场'}${configured ? '' : '（未配置）'}`;
};

export function failOpenOrder(snapshot: StatusSnapshot, capability: Capability) {
  const stages = (capability.fail_open_stages || []).map((stage) => stageName(snapshot, stage));
  const directIndex = stages.indexOf('直连');
  if (!stages.some((stage) => stage.startsWith('备用机场'))) {
    stages.splice(directIndex >= 0 ? directIndex : stages.length, 0, '备用机场（未配置）');
  }
  return stages;
}

export function capabilityRoute(snapshot: StatusSnapshot, capability: Capability): string[] {
  if (capability.data_path === 'native_profile') return capability.runtime_path || [capability.base_group || '原生配置'];
  if (capability.data_path === 'disabled') return [capability.base_group || '原始策略组', '保持原始行为'];
  if (capability.data_path === 'not_compiled') return [capability.base_group || '原始策略组', '尚未编译'];
  if (capability.data_path === 'direct_fallback' || capability.data_path === 'direct_manual') {
    return [capability.base_group || '出口', '直连'];
  }
  if (capability.data_path === 'provider_fallback') {
    return [capability.base_group || '出口', '机场回退', providerName(snapshot, capability.provider_id), capability.leaf || '未提供'];
  }
  if (capability.data_path === 'passthrough') return ['网络直通'];
  return [
    capability.base_group || '出口',
    regionName(snapshot, capability.region_id),
    providerName(snapshot, capability.provider_id),
    capability.leaf || '未提供',
  ];
}

export function modeName(capability: Capability): string {
  if (capability.data_path === 'native_profile') return '原生配置';
  const mode = capability.user_mode || capability.mode;
  return {
    automatic: '自动选优',
    manual_region: '手动保持地区',
    direct: '手动直连',
    manual: '手动选择',
    manual_only: '仅手动',
  }[mode] || mode || '未知';
}

export function reasonText(snapshot: StatusSnapshot, capability: Capability): string {
  const reason = capability.reason;
  if (!reason) return '设备未提供选择原因。';
  if (reason.kind === 'automatic_decision') {
    const parent = snapshot.capabilities.find((item) => item.id === capability.prefer_region_from);
    const choice = reason.decision_reason === 'followed_capability_region'
      ? `跟随${parent ? capabilityName(parent) : '依赖能力'}的合规地区`
      : reason.decision_reason === 'kept_current_region'
        ? '切换收益不足，保持当前地区'
        : '选择同轮最快合格地区';
    return `${choice}；${reason.changed_region ? '已切换地区' : '保持当前地区'}；保护探针${reason.protected_probes_ok ? '通过' : '未记录'}。`;
  }
  if (reason.kind === 'provider_fallback') return '当前优选不可用，Mihomo 已进入机场回退层。';
  if (reason.kind === 'direct_fallback') return '代理路径不可用，Mihomo 已切换到直连退路。';
  if (reason.kind === 'direct_manual') return '用户已选择直连，周期选优暂停。';
  if (reason.kind === 'manual_region') return `手动保持 ${regionName(snapshot, reason.region_id)}，地区内健康切换仍由 Mihomo 负责。`;
  if (reason.kind === 'passthrough') return '代理后端已停止，网络已恢复直通。';
  if (reason.kind === 'disabled') return '该能力已关闭，基础组保持原始行为。';
  if (reason.kind === 'not_compiled') return '该能力尚未进入当前 artifact。';
  if (snapshot.active) return '当前链来自启用初始值或手动选择，页面不会触发测速。';
  return 'NetFleet 未启用，当前使用 原生配置。';
}

export const displayEventName = (
  events: EventsSnapshot,
  kind: 'capabilities' | 'providers' | 'regions',
  id?: string | null,
) => {
  const value = id ? events.display_names?.[kind]?.[id] || id : '全局';
  return kind === 'regions' ? regionalDisplayName(value) : value;
};

export function latestDecision(events: DecisionEvent[]): DecisionEvent | null {
  return events.reduce<DecisionEvent | null>((latest, event) =>
    ['enable', 'select', 'disable'].includes(event.action) && (!latest || event.at >= latest.at) ? event : latest, null);
}

export function eventResult(snapshot: EventsSnapshot, event: DecisionEvent): string {
  if (event.action === 'refresh') {
    if (event.reason === 'rollback_restored') return '更新未生效，已恢复更新前状态';
    return event.changed_count != null && event.failed_count != null
      ? `更新 ${event.changed_count} 个机场，失败 ${event.failed_count} 个`
      : '订阅更新';
  }
  if (event.action === 'disable' && event.reason === 'native_restored') return '已恢复原生配置';
  if (event.action === 'disable' && event.reason === 'native_restore_failed_passthrough') return '已恢复网络直通';
  if (event.to_group === 'DIRECT') return '直连';
  return [displayEventName(snapshot, 'regions', event.region_id), displayEventName(snapshot, 'providers', event.provider_id), event.leaf]
    .filter((item) => item && item !== '全局').join(' / ') || '未记录选路结果';
}

export const eventDelay = (event: DecisionEvent): string =>
  event.action === 'refresh' || event.action === 'disable' ? '不适用' : delay(event.delay_ms, '未记录');

export function eventReason(status: StatusSnapshot, event: DecisionEvent): string {
  if (event.reason === 'followed_capability_region') {
    const capability = status.capabilities.find((item) => item.id === event.capability);
    const parent = status.capabilities.find((item) => item.id === capability?.prefer_region_from);
    return `跟随${parent ? capabilityName(parent) : '依赖能力'}地区`;
  }
  return ({
    fastest_eligible: '同轮最快合格候选',
    kept_current_region: '收益不足，保持当前地区',
    current_region_fastest: '当前地区仍为最快',
    native_restored: '已恢复原生配置',
    native_restore_failed_passthrough: '原生配置恢复失败，已停止代理后端 并恢复网络直通',
    updated: '订阅更新完成并重载',
    cache_updated: '订阅缓存已更新',
    partially_updated: '部分机场更新成功',
    unchanged: '订阅无变化',
    update_failed: '更新失败，旧缓存保持生效',
    rollback_restored: '已恢复更新前运行状态',
  }[event.reason || ''] || event.reason || '未提供');
}

export function recoveryPreferredLabel(snapshot: StatusSnapshot): string {
  const name = snapshot.recovery_profile_display_name?.trim();
  return name ? `${name} 原生配置` : '当前原生配置';
}

export function sourceFreshness(source: DataSourceInfo, statusError?: string | null): string {
  if (statusError || source.connected === false) return '读取失败';
  if (source.fetched_at) return '刚刚更新';
  return '尚未读取';
}

export function sourceTargetLabel(source: DataSourceInfo): string {
  if (source.target_label) return source.target_label;
  return source.mode === 'live' ? (source.label || '设备实时只读') : '当前 OpenWrt';
}
