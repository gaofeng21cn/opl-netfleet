import { Download, ExternalLink, RefreshCw, Settings } from 'lucide-react';
import { useState } from 'react';
import { CompatibilityView } from './CompatibilityView';
import type { ComponentsSnapshot, DashboardComponent, ExtensionComponent, OperationSnapshot } from '../types';
import { OperationProgress } from '../components/OperationProgress';
import { componentError } from '../lib/componentError';
import { ResultNotice, resultTime } from '../components/ResultNotice';

const previewReason = '本机预览只读，请在设备 LuCI 中操作';
const coreVersion = (value: string) => value.replace(/^v/, '').replace(/-r\d+$/, '');
const checkedTime = (value: number | null, failed?: string | null) => value ? `检查于 ${new Date(value * 1000).toLocaleString()}` : failed ? '检查时间未记录' : '尚未检查更新';

function ExtensionRow({ extension, onManage }: { extension: ExtensionComponent; onManage(): void }) {
  const state = { ready: '可配置', not_installed: '未安装', incompatible: '模块版本不兼容', backend_unsupported: '当前后端不支持', dependency_missing: '缺少依赖', unknown: '状态未确认' }[extension.state];
  const absent = extension.state === 'not_installed' && !extension.available;
  const missing = extension.dependencies.filter(dependency => dependency.available === false);
  const warning = extension.state !== 'ready' && extension.state !== 'not_installed';
  return <tr>
    <td><strong>{extension.label}</strong><small title={extension.package}>可选模块</small></td>
    <td><strong>{extension.installed_version || (absent ? '未安装' : '安装版本未确认')}</strong>
      {extension.state !== 'not_installed' && <small className={warning ? 'is-warning' : ''}>{state}</small>}
      {extension.reason && <small>{componentError(extension.reason)}</small>}
      {!absent && extension.dependencies.length > 0 && <details open={missing.length > 0 || undefined}>
        <summary className={missing.length ? 'is-warning' : ''}>{missing.length ? `缺少 ${missing.length} 项模块依赖` : `运行依赖（${extension.dependencies.length}）`}</summary>
        <small style={{ overflowWrap: 'anywhere' }}>{extension.package}</small>
        {extension.dependencies.map(dependency => <small key={dependency.id} className={dependency.available === false ? 'is-warning' : ''}>
          {dependency.id}：{dependency.available === null ? '未确认' : dependency.available ? dependency.installed_version || '已安装' : '缺少'}
        </small>)}
      </details>}
    </td>
    <td>通过 OpenWrt 软件包管理</td>
    <td className="nf-component-actions">{extension.id === 'https-compat' && <button type="button" onClick={onManage}><Settings aria-hidden="true" />管理</button>}</td>
  </tr>;
}

function DashboardRow({ dashboard }: { dashboard: DashboardComponent }) {
  return <tr>
    <td><strong>Zashboard</strong><small>实时运行面板</small></td>
    <td><strong>{dashboard.available ? '已安装，可使用' : '未安装'}</strong>
      {dashboard.available && <small>{dashboard.installed_version || '版本未记录'}</small>}
      {!dashboard.managed && <small>{componentError(dashboard.reason || 'dashboard_managed_externally')}</small>}
    </td>
    <td>{dashboard.available_version && !dashboard.error ? dashboard.update_available ? `候选版本 ${dashboard.available_version}` : '当前更新源暂无新版' : null}</td>
    <td className="nf-component-actions">
      {dashboard.available && <button type="button" disabled title={previewReason}><ExternalLink aria-hidden="true" />打开面板</button>}
      {dashboard.managed && dashboard.update_available && dashboard.available_version && !dashboard.error && <button type="button" disabled title={previewReason}><Download aria-hidden="true" />{dashboard.available ? '更新面板' : '安装面板'}</button>}
    </td>
  </tr>;
}

