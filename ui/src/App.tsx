import { useCallback, useEffect, useMemo, useState } from 'react';
import { AlertCircle, Power, Target } from 'lucide-react';
import { CapabilityPanel } from './components/CapabilityPanel';
import { ConfirmDialog } from './components/ConfirmDialog';
import { DataSourceBar } from './components/DataSourceBar';
import { OverviewDigest } from './components/OverviewDigest';
import { OverviewExitSummary } from './components/OverviewExitSummary';
import { PolicySummary } from './components/PolicySummary';
import { RecoverySection } from './components/RecoverySection';
import { Shell } from './components/Shell';
import { StatusStrip } from './components/StatusStrip';
import { OperationProgress, operationRunning } from './components/OperationProgress';
import { ConfigView } from './config/ConfigView';
import { createConfigDraft, type ConfigDraft } from './config/model';
import { EventsView } from './views/EventsView';
import { ComponentsView } from './views/ComponentsView';
import { ProviderTable, RegionTable } from './views/Tables';
import type { ComponentsSnapshot, ConnectionsSnapshot, DataSourceInfo, DeviceConfigSnapshot, EventsSnapshot, NetFleetClient, OperationsSnapshot, PreviewControls, StatusSnapshot, ViewId } from './types';
import './styles.css';

type DialogAction = 'enable' | 'select' | 'disable' | null;

interface AppProps {
  client: NetFleetClient;
  initialStatus?: StatusSnapshot;
  initialEvents?: EventsSnapshot;
  preview?: PreviewControls;
  fallbackSource?: DataSourceInfo;
}

