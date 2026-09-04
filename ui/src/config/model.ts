import type { DeviceConfigSnapshot, StatusSnapshot } from '../types';

export type ConfigSectionId = 'foundation' | 'providers' | 'regions' | 'exits' | 'routing' | 'automation' | 'safety';

export interface ProviderDraft {
  id: string;
  displayName: string;
  section: string;
  enabled: boolean;
  role: 'primary' | 'reserve';
  billing: 'subscription' | 'buyout';
  availableRegions?: number | null;
  availableNodes?: number | null;
  regionIds: string[];
}

export interface ProviderOption { id: string; section: string; displayName: string; regionIds: string[] }

export interface RegionDraft {
  id: string;
  displayName: string;
  mode: 'automatic' | 'manual_only';
  availableProviders?: number | null;
  availableNodes?: number | null;
  flag?: string | null;
  displayOrder?: number | null;
}

export interface RegionOption { id: string; code: string; displayName: string; displayOrder: number }

export interface CapabilityDraft {
  id: string;
  displayName: string;
  enabled: boolean;
  mode: 'automatic' | 'manual';
  entryGroup: string | null;
  policyGroups: string[];
  regionIds: string[];
  preferRegionFrom?: string | null;
}

export interface RoutingRuleDraft { kind: 'domain_suffix'; value: string; capability: string }

export interface ConfigDraft {
  backend: 'nikki-mihomo';
  policySource: { kind: 'bundle' | 'profile'; ref: string; displayName: string };
  policySourceOptions: Array<{ kind: 'bundle' | 'profile'; ref: string; displayName: string }>;
  policyGroups: string[];
  recoveryProfile: { ref: string; displayName: string };
  recoveryProfileOptions: Array<{ ref: string; displayName: string }>;
  providers: ProviderDraft[];
  providerOptions: ProviderOption[];
  regions: RegionDraft[];
  regionOptions: RegionOption[];
  capabilities: CapabilityDraft[];
  routingRules: RoutingRuleDraft[];
  automation: {
    enabled: boolean;
    selectionIntervalSeconds: number;
    subscriptionRefreshEnabled: boolean;
    subscriptionRefreshIntervalSeconds: number;
  };
  safety: {
    regionSwitchMarginMs: number;
    leafSwitchMarginMs: number;
    runtimeGraceSeconds: number;
    latencyUrl: string;
    protectedUrl: string;
  };
}

const providerRole = (value: string): ProviderDraft['role'] => value === 'reserve' ? 'reserve' : 'primary';
const providerBilling = (value: string): ProviderDraft['billing'] => value === 'buyout' ? 'buyout' : 'subscription';
const regionMode = (value: string): RegionDraft['mode'] => value === 'manual_only' ? 'manual_only' : 'automatic';
const capabilityMode = (value: string): CapabilityDraft['mode'] => value === 'manual' ? 'manual' : 'automatic';

