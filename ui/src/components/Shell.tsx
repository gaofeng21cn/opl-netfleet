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
  SquareArrowOutUpRight,
  Target,
} from 'lucide-react';
import type { PreviewControls, ViewId } from '../types';

type NavigationItem =
  | { id: ViewId; label: string; icon: typeof House; external: false }
  | { id: 'runtime'; label: string; icon: typeof House; external: true };

const nav: NavigationItem[] = [
  { id: 'overview', label: '概览', icon: House, external: false },
  { id: 'exits', label: '出口', icon: Route, external: false },
  { id: 'providers', label: '机场', icon: PlaneTakeoff, external: false },
  { id: 'regions', label: '地区', icon: Globe2, external: false },
  { id: 'runtime' as const, label: '实时运行', icon: SquareArrowOutUpRight, external: true },
  { id: 'config', label: '配置', icon: Settings, external: false },
  { id: 'events', label: '事件与诊断', icon: BellRing, external: false },
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
  dashboardReady: boolean;
  onRefresh(): void;
  onSelect(): void;
  onDisable(): void;
  onOpenDashboard(): void;
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
  dashboardReady,
  onRefresh,
  onSelect,
  onDisable,
  onOpenDashboard,
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
                className={`${view === item.id ? 'is-active' : ''}${item.external ? ' is-external' : ''}`}
                key={item.id}
                onClick={() => {
                  if (item.external) onOpenDashboard();
                  else onViewChange(item.id);
                }}
                disabled={item.external && !dashboardReady}
                title={item.external ? (dashboardReady ? '在新标签页打开完整 Zashboard' : 'Zashboard 当前不可用') : undefined}
                type="button"
              >
                <Icon aria-hidden="true" />
                <span>{item.label}{item.external ? ' ↗' : ''}</span>
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
            <button className={`${view === item.id ? 'is-active' : ''}${item.external ? ' is-external' : ''}`} key={item.id} onClick={() => {
              if (item.external) onOpenDashboard();
              else onViewChange(item.id);
            }} disabled={item.external && !dashboardReady} title={item.external ? (dashboardReady ? '在新标签页打开完整 Zashboard' : 'Zashboard 当前不可用') : undefined} type="button">
              <Icon aria-hidden="true" />
              <span>{item.label}{item.external ? ' ↗' : ''}</span>
            </button>
          );
        })}
      </nav>
    </div>
  );
}