export function App({ client, initialStatus, initialEvents, preview, fallbackSource }: AppProps) {
  const [view, setView] = useState<ViewId>('overview');
  const [status, setStatus] = useState<StatusSnapshot | null>(initialStatus || null);
  const [events, setEvents] = useState<EventsSnapshot | null>(initialEvents || null);
  const [deviceConfig, setDeviceConfig] = useState<DeviceConfigSnapshot | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [statusError, setStatusError] = useState<string | null>(null);
  const [eventsError, setEventsError] = useState<string | null>(null);
  const [components, setComponents] = useState<ComponentsSnapshot | null>(null);
  const [componentsLoading, setComponentsLoading] = useState(false);
  const [componentsError, setComponentsError] = useState<string | null>(null);
  const [operations, setOperations] = useState<OperationsSnapshot>({ subscription: null, packages: null });
  const [operationError, setOperationError] = useState<string | null>(null);
  const [connections, setConnections] = useState<ConnectionsSnapshot>({ connections: [], count: 0, truncated: false });
  const [connectionsLoading, setConnectionsLoading] = useState(false);
  const [connectionsError, setConnectionsError] = useState<string | null>(null);
  const [source, setSource] = useState<DataSourceInfo>(fallbackSource
    ? { ...fallbackSource, connected: Boolean(initialStatus), fetched_at: initialStatus ? Math.floor(Date.now() / 1000) : null }
    : {
      mode: preview ? 'mock' : 'device',
      label: preview ? '本机预览' : '设备实时 RPC',
      target_label: preview ? '脱敏合同数据' : '当前 OpenWrt',
      read_only: Boolean(preview),
      connected: Boolean(initialStatus),
      fetched_at: initialStatus ? Math.floor(Date.now() / 1000) : null,
    });
  const [dialog, setDialog] = useState<DialogAction>(null);
  const [configState, setConfigState] = useState<{ key: string; draft: ConfigDraft; saved: ConfigDraft } | null>(null);

  const refresh = useCallback(async () => {
    setBusy(true);
    setError(null);
    setStatusError(null);
    setEventsError(null);
    const started = Date.now();
    try {
      if (client.read) {
        const snapshot = await client.read();
        setStatus(snapshot.status || null);
        setEvents(snapshot.events || null);
        setDeviceConfig(snapshot.config || null);
        setStatusError(snapshot.status ? null : snapshot.errors?.status || '设备状态读取失败');
        setEventsError(snapshot.events ? null : snapshot.errors?.events || '设备事件读取失败');
        setSource(snapshot.source);
      } else {
        const [nextStatus, nextEvents] = await Promise.allSettled([client.status(), client.events()]);
        if (nextStatus.status === 'fulfilled') setStatus(nextStatus.value);
        else setStatusError(nextStatus.reason instanceof Error ? nextStatus.reason.message : '设备状态读取失败');
        if (nextEvents.status === 'fulfilled') setEvents(nextEvents.value);
        else setEventsError(nextEvents.reason instanceof Error ? nextEvents.reason.message : '设备事件读取失败');
        setSource({
          mode: 'device', label: '设备实时 RPC', target_label: '当前 OpenWrt', read_only: false,
          connected: nextStatus.status === 'fulfilled', fetched_at: Math.floor(Date.now() / 1000), duration_ms: Date.now() - started,
        });
      }
    } catch (reason) {
      const message = reason instanceof Error ? reason.message : '状态读取失败';
      setStatus(null);
      setEvents(null);
      setStatusError(message);
      setSource({
        ...(fallbackSource || {
          mode: client.read ? 'live' : 'device',
          label: client.read ? '设备实时只读' : '设备实时 RPC',
          read_only: true,
        }),
        connected: false,
        fetched_at: Math.floor(Date.now() / 1000),
        duration_ms: Date.now() - started,
      });
    } finally {
      setBusy(false);
    }
  }, [client, fallbackSource]);

  useEffect(() => {
    if (!initialStatus || !initialEvents || preview) void refresh();
  }, [client, initialEvents, initialStatus, preview?.scenario, refresh]);

  const refreshConnections = useCallback(async () => {
    setConnectionsLoading(true);
    setConnectionsError(null);
    try {
      setConnections(await client.connections());
    } catch (reason) {
      setConnections({ connections: [], count: 0, truncated: false });
      setConnectionsError(reason instanceof Error ? reason.message : '设备当前连接读取失败');
    } finally {
      setConnectionsLoading(false);
    }
  }, [client]);

  useEffect(() => {
    if (view === 'events') void refreshConnections();
  }, [refreshConnections, view, preview?.scenario]);

  const refreshComponents = useCallback(async () => {
    setComponentsLoading(true);
    setComponentsError(null);
    try { setComponents(await client.components()); }
    catch (reason) { setComponentsError(reason instanceof Error ? reason.message : '组件信息读取失败'); }
    finally { setComponentsLoading(false); }
  }, [client]);

  useEffect(() => {
    if (view === 'components') void refreshComponents();
  }, [refreshComponents, view, preview?.scenario]);

  useEffect(() => {
    if (view !== 'providers' && view !== 'components') return;
    let cancelled = false;
    let timer: ReturnType<typeof setTimeout>;
    let active = false;
    const readOperations = async () => {
      try {
        const next = await client.operations();
        if (cancelled) return;
        setOperations(next);
        setOperationError(null);
        active = operationRunning(next.subscription) || operationRunning(next.packages);
      } catch (reason) {
        if (!cancelled) setOperationError(reason instanceof Error ? reason.message : '操作进度读取失败');
      }
      if (!cancelled && active) timer = setTimeout(readOperations, 1000);
    };
    void readOperations();
    return () => { cancelled = true; clearTimeout(timer); };
  }, [client, view]);

  const automaticCapability = useMemo(() => {
    const id = status?.selection?.automatic_capability_id;
    return status?.capabilities.find((capability) => capability.id === id) || null;
  }, [status]);

  const configKey = status
    ? [
      source.mode,
      source.target_label || '',
      preview?.scenario || '',
      status.runtime.backend?.id || '',
      status.providers.map((item) => item.id).join(','),
      status.regions.map((item) => item.id).join(','),
      status.capabilities.map((item) => item.id).join(','),
      deviceConfig?.revision || '',
    ].join('|')
    : '';

  useEffect(() => {
    if (!status || (configState && configState.key === configKey)) return;
    const next = createConfigDraft(status, deviceConfig || undefined);
    setConfigState({ key: configKey, draft: next, saved: next });
  }, [configKey, configState, deviceConfig, status]);

  const performAction = async () => {
    if (!dialog || !status) return;
    setBusy(true);
    setError(null);
    try {
      if (dialog === 'enable') await client.enable();
      if (dialog === 'select' && automaticCapability) await client.selectAuto(automaticCapability.id);
      if (dialog === 'disable') await client.disable();
      setDialog(null);
      await refresh();
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : '命令执行失败');
    } finally {
      setBusy(false);
    }
  };

  if (!status) {
    if (!statusError) {
      return <div className="nf-loading"><span className="nf-spinner" />正在读取 NetFleet 设备状态</div>;
    }
    return (
      <Shell
        view={view}
        onViewChange={setView}
        preview={preview}
        busy={busy}
        healthy={false}
        readOnly={source.read_only}
        canSelect={false}
        canDisable={false}
        dashboardReady={false}
        onRefresh={() => void (view === 'events' ? Promise.all([refresh(), refreshConnections()]) : refresh())}
        onSelect={() => undefined}
        onDisable={() => undefined}
        onOpenDashboard={() => undefined}
      >
        <div className="nf-page-heading"><div><h1>网络概览</h1></div></div>
        <DataSourceBar source={source} statusError={statusError} eventsError={eventsError} />
        <div className="nf-alert" role="alert"><AlertCircle aria-hidden="true" /><span>{statusError}</span></div>
      </Shell>
    );
  }

  const visibleEvents = events || { events: [] };
  const healthy = Boolean(status.runtime.mihomo_running && status.runtime.backend_enabled && status.runtime.controller_available &&
    (!status.active || (status.runtime.netfleet_present && status.runtime.lan_runtime?.transparent_proxy_ready)));
  const dashboardReady = Boolean(status.runtime.mihomo_running && status.runtime.controller_available && status.runtime.lan_runtime?.dashboard_lan_ready);
  const title = { overview: '网络概览', exits: '出口', providers: '机场', regions: '地区', config: '配置', components: '组件与更新', events: '事件与诊断' }[view];

  return (
    <Shell
      view={view}
      onViewChange={setView}
      preview={preview}
      busy={busy}
      healthy={healthy}
      readOnly={source.read_only}
      canSelect={status.actions?.can_select_auto === true}
      canDisable={status.actions?.can_disable === true}
      dashboardReady={dashboardReady}
      onRefresh={() => void (view === 'events' ? Promise.all([refresh(), refreshConnections()]) : refresh())}
      onSelect={() => setDialog('select')}
      onDisable={() => setDialog('disable')}
      onOpenDashboard={() => setError('本机参考界面只展示入口；设备版会在新标签页打开完整 Zashboard。')}
    >
      <div className="nf-page-heading">
        <div><h1>{title}</h1>{view !== 'overview' && view !== 'components' && <p>{view === 'config' ? '使用当前设备状态设计配置流程；所有更改仅用于本地预览。' : '所有状态来自同一次设备状态读取。'}</p>}</div>
        {!source.read_only && status.actions?.can_enable && (
          <button className="nf-button-primary" type="button" onClick={() => setDialog('enable')} disabled={busy}>
            <Power aria-hidden="true" />启用 NetFleet
          </button>
        )}
      </div>

      <DataSourceBar source={source} statusError={statusError} eventsError={eventsError} />

      {preview && (
        <div className="nf-mobile-preview">
          <span>{preview.label}</span><span>/</span>
          <select value={preview.scenario} onChange={(event) => preview.onScenarioChange(event.target.value)}>
            {preview.scenarios.map((scenario) => <option key={scenario.id} value={scenario.id}>{scenario.label}</option>)}
          </select>
        </div>
      )}

      {error && <div className="nf-alert" role="alert"><AlertCircle aria-hidden="true" /><span>{error}</span></div>}

      {view === 'overview' && <>
        <StatusStrip snapshot={status} />
        <OverviewExitSummary snapshot={status} onOpen={() => setView('exits')} />
        <OverviewDigest status={status} events={visibleEvents} onOpen={setView} />
      </>}

      {view === 'exits' && <>
        <div className="nf-capability-list is-detailed">
          {status.capabilities.map((capability) => <CapabilityPanel capability={capability} snapshot={status} key={capability.id} />)}
        </div>
        <PolicySummary snapshot={status} />
        <RecoverySection snapshot={status} />
      </>}
      {view === 'providers' && <><OperationProgress operation={operations.subscription} error={operationError} /><ProviderTable snapshot={status} full /></>}
      {view === 'regions' && <RegionTable snapshot={status} full />}
      {view === 'config' && configState && <ConfigView
        key={configKey}
        draft={configState.draft}
        savedDraft={configState.saved}
        status={status}
        client={client}
        onChange={(next) => setConfigState({ ...configState, draft: next })}
        onSave={(next) => setConfigState({ ...configState, draft: next, saved: next })}
      />}
      {view === 'events' && <EventsView key={`${source.mode}|${source.target_label}|${preview?.scenario}`} snapshot={visibleEvents} status={status} connections={connections} connectionsLoading={connectionsLoading} connectionsError={connectionsError} error={eventsError} client={client} />}
      {view === 'components' && <ComponentsView snapshot={components} operation={operations.packages} error={componentsError} operationError={operationError} loading={componentsLoading} onRead={() => void refreshComponents()} />}

      {dialog && <ConfirmDialog
        title={{ enable: '启用 NetFleet', select: '重新自动选优', disable: '关闭 NetFleet' }[dialog]}
        description={{
          enable: '将按当前设备策略重新生成待启用配置，并在网络检查和设备状态确认通过后接管网络出口。',
          select: '将按依赖顺序执行一轮有界测速和原子选择，并恢复后台周期选优。',
          disable: '将优先恢复设备指定的原生配置；只有原生配置无法恢复时，才停止 Nikki 并恢复网络直通。',
        }[dialog]}
        confirmLabel={{ enable: '确认启用', select: '开始选优', disable: '确认关闭' }[dialog]}
        danger={dialog === 'disable'}
        busy={busy}
        onCancel={() => setDialog(null)}
        onConfirm={() => void performAction()}
      />}
    </Shell>
  );
}
