export type NullableNumber = number | null | undefined;

export interface Quota {
  state: 'available' | 'exhausted' | 'unknown' | 'disabled' | string;
  remaining_bytes?: number | null;
  total_bytes?: number | null;
  expires_at?: string | null;
}

export interface FailOpenStage {
  kind: 'preferred' | 'provider_tier' | 'direct' | string;
  role?: 'primary' | 'reserve' | string | null;
  provider_ids?: string[];
}

export interface CapabilityReason {
  kind: string;
  sampled_at?: number;
  delay_ms?: number | null;
  changed_region?: boolean;
  decision_reason?: string;
  protected_probes_ok?: boolean;
  preferred_region_id?: string | null;
  preferred_provider_id?: string | null;
  region_id?: string | null;
  provider_id?: string | null;
}

export interface Capability {
  id: string;
  display_name?: string;
  enabled: boolean;
  compiled: boolean;
  mode: string;
  user_mode?: string | null;
  base_group?: string | null;
  base_groups?: string[];
  data_path: string;
  runtime_path?: string[];
  provider_id?: string | null;
  region_id?: string | null;
  role?: string | null;
  leaf?: string | null;
  alive: boolean;
  prefer_region_from?: string | null;
  allowed_regions?: string[];
  excluded_regions?: string[];
  fail_open_stages?: FailOpenStage[];
  region_switch_margin_ms?: number;
  leaf_switch_margin_ms?: number;
  reason?: CapabilityReason;
}

export interface Provider {
  id: string;
  display_name?: string;
  subscription_section?: string | null;
  role: string;
  billing: string;
  quota?: Quota;
  selected?: boolean;
  available_region_count?: number | null;
  region_count?: number | null;
  available_count?: number | null;
  candidate_count?: number | null;
  best_delay_ms?: number | null;
  last_best_delay_ms?: number | null;
  average_best_delay_ms?: number | null;
  delay_sample_count?: number | null;
  delay_sampled_at?: number | null;
}

export interface SubscriptionStatus {
  section: string;
  ref?: string | null;
  display_name?: string | null;
  cache_present?: boolean;
  cache_sha256?: string | null;
  quota?: Quota;
  last_attempt?: number | null;
  last_success?: number | null;
  last_result?: string | null;
}

export interface Region {
  id: string;
  display_name?: string;
  mode: string;
  selected?: boolean;
  available_provider_count?: number | null;
  provider_count?: number | null;
  available_node_count?: number | null;
  node_count?: number | null;
  last_best_delay_ms?: number | null;
  average_best_delay_ms?: number | null;
  delay_sample_count?: number | null;
  delay_sampled_at?: number | null;
  node_count_known?: boolean;
}

export interface DataSourceInfo {
  mode: 'device' | 'live' | 'snapshot' | 'mock';
  label: string;
  target_label?: string;
  read_only: boolean;
  connected?: boolean;
  fetched_at?: number | null;
  duration_ms?: number | null;
}

export interface ClientReadResult {
  status?: StatusSnapshot;
  events?: EventsSnapshot;
  errors?: {
    status?: string;
    events?: string;
  };
  source: DataSourceInfo;
}

export interface StatusSnapshot {
  active: boolean;
  policy_enabled: boolean;
  profile?: string | null;
  policy_source?: { kind: 'bundle' | 'profile'; ref: string } | null;
  recovery_profile?: string | null;
  recovery_profile_display_name?: string | null;
  native_runtime?: Record<string, unknown> | null;
  runtime: {
    mihomo_running?: boolean;
    nikki_enabled?: boolean;
    netfleet_present?: boolean;
    controller_available?: boolean;
    lan_runtime?: {
      transparent_proxy_ready?: boolean;
      dns_ready?: boolean;
      dashboard_lan_ready?: boolean;
      allow_lan?: boolean;
      api_listen?: string | null;
      dns_enabled?: boolean;
      dns_listen?: string | null;
      dns_tcp_wildcard?: boolean;
      dns_udp_wildcard?: boolean;
      dns_hijack_rule_present?: boolean;
      dns_query_ok?: boolean | null;
      tproxy_tcp_wildcard?: boolean;
      tproxy_udp_wildcard?: boolean;
      tproxy_rule_present?: boolean;
      controller_wildcard?: boolean;
      error?: string;
    } | null;
    cleanup?: { ok?: boolean; error?: string } | null;
    passthrough_ready?: boolean;
    supervisor?: {
      installed?: boolean;
      enabled?: boolean;
      running?: boolean;
    };
  };
  selection?: {
    automatic_capability_id?: string | null;
    automatic_capability_ids?: string[];
    automation_paused?: boolean;
    region_switch_margin_ms?: number;
    leaf_switch_margin_ms?: number;
    automation?: {
      enabled?: boolean;
      selection_interval_seconds?: number;
      poll_interval_seconds?: number;
      startup_grace_seconds?: number;
      runtime_grace_seconds?: number;
      subscription_refresh_enabled?: boolean;
      subscription_refresh_interval_seconds?: number;
    } | null;
  };
  subscription_refresh?: {
    enabled?: boolean;
    interval_seconds?: number;
    provider_count?: number;
    last_run_at?: number | null;
    last_result?: string | null;
    last_ok?: boolean | null;
    last_changed_count?: number | null;
    last_failed_count?: number | null;
    last_reloaded?: boolean | null;
    last_initiator?: string | null;
  } | null;
  subscriptions?: SubscriptionStatus[];
  capabilities: Capability[];
  providers: Provider[];
  regions: Region[];
  actions?: {
    can_enable?: boolean;
    can_select_auto?: boolean;
    can_refresh?: boolean;
    can_disable?: boolean;
  };
}

export interface DecisionEvent {
  at: number;
  action: string;
  trigger?: string;
  initiator?: string;
  capability?: string | null;
  region_id?: string | null;
  provider_id?: string | null;
  leaf?: string | null;
  to_group?: string | null;
  delay_ms?: number | null;
  reason?: string;
}

export interface EventsSnapshot {
  events: DecisionEvent[];
  nikki_lines?: string[];
  store_valid?: boolean;
  store_error?: string | null;
  nikki_lines_persistent?: boolean;
  display_names?: {
    capabilities?: Record<string, string>;
    providers?: Record<string, string>;
    regions?: Record<string, string>;
  };
}

export interface ConnectionRoute {
  destination: string;
  destination_port?: number | string | null;
  network?: string | null;
  rule?: string | null;
  rule_payload?: string | null;
  chains: string[];
}

export interface ConnectionsSnapshot {
  connections: ConnectionRoute[];
  count: number;
  truncated: boolean;
  read_at?: number;
}

export interface NetFleetClient {
  read?(): Promise<ClientReadResult>;
  status(): Promise<StatusSnapshot>;
  events(): Promise<EventsSnapshot>;
  connections(): Promise<ConnectionsSnapshot>;
  enable(): Promise<unknown>;
  selectAuto(capability: string): Promise<unknown>;
  refresh(): Promise<unknown>;
  disable(): Promise<unknown>;
}

export type ViewId = 'overview' | 'exits' | 'providers' | 'regions' | 'config' | 'events';

export interface PreviewControls {
  label: string;
  scenario: string;
  scenarios: Array<{ id: string; label: string }>;
  onScenarioChange(scenario: string): void;
}
