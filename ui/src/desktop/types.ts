import type { DeviceConfigSnapshot, EventsSnapshot, Quota, StatusSnapshot } from '../types';

export type DesktopMode = 'direct' | 'mihomo' | 'netfleet';
export type NetworkMode = 'explicit' | 'system' | 'tun';
export interface DesktopSubscription {
  name: string;
  enabled: boolean;
  imported?: boolean;
  hasUrl?: boolean;
  quota?: Quota;
  updatedAt?: string | null;
  nodeCount?: number | null;
}
// 本机核心设置投影：每行由 owner 给出生效值、Profile 声明值和运行回读。
export interface CoreSettingRow {
  id: string;
  group: string;
  label: string;
  source: 'platform' | 'profile' | 'core_default';
  configured: string | null;
  declared: string | null;
  running: string | null;
}
export interface CoreComponent {
  id: string;
  label: string;
  version: string | null;
  source: 'running' | 'runtime' | 'package';
}
// 更新候选只报告版本与来源；安装由独立确认的面板更新动作完成。
export interface UpdateCandidate {
  installed: string | null;
  available: string | null;
  update_available: boolean;
  url?: string | null;
  size?: number;
  sha256?: string;
  published_at?: string | null;
  installation_unknown?: boolean;
  error?: string;
}
export interface UpdateStatus {
  schema: 'opl-netfleet-macos-updates.v1';
  checked_at: number;
  panel: UpdateCandidate | null;
  app: UpdateCandidate | null;
  errors: string[];
}
export interface DesktopSnapshot {
  runtime: {
    platform: 'macos';
    running: boolean;
    configured: boolean;
    mode: DesktopMode | 'unconfirmed';
    requestedMode: DesktopMode;
    networkMode: NetworkMode;
    ports: { mixed: number; controller: number; dns: number };
    controllerReady: boolean;
    clean: boolean;
    pid: number | null;
    version: string | null;
    lastError: string | null;
  };
  policy: Record<string, unknown> | null;
  subscriptions: Record<string, DesktopSubscription>;
  status: StatusSnapshot | null;
  events: EventsSnapshot | null;
  config: DeviceConfigSnapshot | null;
  configError: string | null;
  network: {
    helper?: string;
    ready?: boolean;
    clean?: boolean;
    authorized?: boolean;
    owned?: boolean;
    recoveryRequired?: boolean;
    status?: string;
    [key: string]: unknown;
  };
  core: {
    profile: string | null;
    mode: NetworkMode;
    running: boolean;
    overlay: boolean;
    rows: CoreSettingRow[];
    components: CoreComponent[];
    identity: {
      version: string | null;
      release: string | null;
      channel: string | null;
      source_commit: string | null;
      source_tree: string | null;
      working_tree_dirty: boolean;
    } | null;
  };
  // 面板可用性来自本机核心能否提供随包资源；连接信息按需读取，不进入快照。
  dashboard: {
    available: boolean;
    version: string | null;
    reason: string | null;
  };
  error: string | null;
}