export function ComponentsView({ snapshot, operation, error, operationError, loading, onRead, scope = '' }: {
  scope?: string;
  snapshot: ComponentsSnapshot | null;
  operation: OperationSnapshot | null;
  error: string | null;
  operationError: string | null;
  loading: boolean;
  onRead(): void;
}) {
  const [detail, setDetail] = useState<string | null>(null);
  if (detail === 'https-compat') return <CompatibilityView extension={snapshot?.extensions?.find(item => item.id === detail)} onBack={() => setDetail(null)} />;
  const feed = snapshot?.feed;
  const dashboard = snapshot?.dashboard;
  const luci = snapshot?.components.find(component => component.id === 'luci');
  const missing = snapshot?.dependencies.filter(item => !item.available) || [];
  const packageFailed = operation && ['failed', 'interrupted'].includes(operation.state);
  const sameFeedFailure = packageFailed && operation.error === feed?.error && (!feed?.checked_at || feed.checked_at >= operation.started_at && feed.checked_at <= (operation.finished_at || 0));
  return <div className="nf-components">
    <div className="nf-section-heading"><h2>已安装组件</h2><div className="nf-components-actions">
      <button type="button" onClick={onRead} disabled={loading} title="刷新设备组件状态" aria-label="刷新设备组件状态"><RefreshCw aria-hidden="true" className={loading ? 'is-spinning' : ''} /></button>
      <button type="button" disabled title={previewReason}><RefreshCw aria-hidden="true" />检查更新</button>
    </div></div>
    <OperationProgress operation={operation} error={operationError} scope={scope} />
    {error && <div className="nf-alert" role="alert">{error}</div>}
    {!snapshot ? <p>{loading ? '正在读取已安装组件…' : '当前设备尚未提供组件管理信息。'}</p> : <>
      {feed?.error && !sameFeedFailure && (!operation || !['running', 'queued'].includes(operation.state)) && <ResultNotice scope={scope} slot="feed" identity={String(feed.checked_at || 0)} title="软件包源检查" warning>
        <span>{componentError(feed.error)}</span><span>{resultTime(feed.checked_at, '检查于') || '检查时间未记录'}</span>
      </ResultNotice>}
      {dashboard?.managed && dashboard.error && <ResultNotice scope={scope} slot="dashboard" identity={String(dashboard.checked_at || 0)} title="面板检查" warning>
        <span>{componentError(dashboard.error)}</span><span>{resultTime(dashboard.checked_at, '检查于') || '检查时间未记录'}</span>
      </ResultNotice>}
      <div className="nf-component-checks" role="status">
        <span>{!snapshot.supported ? '软件包：当前安装方式不支持包管理' : !feed?.configured ? '软件包：未配置更新源' : `软件包：${feed.error ? '上次检查失败 · ' : ''}${checkedTime(feed.checked_at, feed.error)}`}</span>
        {dashboard && <span>{!dashboard.managed ? componentError(dashboard.reason || 'dashboard_managed_externally') : `面板：${dashboard.error ? '上次检查失败 · ' : ''}${checkedTime(dashboard.checked_at, dashboard.error)}`}</span>}
      </div>
      <div className="nf-table-wrap"><table><thead><tr>{['组件', '当前版本与状态', '更新', '操作'].map(label => <th key={label}>{label}</th>)}</tr></thead>
        <tbody>{snapshot.components.filter(component => component.id !== 'luci').map(component => {
          const mismatch = component.id === 'mihomo' && component.installed_version && component.running_version && coreVersion(component.installed_version) !== coreVersion(component.running_version);
          const pairMismatch = component.id === 'netfleet' && luci && luci.installed_version !== component.installed_version;
          const hasUpdate = component.update_available || component.id === 'netfleet' && luci?.update_available && luci.available_version === component.available_version;
          const canUpdate = snapshot.supported && feed?.configured && !feed.error && component.managed && hasUpdate && component.available_version;
          return <tr key={component.id}>
            <td><strong>{component.label}</strong><small>{component.id === 'netfleet' ? '包含 LuCI 管理界面' : '代理核心'}</small></td>
            <td><strong>{component.id === 'mihomo' ? component.running_version || '核心运行版本暂不可读取' : component.installed_version || '未安装'}</strong>
              {component.id === 'mihomo' && component.installed_version && <small>安装记录 {component.installed_version}</small>}
              {mismatch && <span className="is-warning">运行版本与安装记录不一致</span>}
              {pairMismatch && <span className="is-warning">NetFleet 与 LuCI 安装版本不一致</span>}
              {component.reason && <small>{componentError(component.reason)}</small>}
            </td>
            <td>{component.available_version && !feed?.error ? hasUpdate ? `候选版本 ${component.available_version}` : '当前更新源暂无新版' : null}</td>
            <td className="nf-component-actions">{canUpdate && <button type="button" disabled title={previewReason}><Download aria-hidden="true" />{mismatch ? '更新软件包' : '更新'}</button>}</td>
          </tr>;
        })}{snapshot.extensions?.filter(extension => extension.kind === 'optional').map(extension => <ExtensionRow key={extension.id} extension={extension} onManage={() => setDetail(extension.id)} />)}{dashboard && <DashboardRow dashboard={dashboard} />}</tbody></table></div>
      <details className="nf-component-details"><summary>技术详情：更新源与安装信息</summary>
        {feed?.error && <p>软件包源最近错误：{componentError(feed.error)}</p>}
        {packageFailed && <p>最近组件操作：{componentError(operation.error || 'component_operation_failed')}{operation.recovery && `；${{ restored: '已恢复更新前状态', failed: '恢复失败', direct: '已恢复网络直通' }[operation.recovery]}`}</p>}
        {dashboard?.error && <p>面板最近错误：{componentError(dashboard.error)}</p>}
        <dl>
        {snapshot.architecture && <><dt>设备架构</dt><dd>{snapshot.architecture}</dd></>}
        {feed?.url && <><dt>软件包源</dt><dd>{feed.url}</dd></>}
        {luci && <><dt>LuCI 界面</dt><dd>{luci.installed_version || '未安装'} · 随 NetFleet 更新</dd></>}
        {dashboard?.release_url?.startsWith('https://github.com/') && <><dt>面板发行说明</dt><dd><a href={dashboard.release_url} target="_blank" rel="noopener noreferrer">Zashboard 发行说明<ExternalLink aria-hidden="true" /></a></dd></>}
      </dl></details>
      {snapshot.supported && snapshot.dependencies.length > 0 && <details className="nf-component-details nf-components-dependencies" open={missing.length > 0 || undefined}><summary className={missing.length ? 'is-warning' : ''}>{missing.length ? `缺少 ${missing.length} 项运行依赖` : '运行依赖正常'}</summary>
        {missing.length > 0 && <p>请通过 OpenWrt 软件包管理安装缺少的依赖。</p>}
        <ul>{snapshot.dependencies.map(item => <li key={item.id}><strong>{item.label}</strong><span className={item.available ? '' : 'is-warning'}>{item.available ? item.installed_version || '已安装' : '缺少'}</span></li>)}</ul>
      </details>}
    </>}
  </div>;
}