export function createConfigDraft(status: StatusSnapshot, config?: DeviceConfigSnapshot): ConfigDraft {
  const automation = status.selection?.automation;
  if (config) return {
    backend: 'nikki-mihomo',
    policySource: { kind: config.policy_source.kind, ref: config.policy_source.ref, displayName: config.policy_source.display_name },
    policySourceOptions: config.policy_source_options.map((item) => ({ kind: item.kind, ref: item.ref, displayName: item.display_name })),
    policyGroups: config.policy_groups.slice(),
    recoveryProfile: { ref: config.recovery_profile.ref, displayName: config.recovery_profile.display_name },
    recoveryProfileOptions: config.recovery_profile_options.map((item) => ({ ref: item.ref, displayName: item.display_name })),
    providers: config.providers.map((provider) => ({
      id: provider.id, section: provider.section, displayName: provider.display_name, enabled: provider.enabled,
      role: provider.role, billing: provider.billing, regionIds: provider.region_ids.slice(),
      availableRegions: status.providers.find((item) => item.id === provider.id)?.available_region_count,
      availableNodes: status.providers.find((item) => item.id === provider.id)?.available_node_count,
    })),
    providerOptions: config.provider_options.map((item) => ({ id: item.id, section: item.section, displayName: item.display_name, regionIds: item.region_ids.slice() })),
    regions: config.regions.map((region) => ({
      id: region.id, displayName: region.display_name, flag: region.flag, displayOrder: region.display_order,
      mode: region.mode,
      availableProviders: status.regions.find((item) => item.id === region.id)?.available_provider_count,
      availableNodes: status.regions.find((item) => item.id === region.id)?.available_node_count,
    })),
    regionOptions: config.region_options.map((item) => ({ id: item.id, code: item.code, displayName: item.display_name, displayOrder: item.display_order })),
    capabilities: config.capabilities.map((capability) => ({
      id: capability.id, displayName: capability.display_name, enabled: capability.enabled, mode: capability.mode,
      entryGroup: capability.entry_group || null, policyGroups: capability.policy_groups.slice(), regionIds: capability.region_ids.slice(),
      preferRegionFrom: capability.prefer_region_from,
    })),
    routingRules: config.routing_rules.map((item) => ({ ...item })),
    automation: {
      enabled: config.automation.enabled,
      selectionIntervalSeconds: config.automation.selection_interval_seconds,
      subscriptionRefreshEnabled: config.automation.subscription_refresh_enabled,
      subscriptionRefreshIntervalSeconds: config.automation.subscription_refresh_interval_seconds,
    },
    safety: {
      regionSwitchMarginMs: config.safety.region_switch_margin_ms,
      leafSwitchMarginMs: config.safety.leaf_switch_margin_ms,
      runtimeGraceSeconds: config.safety.runtime_grace_seconds,
      latencyUrl: config.safety.latency_url,
      protectedUrl: config.safety.guard_probe_url,
    },
  };
  const visibleRegions = status.regions.filter((region) => (
    (region.available_node_count ?? 0) > 0 && (region.available_provider_count ?? 0) > 0
  ));
  return {
    backend: 'nikki-mihomo',
    policySource: { kind: status.policy_source?.kind === 'profile' ? 'profile' : 'bundle', ref: status.policy_source?.ref || 'bundle:base-v1', displayName: status.policy_source?.kind === 'profile' ? '沿用当前 Nikki 配置' : 'NetFleet 内置基础策略' },
    policySourceOptions: [{ kind: status.policy_source?.kind === 'profile' ? 'profile' : 'bundle', ref: status.policy_source?.ref || 'bundle:base-v1', displayName: status.policy_source?.kind === 'profile' ? '沿用当前 Nikki 配置' : 'NetFleet 内置基础策略' }],
    policyGroups: Array.from(new Set(status.capabilities.flatMap((item) => item.base_groups || (item.base_group ? [item.base_group] : [])))),
    recoveryProfile: { ref: status.recovery_profile || '', displayName: status.recovery_profile_display_name || '当前原生配置' },
    recoveryProfileOptions: [{ ref: status.recovery_profile || '', displayName: status.recovery_profile_display_name || '当前原生配置' }],
    providers: status.providers.map((provider) => ({
      id: provider.id,
      section: provider.subscription_section || provider.id,
      displayName: provider.display_name || provider.id,
      enabled: true,
      role: providerRole(provider.role),
      billing: providerBilling(provider.billing),
      availableRegions: provider.available_region_count,
      availableNodes: provider.available_node_count,
      regionIds: visibleRegions.map((region) => region.id),
    })),
    providerOptions: status.subscriptions?.map((item) => ({ id: item.section, section: item.section, displayName: item.display_name || item.section, regionIds: visibleRegions.map((region) => region.id) })) || [],
    regions: visibleRegions
      .map((region) => ({
        id: region.id,
        displayName: region.display_name || region.id,
        mode: regionMode(region.mode),
        availableProviders: region.available_provider_count,
        availableNodes: region.available_node_count,
        flag: null,
      })),
    regionOptions: visibleRegions.map((region, index) => ({ id: region.id, code: region.display_name?.slice(0, 2) || '', displayName: region.display_name || region.id, displayOrder: (index + 1) * 10 })),
    capabilities: status.capabilities.map((capability) => ({
      id: capability.id,
      displayName: capability.display_name || capability.id,
      enabled: capability.enabled,
      mode: capabilityMode(capability.mode),
      entryGroup: capability.base_groups?.[0] || capability.base_group || null,
      policyGroups: capability.base_groups?.slice(1) || [],
      regionIds: visibleRegions.map((region) => region.id).filter((id) => !(capability.excluded_regions || []).includes(id)),
      preferRegionFrom: capability.prefer_region_from,
    })),
    routingRules: [],
    automation: {
      enabled: automation?.enabled !== false,
      selectionIntervalSeconds: automation?.selection_interval_seconds || 1800,
      subscriptionRefreshEnabled: automation?.subscription_refresh_enabled !== false,
      subscriptionRefreshIntervalSeconds: automation?.subscription_refresh_interval_seconds || 43200,
    },
    safety: {
      regionSwitchMarginMs: status.selection?.region_switch_margin_ms || 150,
      leafSwitchMarginMs: status.selection?.leaf_switch_margin_ms || 150,
      runtimeGraceSeconds: automation?.runtime_grace_seconds || 120,
      latencyUrl: 'https://www.gstatic.com/generate_204',
      protectedUrl: 'https://www.gstatic.com/generate_204',
    },
  };
}

