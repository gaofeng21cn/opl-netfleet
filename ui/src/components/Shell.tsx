import {
  Activity,
  BellRing,
  Globe2,
  House,
  LockKeyhole,
  Network,
  PlaneTakeoff,
  Power,
  RefreshCw,
  Route,
  Settings,
  Target,
} from 'lucide-react';
import type { PreviewControls, ViewId } from '../types';

const nav = [
  { id: 'overview' as const, label: '概览', icon: House },
  { id: 'exits' as const, label: '出口', icon: Route },
  { id: 'providers' as const, label: '机场', icon: PlaneTakeoff },
  { id: 'regions' as const, label: '地区', icon: Globe2 },
  { id: 'config' as const, label: '配置', icon: Settings },
  { id: 'events' as const, label: '事件与诊断', icon: BellRing },
];

interface ShellProps {
  view: ViewId;
  onViewChange(view: ViewId): void;
  preview?: PreviewControls;
  busy: boolean;
  healthy: boolean;
  readOnly: boolean;
  canSelect: boolean;
  canDisable: boolean;
  onRefresh(): void;
  onSelect(): void;
  onDisable(): void;
  children: React.ReactNode;
}

export function Shell({
  view,
  onViewChange,
  preview,
  busy,
  healthy,
  readOnly,
  canSelect,
  canDisable,
  onRefresh,
  onSelect,
  onDisable,
  children,
}: ShellProps) {
  return (
    <div className="nf-app">
      <aside className="nf-sidebar">
        <div className="nf-brand">
          <Network aria-hidden="true" />
          <span><strong>OPL</strong> NetFleet</span>
        </div>
        <nav className="nf-nav" aria-label="NetFleet 导航">
          {nav.map((item) => {
            const Icon = item.icon;
            return (
              <button
                className={view === item.id ? 'is-active' : ''}
                key={item.id}
                onClick={() => onViewChange(item.id)}
                type="button"
              >
                <Icon aria-hidden="true" />
                <span>{item.label}</span>
              </button>
            );
          })}
        </nav>
        <div className="nf-sidebar-foot">
          <span className={`nf-health-dot ${healthy ? '' : 'is-bad'}`} />
          <div><strong>OPL NetFleet</strong><small>共享 UI</small></div>
        </div>
      </aside>

      <div className="nf-stage">
        <header className="nf-toolbar">
          {preview ? (
            <div className="nf-preview-control">
              <Activity aria-hidden="true" />
              <span>{preview.label}</span>
              <span className="nf-divider">/</span>
              <label>
                <span className="nf-visually-hidden">数据场景</span>
                <select value={preview.scenario} onChange={(event) => preview.onScenarioChange(event.target.value)}>
                  {preview.scenarios.map((scenario) => <option key={scenario.id} value={scenario.id}>{scenario.label}</option>)}
                </select>
              </label>
            </div>
          ) : <span />}
          <div className="nf-toolbar-actions">
            {readOnly && <span className="nf-readonly-badge"><LockKeyhole aria-hidden="true" />实时只读</span>}
            <button type="button" onClick={onRefresh} disabled={busy} title="刷新状态">
              <RefreshCw aria-hidden="true" className={busy ? 'is-spinning' : ''} />
              <span>刷新</span>
            </button>
            {!readOnly && <button type="button" onClick={onSelect} disabled={busy || !canSelect} title="重新自动选优">
              <Target aria-hidden="true" />
              <span>重新选优</span>
            </button>}
            {!readOnly && <button className="is-danger" type="button" onClick={onDisable} disabled={busy || !canDisable} title="关闭 NetFleet">
              <Power aria-hidden="true" />
              <span>关闭 NetFleet</span>
            </button>}
          </div>
        </header>
        <main className="nf-main">{children}</main>
      </div>

      <nav className="nf-mobile-nav" aria-label="NetFleet 移动导航">
        {nav.map((item) => {
          const Icon = item.icon;
          return (
            <button className={view === item.id ? 'is-active' : ''} key={item.id} onClick={() => onViewChange(item.id)} type="button">
              <Icon aria-hidden="true" />
              <span>{item.label}</span>
            </button>
          );
        })}
      </nav>
    </div>
  );
}
