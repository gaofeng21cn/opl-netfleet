import { fixtureScenarios, type FixtureScenario } from '../data/fixtures';
import type { ComponentsSnapshot, DataSourceInfo, DiagnosticsSnapshot, EventsSnapshot, MaintenanceSnapshot, NetFleetClient, NetworkSnapshot, OperationsSnapshot, StatusSnapshot } from '../types';

const clone = <T,>(value: T): T => structuredClone(value);

export class MockNetFleetClient implements NetFleetClient {
  private scenario: FixtureScenario = 'healthy';
  private currentStatus: StatusSnapshot = clone(fixtureScenarios.healthy.status);
  private currentEvents: EventsSnapshot = clone(fixtureScenarios.healthy.events);
  private source: DataSourceInfo = {
    mode: 'mock',
    label: '模拟场景',
    target_label: '脱敏合同数据',
    read_only: true,
    connected: true,
  };

  setScenario(scenario: FixtureScenario) {
    this.scenario = scenario;
    this.currentStatus = clone(fixtureScenarios[scenario].status);
    this.currentEvents = clone(fixtureScenarios[scenario].events);
    this.source = { ...this.source, mode: 'mock', label: '模拟场景', target_label: '脱敏合同数据' };
  }

  loadFixture(status: StatusSnapshot, events: EventsSnapshot) {
    this.currentStatus = clone(status);
    this.currentEvents = clone(events);
    this.source = { ...this.source, mode: 'snapshot', label: '私有设备快照', target_label: '本机文件' };
  }

  getScenario() {
    return this.scenario;
  }

  async status() {
    return clone(this.currentStatus);
  }

  async read() {
    return {
      status: clone(this.currentStatus),
      events: clone(this.currentEvents),
      source: { ...this.source, fetched_at: Math.floor(Date.now() / 1000), duration_ms: 0 },
    };
  }

  async events() {
    return clone(this.currentEvents);
  }

  async connections() {
    return { connections: [], count: 0, truncated: false };
  }

  async components(): Promise<ComponentsSnapshot> {
    if (this.source.mode !== 'mock') throw new Error('此私有快照未包含组件信息');
    return {
      supported: true, backend: 'native-mihomo', architecture: 'aarch64',
      feed: { configured: true, url: 'https://example.test/netfleet/packages.adb', checked_at: null, error: null },
      components: [
        { id: 'netfleet', label: 'NetFleet', installed_version: '0.5.2-r1', running_version: null, available_version: null, update_available: false, managed: true, reason: null },
        { id: 'luci', label: 'LuCI 界面', installed_version: '0.5.2-r1', running_version: null, available_version: null, update_available: false, managed: true, reason: null },
        { id: 'mihomo', label: 'Mihomo', installed_version: '1.19.30-r1', running_version: 'v1.19.30', available_version: null, update_available: false, managed: true, reason: null },
      ],
      dependencies: [{ id: 'ucode', label: 'ucode', installed_version: null, available: true }, { id: 'yq', label: 'yq', installed_version: null, available: true }],
      extensions: [{ id: 'https-compat', label: 'HTTPS 兼容', kind: 'optional', package: 'opl-netfleet-https-compat',
        installed_version: '0.1.0-r1', api_version: 1, compatible: true, available: true, state: 'ready', reason: null,
        dependencies: [{ id: 'python3', available: true, installed_version: '3.13.7-r1' }], ui: ['settings', 'components', 'diagnostics'] }],
      dashboard: { id: 'zashboard', label: 'Zashboard', installed_version: null, available_version: null, available: true, managed: true, update_available: false, checked_at: null, error: null, reason: null, release_url: null },
    };
  }

  async network(): Promise<NetworkSnapshot> {
    if (this.source.mode !== 'mock') throw new Error('此私有快照未包含网络接入信息');
    if (this.currentStatus.runtime.backend?.id !== 'native-mihomo') return { available: false, reason: 'native_backend_required', revision: null, settings: null };
    return {
      available: true, backend: 'native-mihomo', revision: 'fixture-network', running: Boolean(this.currentStatus.runtime.mihomo_running),
      settings: {
        dns: { nameservers: ['1.1.1.1'], default_nameservers: ['1.1.1.1'], proxy_nameservers: [], direct_nameservers: [], policies: [], proxy_policies: [] },
        lan: { enabled: true, interfaces: ['br-lan'], rules: [] }, router: { enabled: true },
        listeners: { mixed_port: 7890, http_port: 0, socks_port: 0, authentication_enabled: false, credentials: [] },
      },
      resources: { interfaces: [{ name: 'br-lan', up: true, device: 'br-lan' }], preserved_dns_policy_count: 0, preserved_proxy_policy_count: 0 },
    };
  }

  async maintenance(): Promise<MaintenanceSnapshot> {
    if (this.source.mode !== 'mock') throw new Error('此私有快照未包含配置维护信息');
    const native = this.currentStatus.runtime.backend?.id === 'native-mihomo';
    return {
      supported: native, reason: native ? null : 'native_backend_required', revision: 'fixture-maintenance',
      profiles: [], core: { running: Boolean(this.currentStatus.runtime.mihomo_running), controller_available: Boolean(this.currentStatus.runtime.controller_available), running_version: null, actions: native ? ['restart', 'reload'] : [] },
      backup: { format: 'netfleet-backup-v1', contains_credentials: true },
    };
  }

  async diagnostics(): Promise<DiagnosticsSnapshot> {
    if (this.source.mode !== 'mock') throw new Error('此私有快照未包含核心诊断信息');
    return { supported: this.currentStatus.runtime.backend?.id === 'native-mihomo', core_running: Boolean(this.currentStatus.runtime.mihomo_running), controller_available: Boolean(this.currentStatus.runtime.controller_available), captured_at: Math.floor(Date.now() / 1000), lines: [], truncated: false };
  }

  async operations(): Promise<OperationsSnapshot> {
    return { subscription: null, packages: null };
  }

  async enable() {
    this.setScenario('healthy');
    this.record('enable', 'fastest_eligible', this.currentStatus.selection?.automatic_capability_id);
    return { state: 'active' };
  }

  async selectAuto(capability: string) {
    this.currentStatus.selection = { ...this.currentStatus.selection, automation_paused: false };
    this.record('select', 'fastest_eligible', capability);
    return { state: 'active' };
  }

  async refresh() {
    const at = Math.floor(Date.now() / 1000);
    this.currentStatus.subscription_refresh = {
      ...(this.currentStatus.subscription_refresh || {}),
      last_run_at: at,
      last_result: 'unchanged',
      last_ok: true,
      last_changed_count: 0,
      last_failed_count: 0,
      last_reloaded: false,
    };
    this.record('refresh', 'unchanged');
    return { state: 'unchanged' };
  }

  async disable() {
    this.setScenario('inactive');
    this.record('disable', 'native_restored');
    return { state: 'native_profile' };
  }

  private record(action: string, reason: string, capability: string | null = null) {
    const selected = capability
      ? this.currentStatus.capabilities.find((item) => item.id === capability)
      : null;
    this.currentEvents.events.push({
      at: Math.floor(Date.now() / 1000),
      action,
      initiator: 'luci',
      capability,
      region_id: selected?.region_id,
      provider_id: selected?.provider_id,
      leaf: selected?.leaf,
      delay_ms: selected?.reason?.delay_ms,
      reason,
    });
  }
}
