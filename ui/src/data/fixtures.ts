import type { EventsSnapshot, StatusSnapshot } from '../types';

const gib = (value: number) => value * 1024 * 1024 * 1024;

const healthy: StatusSnapshot = {
  active: true,
  policy_enabled: true,
  profile: 'file:opl-netfleet/mvp.json',
  policy_source: { kind: 'profile', ref: 'subscription:source' },
  recovery_profile: 'subscription:recovery',
  recovery_profile_display_name: '示例恢复配置',
  runtime: {
    mihomo_running: true,
    nikki_enabled: true,
    netfleet_present: true,
    controller_available: true,
    lan_runtime: {
      transparent_proxy_ready: true,
      dns_ready: true,
      dashboard_lan_ready: true,
      allow_lan: true,
      api_listen: '0.0.0.0:9090',
      dns_enabled: true,
      dns_listen: '[::]:1053',
      dns_tcp_wildcard: true,
      dns_udp_wildcard: true,
      dns_hijack_rule_present: true,
      dns_query_ok: true,
      tproxy_tcp_wildcard: true,
      tproxy_udp_wildcard: true,
      tproxy_rule_present: true,
      controller_wildcard: true,
    },
    supervisor: { installed: true, enabled: true, running: true },
  },
  selection: {
    automatic_capability_id: 'standard',
    automatic_capability_ids: ['standard', 'ai-compatible'],
    automation_paused: false,
    region_switch_margin_ms: 150,
    leaf_switch_margin_ms: 150,
    automation: { enabled: true, selection_interval_seconds: 1800, poll_interval_seconds: 15, startup_grace_seconds: 120, runtime_grace_seconds: 45, subscription_refresh_enabled: true, subscription_refresh_interval_seconds: 43200 },
  },
  subscription_refresh: {
    enabled: true, interval_seconds: 43200, provider_count: 3, last_run_at: 1788146100,
    last_result: 'unchanged', last_ok: true, last_changed_count: 0, last_failed_count: 0, last_reloaded: false,
  },
  subscriptions: [
    { section: 'alpha-source', ref: 'subscription:alpha-source', display_name: 'Alpha 正式机场', cache_present: true, cache_sha256: 'a'.repeat(64), quota: { state: 'available', remaining_bytes: gib(812.6) }, last_attempt: 1788146100, last_success: 1788146100, last_result: 'unchanged' },
    { section: 'beta-source', ref: 'subscription:beta-source', display_name: 'Beta 高级机场', cache_present: true, cache_sha256: 'b'.repeat(64), quota: { state: 'available', remaining_bytes: gib(526.3) }, last_attempt: 1788146100, last_success: 1788146100, last_result: 'updated' },
    { section: 'gamma-source', ref: 'subscription:gamma-source', display_name: 'Gamma 备用机场', cache_present: true, cache_sha256: 'c'.repeat(64), quota: { state: 'unknown' }, last_attempt: null, last_success: null, last_result: null },
  ],
  capabilities: [
    {
      id: 'standard', display_name: '海外加速', enabled: true, compiled: true, mode: 'automatic', user_mode: 'automatic',
      base_group: 'OUTBOUND', base_groups: ['OUTBOUND'], data_path: 'preferred', provider_id: 'alpha', region_id: 'japan',
      role: 'primary', leaf: 'JP-Tokyo-02', alive: true, region_switch_margin_ms: 150, leaf_switch_margin_ms: 150,
      fail_open_stages: [
        { kind: 'preferred' }, { kind: 'provider_tier', role: 'primary', provider_ids: ['alpha', 'beta'] },
        { kind: 'provider_tier', role: 'reserve', provider_ids: ['gamma'] }, { kind: 'direct' },
      ],
      reason: { kind: 'automatic_decision', delay_ms: 78, changed_region: false, decision_reason: 'current_region_fastest', protected_probes_ok: true },
    },
    {
      id: 'ai-compatible', display_name: 'AI 出口', enabled: true, compiled: true, mode: 'automatic', user_mode: 'automatic',
      base_group: 'AI-OUTBOUND', base_groups: ['AI-OUTBOUND', 'CLAUDE-OUTBOUND'], data_path: 'preferred', provider_id: 'beta',
      region_id: 'singapore', role: 'primary', leaf: 'SG-Singapore-01', alive: true, prefer_region_from: 'standard',
      excluded_regions: ['hong_kong'],
      region_switch_margin_ms: 150, leaf_switch_margin_ms: 80,
      fail_open_stages: [
        { kind: 'preferred' }, { kind: 'provider_tier', role: 'primary', provider_ids: ['alpha', 'beta'] }, { kind: 'direct' },
      ],
      reason: { kind: 'automatic_decision', delay_ms: 102, changed_region: false, decision_reason: 'fastest_eligible', protected_probes_ok: true },
    },
  ],
  providers: [
    { id: 'alpha', display_name: 'Alpha 正式机场', subscription_section: 'alpha-source', role: 'primary', billing: 'subscription', selected: true, available_region_count: 4, region_count: 5, available_count: 18, candidate_count: 20, best_delay_ms: 78, last_best_delay_ms: 78, average_best_delay_ms: 84, delay_sample_count: 24, quota: { state: 'available', remaining_bytes: gib(812.6) } },
    { id: 'beta', display_name: 'Beta 高级机场', subscription_section: 'beta-source', role: 'primary', billing: 'subscription', selected: true, available_region_count: 5, region_count: 5, available_count: 16, candidate_count: 18, best_delay_ms: 102, last_best_delay_ms: 102, average_best_delay_ms: 118, delay_sample_count: 24, quota: { state: 'available', remaining_bytes: gib(526.3) } },
    { id: 'gamma', display_name: 'Gamma 备用机场', subscription_section: 'gamma-source', role: 'reserve', billing: 'buyout', selected: false, available_region_count: 3, region_count: 4, available_count: 8, candidate_count: 12, best_delay_ms: 168, last_best_delay_ms: 168, average_best_delay_ms: 168, delay_sample_count: 1, quota: { state: 'unknown' } },
  ],
  regions: [
    { id: 'japan', display_name: '🇯🇵 日本', mode: 'automatic', selected: true, available_provider_count: 2, provider_count: 3, available_node_count: 11, node_count: 13, last_best_delay_ms: 78, average_best_delay_ms: 84, delay_sample_count: 24 },
    { id: 'singapore', display_name: '🇸🇬 新加坡', mode: 'automatic', selected: true, available_provider_count: 2, provider_count: 2, available_node_count: 8, node_count: 9, last_best_delay_ms: 102, average_best_delay_ms: 118, delay_sample_count: 24 },
    { id: 'hong_kong', display_name: '🇭🇰 香港', mode: 'automatic', available_provider_count: 2, provider_count: 2, available_node_count: 7, node_count: 8, last_best_delay_ms: 92, average_best_delay_ms: 101, delay_sample_count: 24 },
    { id: 'taiwan', display_name: '🇹🇼 台湾', mode: 'automatic', available_provider_count: 2, provider_count: 2, available_node_count: 5, node_count: 6, last_best_delay_ms: 96, average_best_delay_ms: 96, delay_sample_count: 1 },
    { id: 'united_states', display_name: '🇺🇸 美国', mode: 'automatic', available_provider_count: 3, provider_count: 3, available_node_count: 9, node_count: 12, last_best_delay_ms: 168, average_best_delay_ms: 176, delay_sample_count: 24 },
  ],
  actions: { can_enable: false, can_select_auto: true, can_refresh: true, can_disable: true },
};

