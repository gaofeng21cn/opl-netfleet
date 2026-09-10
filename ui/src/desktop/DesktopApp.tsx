import { useCallback, useEffect, useRef, useState } from 'react';
import { automaticSelectionCopy } from '../lib/selection';
import { AlertCircle } from 'lucide-react';
import { Shell } from '../components/Shell';
import { OverviewDigest } from '../components/OverviewDigest';
import { OverviewExitSummary } from '../components/OverviewExitSummary';
import { CapabilityPanel } from '../components/CapabilityPanel';
import { PolicySummary } from '../components/PolicySummary';
import { ResultNotice } from '../components/ResultNotice';
import { DataSourceBar } from '../components/DataSourceBar';
import { RegionSelectionDialog } from '../components/RegionSelectionDialog';
import { ConfirmDialog } from '../components/ConfirmDialog';
import { ProviderTable, RegionTable } from '../views/Tables';
import { EventsView } from '../views/EventsView';
import type { ViewId } from '../types';
import type { DesktopNetFleetClient } from './client';
import type { DesktopSnapshot } from './types';
import { DesktopConfiguration } from './DesktopConfiguration';
import { LogsAndBackup, RuntimeControls, SubscriptionManager, type RunAction } from './panels';

const pages = ['overview', 'exits', 'providers', 'regions', 'config', 'events'] as const;
const titles: Record<string, string> = { overview: '网络概览', exits: '出口', providers: '机场', regions: '地区', config: '配置', events: '诊断' };
const descriptions: Record<string, string> = { overview: '查看本机连接状态，管理代理与网络接入。', exits: '为不同业务选择合适的出口。', providers: '管理订阅来源，比较机场覆盖与连接质量。', regions: '查看可用地区，为业务指定出口位置。', config: '管理基础配置、业务策略与自动运行。', events: '查看连接与运行记录，备份本机配置。' };
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
  const [showSubscriptions, setShowSubscriptions] = useState(false);
  const [selection, setSelection] = useState<Selection | null>(null);
  const [confirmAutomatic, setConfirmAutomatic] = useState(false);
  const inflight = useRef(false);
  const readPending = useRef<Promise<void> | null>(null);
  const subscriptionsRef = useRef<HTMLDivElement>(null);
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
  useEffect(() => { if (showSubscriptions && view === 'providers') subscriptionsRef.current?.scrollIntoView({ block: 'nearest' }); }, [showSubscriptions, view]);
  const run: RunAction = async (title, work) => {
    if (inflight.current || !connected) return false;
    inflight.current = true; setBusy(true); setProgress({ title, started: Date.now() }); setResult(null);
    const started = Date.now();
    try {
      await readPending.current;
      const outcome = await work() as { message?: string; ready?: boolean } | undefined;
      try { applySnapshot(await client.readSnapshot()); }
      catch (reason) { setConnected(false); setReadError(reasonText(reason)); setResult({ id: crypto.randomUUID(), title, warning: true, detail: '操作已返回成功，但状态回读失败。请先刷新确认结果，不要重复提交。' }); return false; }
      setResult({ id: crypto.randomUUID(), title, warning: outcome?.ready === false, detail: outcome?.message || `操作完成，状态已更新。用时 ${((Date.now() - started) / 1000).toFixed(1)} 秒。` });
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
  const openSubscriptions = () => { setShowSubscriptions(true); subscriptionsRef.current?.scrollIntoView({ block: 'nearest' }); };
  const selectionBlocked = !connected || snapshot?.error ? '状态读取失败，请刷新后重试' : busy ? '已有操作正在执行' : !readyToSelect ? '启用 NetFleet 后可切换地区' : undefined;
  const automatic = automaticSelectionCopy(Boolean(status?.selection?.automation_paused));
  return <Shell platform="desktop" view={view} onViewChange={navigate} busy={busy} healthy={connected && !snapshot?.error} readOnly={!connected} canSelect={Boolean(readyToSelect && automaticId)} automationPaused={status?.selection?.automation_paused} canDisable={Boolean(readyToSelect)} dashboardReady={false} onRefresh={() => void refresh()} onSelect={() => setConfirmAutomatic(true)} onDisable={() => void run('退出增强并保留原生代理', () => client.disable())} onOpenDashboard={() => undefined}>
    <div className="nf-page-heading"><div><h1>{titles[view]}</h1><p>{descriptions[view]}</p></div></div>
    {(readError || snapshot?.error) && <div className="nf-alert" role="alert"><AlertCircle aria-hidden="true" /><span>{readError || snapshot?.error}</span></div>}
    {progress && <section className="nf-operation" role="status" aria-live="polite"><strong>{progress.title}</strong><p className="nf-operation-detail">请求正在执行，已等待 {elapsed} 秒。完成后将重新读取本机状态。</p></section>}
    {result && <ResultNotice scope={location.origin} slot="desktop-action" identity={result.id} title={result.title} warning={result.warning}>{result.detail}</ResultNotice>}
    {!snapshot && <p className="nf-empty">{busy ? '正在读取本机运行状态…' : '尚未取得本机状态。请使用“刷新”重新连接。'}</p>}
    {snapshot && <>
      {view === 'overview' && <>
        <RuntimeControls snapshot={snapshot} client={client} run={run} disabled={blocked} />
        {!snapshot.runtime.configured && <section className="nf-desktop-welcome"><div><h2>{Object.keys(snapshot.subscriptions).length ? '订阅尚未准备完成' : '添加订阅，准备你的网络'}</h2><p>{Object.keys(snapshot.subscriptions).length ? '订阅已保存在本机，但还缺少可识别的地区或主入口。可重新准备，或导入完整配置。' : '粘贴机场订阅后自动下载、校验并生成配置。准备过程不会启动代理或接管本机流量。'}</p></div><button className="nf-button-primary" onClick={() => { navigate('providers'); setShowSubscriptions(true); }}>{Object.keys(snapshot.subscriptions).length ? '查看机场订阅' : '添加订阅'}</button></section>}
        {status && <><OverviewExitSummary snapshot={status} onOpen={() => navigate('exits')} /><OverviewDigest status={status} events={snapshot.events || { events: [] }} onOpen={navigate} platform="desktop" /></>}
      </>}
      {view === 'exits' && (status ? <><div className="nf-capability-list is-detailed">{status.capabilities.map(capability => <CapabilityPanel key={capability.id} snapshot={status} capability={capability} disabled={!readyToSelect} onChooseRegion={() => setSelection({ capability: capability.id })} onSelectAuto={automaticId ? () => setConfirmAutomatic(true) : undefined} />)}</div><PolicySummary snapshot={status} /></> : <p className="nf-empty">添加订阅并完成准备后，这里显示业务出口。</p>)}
      <div hidden={view !== 'providers'}>
        {status && <ProviderTable snapshot={status} full onManageSubscriptions={openSubscriptions} />}
        {!status && <p className="nf-empty">编译后可查看机场的地区覆盖与运行测量；订阅来源可先在下方管理。</p>}
        <div ref={subscriptionsRef} hidden={Boolean(status) && !showSubscriptions}><SubscriptionManager snapshot={snapshot} disabled={blocked} client={client} run={run} /></div>
      </div>
      {view === 'regions' && (status ? <RegionTable snapshot={status} full onChooseRegion={region => setSelection({ region })} blockedReason={selectionBlocked} /> : <p className="nf-empty">添加订阅并完成准备后，这里显示已识别地区。</p>)}
      <div hidden={view !== 'config'}><DesktopConfiguration snapshot={snapshot} disabled={blocked} client={client} run={run} onManageSubscriptions={() => { navigate('providers'); setShowSubscriptions(true); }} /></div>
      <div hidden={view !== 'events'}>
        {status && <EventsView sections={['events']} snapshot={snapshot.events || { events: [] }} status={status} connections={{ connections: [], count: 0, truncated: false }} connectionsLoading={false} stale={!connected} />}
        {!status && <p className="nf-empty">当前尚无已编译业务策略，仍可读取日志和管理备份。</p>}
        <LogsAndBackup snapshot={snapshot} disabled={blocked} client={client} run={run} />
      </div>
    </>}
    <DataSourceBar source={{ mode: 'live', label: '本机认证服务', target_label: '当前 Mac', read_only: blocked, connected, fetched_at: fetchedAt }} statusError={readError || snapshot?.error} />
    {selection && status && <RegionSelectionDialog snapshot={status} initialCapability={selection.capability} initialRegion={selection.region} blockedReason={selectionBlocked} onCancel={() => setSelection(null)} onConfirm={(capability, region) => { setSelection(null); void run('切换并保持地区', () => client.selectRegion(capability, region)); }} />}
    {confirmAutomatic && <ConfirmDialog {...automatic} busy={!readyToSelect || !automaticId} onCancel={() => setConfirmAutomatic(false)} onConfirm={() => { if (!automaticId || !readyToSelect) return; setConfirmAutomatic(false); void run(automatic.title, () => client.selectAuto(automaticId)); }} />}
  </Shell>;
}
