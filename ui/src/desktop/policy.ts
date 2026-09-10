import { createConfigDraft, type ConfigDraft } from '../config/model';
import type { DeviceConfigSnapshot } from '../types';
import type { DesktopSnapshot } from './types';

export function toDesktopDraft(snapshot: DesktopSnapshot): ConfigDraft {
  if (!snapshot.status || !snapshot.config) throw new Error(snapshot.configError || '业务配置尚不可读取。');
  return createConfigDraft(snapshot.status, snapshot.config);
}

// Send editor fields, not a reconstructed policy. The shared configuration owner
// merges them with its authoritative policy and rejects stale revisions.
export function desktopConfigRequest(config: DeviceConfigSnapshot, draft: ConfigDraft): Record<string, unknown> {
  return {
    revision: config.revision,
    policy_source: { kind: draft.policySource.kind, ref: draft.policySource.ref },
    recovery_profile_ref: draft.recoveryProfile.ref,
    providers: Object.fromEntries(draft.providers.map(item => [item.id, {
      section: item.section, enabled: item.enabled, role: item.role, billing: item.billing, region_ids: item.regionIds,
    }])),
    regions: Object.fromEntries(draft.regions.map(item => [item.id, { display_name: item.displayName, mode: item.mode }])),
    capabilities: Object.fromEntries(draft.capabilities.map(item => [item.id, {
      display_name: item.displayName, enabled: item.enabled, mode: item.mode, region_ids: item.regionIds,
      prefer_region_from: item.preferRegionFrom ?? null, entry_group: item.entryGroup, policy_groups: item.policyGroups,
    }])),
    routing_rules: draft.routingRules,
    automation: {
      enabled: draft.automation.enabled, selection_interval_seconds: draft.automation.selectionIntervalSeconds,
      subscription_refresh_enabled: draft.automation.subscriptionRefreshEnabled,
      subscription_refresh_interval_seconds: draft.automation.subscriptionRefreshIntervalSeconds,
    },
    safety: {
      region_switch_margin_ms: draft.safety.regionSwitchMarginMs,
      leaf_switch_margin_ms: draft.safety.leafSwitchMarginMs,
      runtime_grace_seconds: draft.safety.runtimeGraceSeconds,
      latency_url: draft.safety.latencyUrl, path_probe_url: draft.safety.protectedUrl,
      guard_probe_url: config.safety.guard_probe_url,
    },
  };
}