const events: EventsSnapshot = {
  display_names: {
    capabilities: { standard: '海外加速', 'ai-compatible': 'AI 出口' },
    providers: { alpha: 'Alpha 正式机场', beta: 'Beta 高级机场', gamma: 'Gamma 备用机场' },
    regions: { japan: '🇯🇵 日本', singapore: '🇸🇬 新加坡', hong_kong: '🇭🇰 香港', taiwan: '🇹🇼 台湾', united_states: '🇺🇸 美国' },
  },
  events: [
    { at: 1788144300, action: 'enable', initiator: 'luci', capability: 'standard', region_id: 'japan', provider_id: 'alpha', leaf: 'JP-Tokyo-02', delay_ms: 78, reason: 'fastest_eligible' },
    { at: 1788146100, action: 'select', trigger: 'scheduled', initiator: 'supervisor', capability: 'standard', region_id: 'japan', provider_id: 'alpha', leaf: 'JP-Tokyo-02', delay_ms: 78, reason: 'current_region_fastest' },
    { at: 1788146101, action: 'select', trigger: 'scheduled', initiator: 'supervisor', capability: 'ai-compatible', region_id: 'singapore', provider_id: 'beta', leaf: 'SG-Singapore-01', delay_ms: 102, reason: 'fastest_eligible' },
  ],
  nikki_lines: [
    'NETFLEET-SELECT capability=standard outcome=kept_current_region delay_ms=78',
    'NETFLEET-SELECT capability=ai-compatible outcome=fastest_eligible delay_ms=102',
  ],
};

const degraded: StatusSnapshot = structuredClone(healthy);
degraded.capabilities[0].data_path = 'provider_fallback';
degraded.capabilities[0].provider_id = 'gamma';
degraded.capabilities[0].region_id = null;
degraded.capabilities[0].leaf = 'US-LosAngeles-01';
degraded.capabilities[0].role = 'reserve';
degraded.capabilities[0].reason = { kind: 'provider_fallback', preferred_provider_id: 'alpha', preferred_region_id: 'japan' };
degraded.providers[0].selected = false;
degraded.providers[2].selected = true;
degraded.providers[0].available_region_count = 0;
degraded.providers[0].best_delay_ms = null;

const inactive: StatusSnapshot = structuredClone(healthy);
inactive.active = false;
inactive.runtime.netfleet_present = false;
inactive.runtime.supervisor = { installed: true, enabled: true, running: false };
inactive.profile = 'subscription:base';
inactive.actions = { can_enable: true, can_select_auto: false, can_disable: false };
inactive.capabilities = inactive.capabilities.map((capability) => ({
  ...capability,
  data_path: 'native_profile',
  user_mode: 'native_profile',
  runtime_path: [capability.base_group || '出口', 'Nikki 原生自动选择', 'Native-Leaf'],
  reason: { kind: 'native_profile' },
}));

export const fixtureScenarios = {
  healthy: { label: '健康运行', status: healthy, events },
  degraded: { label: '机场回退', status: degraded, events },
  inactive: { label: '原生配置', status: inactive, events },
};

export type FixtureScenario = keyof typeof fixtureScenarios;