export function validateConfigDraft(draft: ConfigDraft): string[] {
  const errors: string[] = [];
  const enabledProviders = draft.providers.filter((provider) => provider.enabled);
  if (!draft.recoveryProfile.ref.trim()) errors.push('请选择退出与故障恢复使用的原生配置。');
  if (enabledProviders.length === 0) errors.push('至少选择一个参与 NetFleet 的机场。');
  if (!enabledProviders.some((provider) => provider.role === 'primary')) errors.push('至少需要一个主用机场。');
  if (!draft.capabilities.some((capability) => capability.enabled)) errors.push('至少启用一个出口能力。');
  if (draft.capabilities.some((capability) => capability.enabled && !capability.entryGroup)) errors.push('每个已启用出口都要选择默认出口组。');
  const groups = draft.capabilities.flatMap((item) => [item.entryGroup, ...item.policyGroups].filter(Boolean));
  if (new Set(groups).size !== groups.length) errors.push('同一个策略组不能绑定到多个出口。');
  if (draft.routingRules.some((rule) => !/^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])$/.test(rule.value) || !rule.value.includes('.'))) errors.push('域名规则必须是纯域名后缀。');
  if (draft.regions.some((region) => !region.displayName.trim())) errors.push('地区显示名称不能为空。');
  if (draft.automation.enabled && draft.automation.selectionIntervalSeconds < 300) errors.push('周期选优不能短于 5 分钟。');
  if (draft.safety.regionSwitchMarginMs < 0 || draft.safety.leafSwitchMarginMs < 0) errors.push('切换门槛不能为负数。');
  if (!draft.safety.latencyUrl.startsWith('https://')) errors.push('测速地址必须使用 HTTPS。');
  if (!draft.safety.protectedUrl.startsWith('https://')) errors.push('业务保护地址必须使用 HTTPS。');
  return errors;
}

export function configSummary(draft: ConfigDraft) {
  return {
    providerCount: draft.providers.filter((provider) => provider.enabled).length,
    primaryCount: draft.providers.filter((provider) => provider.enabled && provider.role === 'primary').length,
    reserveCount: draft.providers.filter((provider) => provider.enabled && provider.role === 'reserve').length,
    automaticRegionCount: draft.regions.filter((region) => region.mode === 'automatic').length,
    capabilityCount: draft.capabilities.filter((capability) => capability.enabled).length,
  };
}
