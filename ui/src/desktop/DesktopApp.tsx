import { useCallback, useEffect, useRef, useState } from 'react';
import { automaticSelectionCopy } from '../lib/selection';
import { AlertCircle } from 'lucide-react';
import { Shell } from '../components/Shell';
import { DesktopOverview } from './DesktopOverview';
import { CapabilityPanel } from '../components/CapabilityPanel';
import { PolicySummary } from '../components/PolicySummary';
import { ActionFeedback } from './ActionFeedback';
import { SourceDialog } from './SourceDialog';
import { RegionSelectionDialog } from '../components/RegionSelectionDialog';
import { ConfirmDialog } from '../components/ConfirmDialog';
import { ProviderTable, RegionTable } from '../views/Tables';
import { EventsView } from '../views/EventsView';
import type { ViewId } from '../types';
import type { DesktopNetFleetClient } from './client';
import type { DesktopSnapshot } from './types';
import { DesktopConfiguration } from './DesktopConfiguration';
import { DesktopTools, RuntimeControls, SubscriptionManager, type RunAction } from './panels';

const pages = ['overview', 'exits', 'providers', 'regions', 'config', 'events'] as const;
const currentPage = (): ViewId => pages.includes(location.hash.slice(1) as typeof pages[number]) ? location.hash.slice(1) as ViewId : 'overview';
const reasonText = (reason: unknown) => reason instanceof Error ? reason.message : String(reason);

