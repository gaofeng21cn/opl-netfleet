import { exitMeasurementState } from '../components/CapabilityPanel';
import { capabilityName, delay, regionName } from '../lib/format';
import type { StatusSnapshot } from '../types';
import type { DesktopSnapshot, NetworkMode } from './types';

// The AppKit host renders a menu from this projection and sends every choice
// back through the page's own serialized action path. Keeping the model here
// means the menu and the page read the same facts, and it stays testable
// without a running window.

export interface HostRegion {
  id: string;
  name: string;
  selected: boolean;
}

export interface HostExit {
  id: string;
  name: string;
  current: string;
  detail: string;
  automatic: boolean;
  paused: boolean;
  selectable: boolean;
  regions: HostRegion[];
}

export interface HostState {
  running: boolean;
  configured: boolean;
  busy: boolean;
  mode: string;
  networkMode: NetworkMode;
  address: string;
  summary: string;
  exits: HostExit[];
  automationPaused: boolean;
}

const currentPath = (status: StatusSnapshot, capability: StatusSnapshot['capabilities'][number], attached: boolean, measured: boolean) => {
  if (!attached) return '未接管';
  if (!measured) return '状态待确认';
  if (capability.data_path === 'direct_manual' || capability.data_path === 'direct_fallback') return '直连';
  if (capability.data_path === 'provider_fallback') return '机场退路';
  return regionName(status, capability.region_id);
};

const currentDetail = (capability: StatusSnapshot['capabilities'][number], measured: boolean) => {
  if (!measured) return '未测量';
  if (capability.data_path === 'direct_manual') return '手动直连';
  if (capability.data_path === 'direct_fallback') return '直连退路';
  return `${delay(capability.reason?.delay_ms)} · ${capability.alive ? '健康' : '不可用'}`;
};

export function hostState(snapshot: DesktopSnapshot | null, busy: boolean): HostState {
  const runtime = snapshot?.runtime;
  const status = snapshot?.status ?? null;
  const configured = Boolean(runtime?.configured);
  const running = Boolean(runtime?.running);
  const attached = Boolean(status && running && runtime?.mode === 'netfleet' && status.active);
  const exits: HostExit[] = [];
  if (status) {
    const measurement = exitMeasurementState(status, attached);
    const selected = new Set(status.regions.filter(region => region.selected).map(region => region.id));
    for (const capability of status.capabilities.filter(item => item.enabled)) {
      // A capability switch follows the page: the menu only offers regions the
      // backend already marked selectable for that exit.
      const ids = capability.selectable_regions?.length
        ? capability.selectable_regions
        : capability.can_select_region ? status.regions.map(region => region.id) : [];
      const held = capability.user_mode === 'manual_region' ? capability.manual_region_id || capability.region_id : null;
      exits.push({
        id: capability.id,
        name: capabilityName(capability),
        current: currentPath(status, capability, measurement.attached, measurement.measured),
        detail: currentDetail(capability, measurement.measured),
        automatic: capability.user_mode === 'automatic',
        paused: Boolean(status.selection?.automation_paused),
        selectable: Boolean(capability.can_select_region),
        regions: ids.map(id => ({ id, name: regionName(status, id), selected: held === id || (!held && selected.has(id)) })),
      });
    }
  }
  const primary = exits[0];
  return {
    running,
    configured,
    busy,
    mode: runtime?.mode ?? 'unconfirmed',
    networkMode: runtime?.networkMode ?? 'explicit',
    address: runtime ? `127.0.0.1:${runtime.ports.mixed}` : '',
    summary: !running ? '代理已停止' : primary ? `${primary.name} ${primary.current}` : '增强代理运行中',
    exits,
    automationPaused: Boolean(status?.selection?.automation_paused),
  };
}
