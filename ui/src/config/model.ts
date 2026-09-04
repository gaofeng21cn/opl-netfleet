import type { StatusSnapshot } from '../types';

export type ConfigSectionId = 'foundation' | 'providers' | 'regions' | 'exits' | 'automation' | 'safety';

export interface ProviderDraft {
  id: string;
  displayName: string;
  enabled: boolean;
  role: 'primary' | 'reserve';
  billing: 'subscription' | 'buyout';
  availableRegions?: number | null;
  availableNodes?: number | null;
}

export interface RegionDraft {
  id: string;
  displayName: string;
  mode: 'automatic' | 'manual_only';
  availableProviders?: number | null;
  availableNodes?: number | null;
}

export interface CapabilityDraft {
  id: string;
  displayName: string;
  enabled: boolean;
  mode: 'automatic' | 'manual';
  baseGroups: string[];
  excludedRegions: string[];
  preferRegionFrom?: string | null;
}

export interface ConfigDraft {
  backend: 'nikki-mihomo';
  policySource: 'bundle' | 'profile';
  recoveryProfile: string;
  providers: ProviderDraft[];
  regions: RegionDraft[];
  capabilities: CapabilityDraft[];
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

export function createConfigDraft(status: StatusSnapshot): ConfigDraft {
  const automation = status.selection?.automation;
  return {
    backend: 'nikki-mihomo',
    policySource: status.policy_source?.kind === 'profile' ? 'profile' : 'bundle',
    recoveryProfile: status.recovery_profile_display_name || '当前原生配置',
    providers: status.providers.map((provider) => ({
      id: provider.id,
      displayName: provider.display_name || provider.id,
      enabled: true,
      role: providerRole(provider.role),
      billing: providerBilling(provider.billing),
      availableRegions: provider.available_region_count,
      availableNodes: provider.available_node_count,
    })),
    regions: status.regions
      .filter((region) => (
        (region.available_node_count ?? 0) > 0 &&
        (region.available_provider_count ?? 0) > 0
      ))
      .map((region) => ({
        id: region.id,
        displayName: region.display_name || region.id,
        mode: regionMode(region.mode),
        availableProviders: region.available_provider_count,
        availableNodes: region.available_node_count,
      })),
    capabilities: status.capabilities.map((capability) => ({
      id: capability.id,
      displayName: capability.display_name || capability.id,
      enabled: capability.enabled,
      mode: capabilityMode(capability.mode),
      baseGroups: capability.base_groups?.length
        ? capability.base_groups
        : capability.base_group ? [capability.base_group] : [],
      excludedRegions: capability.excluded_regions || [],
      preferRegionFrom: capability.prefer_region_from,
    })),
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
  if (!draft.recoveryProfile.trim()) errors.push('请选择退出与故障恢复使用的原生配置。');
  if (enabledProviders.length === 0) errors.push('至少选择一个参与 NetFleet 的机场。');
  if (!enabledProviders.some((provider) => provider.role === 'primary')) errors.push('至少需要一个主用机场。');
  if (!draft.capabilities.some((capability) => capability.enabled)) errors.push('至少启用一个出口能力。');
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