type Selection = { capability?: string; region?: string };
export function DesktopApp({ client }: { client: DesktopNetFleetClient }) {
  const [view, setView] = useState<ViewId>(currentPage);
  const [snapshot, setSnapshot] = useState<DesktopSnapshot | null>(null);
  const [connected, setConnected] = useState(false);
  const [busy, setBusy] = useState(false);
  const [readError, setReadError] = useState<string | null>(null);
  const [fetchedAt, setFetchedAt] = useState<number | null>(null);
  const [progress, setProgress] = useState<{ title: string; started: number } | null>(null);
  const [elapsed, setElapsed] = useState(0);
  const [result, setResult] = useState<{ id: string; title: string; detail: string; warning?: boolean } | null>(null);
  const dismissResult = useCallback(() => setResult(null), []);
  const [showSubscriptions, setShowSubscriptions] = useState(false);
  const [diagnostic, setDiagnostic] = useState<'events' | 'connections' | 'logs'>('events');
  const [selection, setSelection] = useState<Selection | null>(null);
  const [confirmAutomatic, setConfirmAutomatic] = useState(false);
  const inflight = useRef(false);
  const readPending = useRef<Promise<void> | null>(null);
  const navigate = useCallback((next: ViewId) => { if (!pages.includes(next as typeof pages[number])) return; setView(next); history.pushState(null, '', `#${next}`); }, []);
  const applySnapshot = (value: DesktopSnapshot) => { setSnapshot(value); setConnected(true); setReadError(null); setFetchedAt(Math.floor(Date.now() / 1000)); };
  const refresh = useCallback(async () => {
    if (inflight.current || readPending.current) return;
    const pending = (async () => {
      try { applySnapshot(await client.readSnapshot()); }
      catch (reason) { setConnected(false); setReadError(reasonText(reason)); }
    })();
    readPending.current = pending;
    try { await pending; } finally { readPending.current = null; }
  }, [client]);
  useEffect(() => { void refresh(); }, [refresh]);
  useEffect(() => {
    const visibleRead = () => {
      const editing = document.activeElement?.matches('input, textarea, select, [contenteditable="true"], [contenteditable=""]');
      if (document.visibilityState === 'visible' && !inflight.current && !editing) void refresh();
    };
    const timer = setInterval(visibleRead, 10000);
    document.addEventListener('visibilitychange', visibleRead);
    return () => { clearInterval(timer); document.removeEventListener('visibilitychange', visibleRead); };
  }, [refresh]);
  useEffect(() => {
    const pop = () => setView(currentPage());
    const command = (event: Event) => { const next = (event as CustomEvent<string>).detail; if (next === 'refresh') void refresh(); else if (pages.includes(next as typeof pages[number])) navigate(next as ViewId); };
    addEventListener('popstate', pop); addEventListener('hashchange', pop); addEventListener('netfleet-command', command);
    return () => { removeEventListener('popstate', pop); removeEventListener('hashchange', pop); removeEventListener('netfleet-command', command); };
  }, [navigate, refresh]);
  useEffect(() => { if (!progress) return; const tick = () => setElapsed(Math.floor((Date.now() - progress.started) / 1000)); tick(); const timer = setInterval(tick, 1000); return () => clearInterval(timer); }, [progress]);
  const run: RunAction = async (title, work) => {
    if (inflight.current || !connected) return false;
    inflight.current = true; setBusy(true); setProgress({ title, started: Date.now() }); setResult(null);
    const started = Date.now();
    try {
      await readPending.current;
      const outcome = await work() as { message?: string; ready?: boolean } | undefined;
      try { applySnapshot(await client.readSnapshot()); }
      catch (reason) { setConnected(false); setReadError(reasonText(reason)); setResult({ id: crypto.randomUUID(), title, warning: true, detail: '操作已返回成功，但状态回读失败。请先刷新确认结果，不要重复提交。' }); return false; }
      setResult({ id: crypto.randomUUID(), title, warning: outcome?.ready === false, detail: outcome?.message || `已完成并更新状态 · ${((Date.now() - started) / 1000).toFixed(1)} 秒` });
      return true;
    } catch (reason) {
      try { applySnapshot(await client.readSnapshot()); }
      catch { setConnected(false); setReadError('本机状态读取失败，请刷新后重试。'); }
      setResult({ id: crypto.randomUUID(), title, detail: reasonText(reason), warning: true });
      return false;
    } finally { inflight.current = false; setBusy(false); setProgress(null); }
  };
  const status = snapshot?.status;
  const blocked = busy || !connected || !snapshot;
  const businessBlocked = blocked || !status || Boolean(snapshot?.error);
  const automaticId = status?.selection?.automatic_capability_id || status?.capabilities.find(capability => capability.enabled && capability.mode === 'automatic')?.id;
  const readyToSelect = !businessBlocked && snapshot?.runtime.mode === 'netfleet' && snapshot.runtime.running;
  const openSubscriptions = () => setShowSubscriptions(true);
  const selectionBlocked = !connected || snapshot?.error ? '状态读取失败，请刷新后重试' : busy ? '已有操作正在执行' : !readyToSelect ? '启用 NetFleet 后可切换地区' : undefined;
  const automatic = automaticSelectionCopy(Boolean(status?.selection?.automation_paused));
  const sourceDialogOpen = showSubscriptions && view === 'providers';
  const readFailure = (readError || snapshot?.error) && <div className="nf-alert" role="alert"><AlertCircle aria-hidden="true" /><span>{readError || snapshot?.error}</span></div>;
  const feedback = <ActionFeedback progress={progress} elapsed={elapsed} result={result} inline={sourceDialogOpen} onDismiss={dismissResult} />;
  return <Shell notice={!sourceDialogOpen && feedback} platform="desktop" view={view} onViewChange={navigate} busy={busy} healthy={connected && !snapshot?.error} readOnly={!connected} canSelect={Boolean(readyToSelect && automaticId)} automationPaused={status?.selection?.automation_paused} canDisable={Boolean(readyToSelect)} dashboardReady={false} onRefresh={() => void refresh()} onSelect={() => setConfirmAutomatic(true)} onDisable={() => void run('退出增强并保留原生代理', () => client.disable())} onOpenDashboard={() => undefined}>

    {!sourceDialogOpen && readFailure}
    {!snapshot && <p className="nf-empty">{busy ? '正在读取本机运行状态…' : '尚未取得本机状态。请使用“刷新”重新连接。'}</p>}
    {snapshot && <>
      {view === 'overview' && <>
        <RuntimeControls snapshot={snapshot} client={client} run={run} disabled={blocked} />
        <DesktopOverview snapshot={snapshot} disabled={blocked} canSelect={Boolean(readyToSelect)} onSelect={capability => setSelection({ capability })} onNavigate={next => { navigate(next); if (next === 'providers' && !snapshot.runtime.configured) setShowSubscriptions(true); }} />
      </>}
      {view === 'exits' && (status ? <><div className="nf-capability-list is-detailed">{status.capabilities.map(capability => <CapabilityPanel key={capability.id} snapshot={status} capability={capability} active={snapshot.runtime.running && snapshot.runtime.mode === 'netfleet' && status.active} disabled={!readyToSelect} onChooseRegion={() => setSelection({ capability: capability.id })} onSelectAuto={automaticId ? () => setConfirmAutomatic(true) : undefined} />)}</div><PolicySummary snapshot={status} /></> : <p className="nf-empty">添加订阅并完成准备后，这里显示业务出口。</p>)}
      <div hidden={view !== 'providers'}>
        <div className="nf-desktop-page-actions"><span>{status?.providers.length ?? 0} 个机场 · {Object.keys(snapshot.subscriptions).length} 个来源</span><button type="button" className="nf-button-secondary" disabled={blocked || !Object.values(snapshot.subscriptions).some(item => item.enabled && item.hasUrl)} onClick={() => void run('更新订阅', () => client.refresh())}>更新订阅</button><button type="button" className="nf-button-primary" onClick={openSubscriptions}>管理订阅来源</button></div>
        {status && <ProviderTable snapshot={status} full subscriptionsManaged />}
        {!status && <p className="nf-empty">添加订阅后自动准备机场资源与业务策略。</p>}
        {Object.keys(snapshot.subscriptions).some(id => !status?.providers.some(item => (item.subscription_section || item.id) === id)) && <p className="nf-management-note">部分来源尚未纳入机场列表，可在“管理订阅来源”中查看准备状态。</p>}
      </div>
      <SourceDialog open={sourceDialogOpen} onClose={() => setShowSubscriptions(false)}>{sourceDialogOpen && <>{readFailure}{feedback}</>}<SubscriptionManager snapshot={snapshot} disabled={blocked} client={client} run={run} /></SourceDialog>
      {view === 'regions' && (status ? <RegionTable snapshot={status} full onChooseRegion={region => setSelection({ region })} blockedReason={selectionBlocked} /> : <p className="nf-empty">添加订阅并完成准备后，这里显示已识别地区。</p>)}
      <div hidden={view !== 'config'}><DesktopConfiguration snapshot={snapshot} disabled={blocked} client={client} run={run} onManageSubscriptions={() => { navigate('providers'); setShowSubscriptions(true); }} /></div>
      <div hidden={view !== 'events'}>
        <nav className="nf-subtabs" aria-label="诊断分类">{([['events', '选路记录'], ['connections', '当前连接'], ['logs', '核心日志']] as const).map(([id, label]) => <button type="button" key={id} aria-current={diagnostic === id ? 'page' : undefined} onClick={() => setDiagnostic(id)}>{label}</button>)}</nav>
        <div hidden={diagnostic !== 'events'}>{status ? <EventsView sections={['events']} snapshot={snapshot.events || { events: [] }} status={status} connections={{ connections: [], count: 0, truncated: false }} connectionsLoading={false} stale={!connected} /> : <p className="nf-empty">暂无选路记录，启用后会记录实际结果。</p>}</div>
        <div hidden={diagnostic !== 'connections'}><DesktopTools section="connections" snapshot={snapshot} disabled={blocked} client={client} run={run} /></div>
        <div hidden={diagnostic !== 'logs'}><DesktopTools section="logs" snapshot={snapshot} disabled={blocked} client={client} run={run} /></div>
      </div>
    </>}
    {view === 'events' && <p className="nf-desktop-read-status" role="status">{connected ? '服务连接正常' : '服务连接失败'} · 最近读取 {fetchedAt ? new Date(fetchedAt * 1000).toLocaleTimeString('zh-CN') : '尚未读取'}</p>}
    {selection && status && <RegionSelectionDialog snapshot={status} initialCapability={selection.capability} initialRegion={selection.region} blockedReason={selectionBlocked} onCancel={() => setSelection(null)} onConfirm={(capability, region) => { setSelection(null); void run('切换并保持地区', () => client.selectRegion(capability, region)); }} />}
    {confirmAutomatic && <ConfirmDialog {...automatic} busy={!readyToSelect || !automaticId} onCancel={() => setConfirmAutomatic(false)} onConfirm={() => { if (!automaticId || !readyToSelect) return; setConfirmAutomatic(false); void run(automatic.title, () => client.selectAuto(automaticId)); }} />}
  </Shell>;
}
