import {
  Activity,
  BellRing,
  Globe2,
  House,
  LockKeyhole,
  Network,
  PlaneTakeoff,
  Package,
  Power,
  RefreshCw,
  Route,
  Settings,
  SquareArrowOutUpRight,
  Target,
} from 'lucide-react';
import type { PreviewControls, ViewId } from '../types';

type NavigationItem = { id: ViewId; label: string; icon: typeof House };

const nav: NavigationItem[] = [
  { id: 'overview', label: '概览', icon: House },
  { id: 'exits', label: '出口', icon: Route },
  { id: 'providers', label: '机场', icon: PlaneTakeoff },
  { id: 'regions', label: '地区', icon: Globe2 },
  { id: 'config', label: '配置', icon: Settings },
  { id: 'components', label: '插件与更新', icon: Package },
  { id: 'events', label: '诊断', icon: BellRing },
];

interface ShellProps {
  platform?: 'openwrt' | 'desktop';
  view: ViewId;
  onViewChange(view: ViewId): void;
  preview?: PreviewControls;
  busy: boolean;
  healthy: boolean;
  readOnly: boolean;
  canSelect: boolean;
  automationPaused?: boolean;
  canDisable: boolean;
  dashboardReady: boolean;
  onRefresh(): void;
  onSelect(): void;
  onDisable(): void;
  onOpenDashboard(): void;
  children: React.ReactNode;
  notice?: React.ReactNode;
}

export function Shell({
  platform = 'openwrt',
  view,
  onViewChange,
  preview,
  busy,
  healthy,
  readOnly,
  canSelect,
  automationPaused = false,
  canDisable,
  dashboardReady,
  onRefresh,
  onSelect,
  onDisable,
  onOpenDashboard,
  children,
  notice,
}: ShellProps) {
  const items = platform === 'desktop' ? nav.filter(item => item.id !== 'components') : nav;
  return (
    <div className={`nf-app${platform === 'desktop' ? ' nf-desktop' : ''}`}>
      <aside className="nf-sidebar">
        <div className="nf-brand">
          {platform === 'desktop' ? <img src="/logo.png" alt="" className="nf-brand-logo" /> : <Network aria-hidden="true" />}
          <span><strong>OPL</strong> NetFleet</span>
        </div>
        <nav className="nf-nav" aria-label="NetFleet 导航">
          {items.map((item) => {
            const Icon = item.icon;
            return (
              <button
                className={view === item.id ? 'is-active' : ''}
                aria-current={view === item.id ? 'page' : undefined}
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
        {platform !== 'desktop' && <div className="nf-sidebar-foot">
          <span className={`nf-health-dot ${healthy ? '' : 'is-bad'}`} />
          <div><strong>OPL NetFleet</strong><small>共享 UI</small></div>
        </div>}
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
          ) : platform === 'desktop' ? <h1 className="nf-desktop-title">{items.find(item => item.id === view)?.label}</h1> : <span />}
          <div className="nf-toolbar-actions">
            {platform !== 'desktop' && <button type="button" onClick={onOpenDashboard} disabled={!dashboardReady} title={dashboardReady ? '在新标签页打开完整 Zashboard' : 'Zashboard 当前不可用'}>
              <SquareArrowOutUpRight aria-hidden="true" /><span>Zashboard</span>
            </button>}
            {readOnly && <span className="nf-readonly-badge"><LockKeyhole aria-hidden="true" />实时只读</span>}
            {view !== 'components' && <button type="button" onClick={onRefresh} disabled={busy} title="刷新状态">
              <RefreshCw aria-hidden="true" className={busy ? 'is-spinning' : ''} />
              <span>刷新</span>
            </button>}
            {!readOnly && ['overview', 'exits', 'regions'].includes(view) && <button type="button" onClick={onSelect} disabled={busy || !canSelect} title={automationPaused ? '解除手动保持并恢复整轮自动选优' : '按切换门槛重新自动选优'}>
              <Target aria-hidden="true" />
              <span>{automationPaused ? '恢复自动选优' : '重新选优'}</span>
            </button>}
            {!readOnly && view === 'overview' && platform !== 'desktop' && <button className="is-danger" type="button" onClick={onDisable} disabled={busy || !canDisable} title="关闭 NetFleet">
              <Power aria-hidden="true" />
              <span>关闭 NetFleet</span>
            </button>}
          </div>
        </header>
        <main className="nf-main">{children}</main>
        {notice}
      </div>

      <nav className="nf-mobile-nav" aria-label="NetFleet 移动导航">
        {items.map((item) => {
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
