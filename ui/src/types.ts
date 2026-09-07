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
  available_node_count?: number | null;
  node_count?: number | null;
  node_count_known?: boolean;
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
  pending_update?: boolean;
  cache_current?: boolean;
  using_previous_cache?: boolean;
  cache_sha256?: string | null;
  node_count?: number | null;
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
  available_count?: number | null;
  candidate_count?: number | null;
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
  config?: DeviceConfigSnapshot;
  errors?: {
    status?: string;
    events?: string;
    config?: string;
  };
  source: DataSourceInfo;
}

export interface DeviceConfigSnapshot {
  revision: string;
  active: boolean;
  pending_apply: boolean;
  backend: { id: string; display_name: string };
  policy_source: { kind: 'bundle' | 'profile'; ref: string; display_name: string };
  policy_source_options: Array<{ kind: 'bundle' | 'profile'; ref: string; display_name: string }>;
  policy_groups: string[];
  recovery_profile: { ref: string; display_name: string };
  recovery_profile_options: Array<{ ref: string; display_name: string }>;
  providers: Array<{ id: string; section: string; display_name: string; enabled: boolean; role: 'primary' | 'reserve'; billing: 'subscription' | 'buyout'; region_ids: string[] }>;
  provider_options: Array<{ id: string; section: string; display_name: string; region_ids: string[] }>;
  regions: Array<{ id: string; flag?: string | null; display_name: string; display_order?: number | null; mode: 'automatic' | 'manual_only' }>;
  region_options: Array<{ id: string; code: string; display_name: string; display_order: number }>;
  capabilities: Array<{ id: string; display_name: string; enabled: boolean; mode: 'automatic' | 'manual'; region_ids: string[]; prefer_region_from?: string | null; entry_group?: string | null; policy_groups: string[]; base_groups?: string[] }>;
  routing_rules: Array<{ kind: 'domain_suffix' | 'ip_cidr'; value: string; capability?: string; target?: 'direct' }>;
  automation: { enabled: boolean; selection_interval_seconds: number; subscription_refresh_enabled: boolean; subscription_refresh_interval_seconds: number };
  safety: { region_switch_margin_ms: number; leaf_switch_margin_ms: number; runtime_grace_seconds: number; latency_url: string; path_probe_url: string; guard_probe_url: string };
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
    backend?: { id: string; display_name: string };
    mihomo_running?: boolean;
    backend_enabled?: boolean;
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
  changed_count?: number;
  failed_count?: number;
}

export interface EventsSnapshot {
  events: DecisionEvent[];
  core_lines?: string[];
  store_valid?: boolean;
  store_error?: string | null;
  core_lines_persistent?: boolean;
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
  components(): Promise<ComponentsSnapshot>;
  operations(): Promise<OperationsSnapshot>;
  network(): Promise<NetworkSnapshot>;
  maintenance(): Promise<MaintenanceSnapshot>;
  diagnostics(): Promise<DiagnosticsSnapshot>;
  enable(): Promise<unknown>;
  selectAuto(capability: string): Promise<unknown>;
  refresh(): Promise<unknown>;
  disable(): Promise<unknown>;
}

export interface OperationSnapshot {
  id: string;
  kind: 'subscription' | 'packages';
  state: 'queued' | 'running' | 'succeeded' | 'failed' | 'interrupted';
  recovery?: 'restored' | 'failed' | 'direct' | null;
  phase: string;
  started_at: number;
  updated_at: number;
  finished_at?: number | null;
  completed: number;
  total: number | null;
  subject?: string | null;
  error?: string | null;
}

export interface OperationsSnapshot {
  subscription: OperationSnapshot | null;
  packages: OperationSnapshot | null;
}

export interface ComponentsSnapshot {
  supported: boolean;
  backend: string;
  architecture: string;
  feed: { configured: boolean; url: string | null; checked_at: number | null; error: string | null };
  components: Array<{ id: 'netfleet' | 'luci' | 'mihomo'; label: string; installed_version: string | null; running_version: string | null; available_version: string | null; update_available: boolean; managed: boolean; reason: string | null }>;
  dependencies: Array<{ id: string; label: string; installed_version: string | null; available: boolean }>;
  extensions?: ExtensionComponent[];
  dashboard?: DashboardComponent;
}

export interface ExtensionComponent {
  id: string;
  label: string;
  kind: 'optional' | 'resource';
  package: string;
  installed_version: string | null;
  api_version: number | null;
  compatible: boolean;
  available: boolean;
  state: 'ready' | 'not_installed' | 'incompatible' | 'backend_unsupported' | 'dependency_missing' | 'unknown';
  reason: string | null;
  dependencies: Array<{ id: string; available: boolean | null; installed_version: string | null }>;
  ui: string[];
}

export interface DashboardComponent {
  id: 'zashboard';
  label: string;
  installed_version: string | null;
  available_version: string | null;
  available: boolean;
  managed: boolean;
  update_available: boolean;
  checked_at: number | null;
  error: string | null;
  reason: string | null;
  release_url: string | null;
}

export interface DnsPolicy { domain: string; nameservers: string[] }

export interface NetworkSettings {
  dns: { nameservers: string[]; default_nameservers: string[]; proxy_nameservers: string[]; direct_nameservers: string[]; policies: DnsPolicy[]; proxy_policies: DnsPolicy[] };
  lan: { enabled: boolean; interfaces: string[]; rules: Array<{ id: string; enabled: boolean; ipv4: string[]; ipv6: string[]; mac: string[]; proxy: boolean; dns: boolean }> };
  router: { enabled: boolean };
  listeners: { mixed_port: number; http_port: number; socks_port: number; authentication_enabled: boolean; credentials: Array<{ id: string; username: string; password_configured: boolean }> };
}

export interface NetworkSnapshot {
  available: boolean;
  reason?: string | null;
  backend?: string;
  revision: string | null;
  running?: boolean;
  settings: NetworkSettings | null;
  preview_redacted?: boolean;
  resources?: { interfaces: Array<{ name: string; up: boolean; device: string | null }>; preserved_dns_policy_count: number; preserved_proxy_policy_count: number };
}

export interface MaintenanceSnapshot {
  supported: boolean;
  reason?: string | null;
  revision: string | null;
  profiles: Array<{ id: string; ref: string; format: string; size_bytes: number; modified_at: number; referenced: boolean; editable: boolean }>;
  core: { running: boolean; controller_available?: boolean; running_version?: string | null; actions: Array<'restart' | 'reload'> };
  backup?: { format: string; contains_credentials: boolean };
}

export interface DiagnosticsSnapshot {
  supported: boolean;
  core_running: boolean;
  controller_available: boolean;
  captured_at: number;
  lines: string[];
  truncated: boolean;
}

export type ViewId = 'overview' | 'exits' | 'providers' | 'regions' | 'config' | 'components' | 'events';

export interface PreviewControls {
  label: string;
  scenario: string;
  scenarios: Array<{ id: string; label: string }>;
  onScenarioChange(scenario: string): void;
}
