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
  error: string | null;
}
