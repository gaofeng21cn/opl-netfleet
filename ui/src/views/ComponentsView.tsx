import { Download, ExternalLink, RefreshCw, Settings } from 'lucide-react';
import { useState } from 'react';
import { CompatibilityView } from './CompatibilityView';
import type { ComponentsSnapshot, DashboardComponent, ExtensionComponent, PluginComponent, OperationSnapshot } from '../types';
import { OperationProgress } from '../components/OperationProgress';
import { componentError } from '../lib/componentError';
import { ResultNotice, resultTime } from '../components/ResultNotice';
import { displayVersion } from '../lib/version';

const previewReason = '本机预览只读，请在设备 LuCI 中操作';
const coreVersion = (value: string) => value.replace(/^v/, '').replace(/-r\d+$/, '');
const checkedTime = (value: number | null, failed?: string | null) => value ? `检查于 ${new Date(value * 1000).toLocaleString()}` : failed ? '检查时间未记录' : '尚未检查更新';
const pluginPurposes: Record<string, string> = {
  'device-identity': '识别网络设备，为按设备配置规则提供稳定身份',
  activation: '切换运行模式，应用或退出代理接管',
  compilation: '根据策略与节点来源生成代理运行配置',
  components: '检查并更新基础软件与面板资源',
  configuration: '读取、校验和保存出口与选路策略',
  dashboard: '提供实时面板入口与资源更新',
  events: '记录设备操作进度和选路事件',
  'https-compat': '为指定设备和网站提供 HTTPS 协议兼容',
  maintenance: '管理配置文件、备份与核心维护',
  mihomo: '连接代理核心并管理其运行配置',
  models: '提供机场、地区与出口的结构化配置',
  network: '管理设备代理、DNS 与监听设置',
  platform: '提供设备进程与运行环境能力',
  'platform-openwrt': '接入系统配置与设备信息',
  'platform-storage': '读写配置文档与设备文件',
  'product-ui': '提供概览、出口与配置等页面的内容和交互；由 LuCI 接入组件加载',
  recovery: '在退出或异常时恢复网络直连',
  refresh: '更新订阅并准备最新节点',
  scheduler: '按计划执行订阅更新与自动选优',
  selection: '为各出口测速并选择可用路径',
  'selection-algorithm': '按策略比较地区与候选路径',
  setup: '准备运行基础并接入已有设置',
  status: '汇总当前出口、机场与设备运行状态',
  subscriptions: '管理机场订阅与节点缓存',
};

function PluginRow({ plugin, product }: { plugin: PluginComponent; product?: ComponentsSnapshot['product'] }) {
  const version = plugin.installed_version || plugin.version;
  const unavailable = Boolean(plugin.reason) || ['unavailable', 'invalid'].includes(plugin.state);
  return <tr>
    <td><strong>{plugin.label || plugin.id}</strong><small>{plugin.id}</small>{plugin.instance && plugin.instance !== 'default' && <small>实例：{plugin.instance}</small>}</td>
    <td><span>{product ? product.packages.some(item => item.name === plugin.package) ? '默认产品能力' : '独立安装的插件' : plugin.runtime === 'service' ? '服务插件' : '进程插件'}</span><small>{plugin.description || pluginPurposes[plugin.id] || `为 NetFleet 提供 ${plugin.label || plugin.id} ${plugin.runtime === 'service' ? '服务' : '功能'}`}</small></td>
    <td><strong>{displayVersion(version)}</strong><details><summary>版本详情</summary><small>{version}</small><small>{plugin.package}</small></details></td>
    <td className="nf-component-actions">{plugin.ui?.length ? plugin.ui.map(page => <button key={page.id} type="button" disabled title={previewReason}>{plugin.ui.length === 1 ? plugin.configuration ? '配置' : '打开页面' : page.title}</button>) : <small>无需单独配置</small>}</td>
    <td className="nf-component-actions">
      <span>{typeof plugin.enabled !== 'boolean' ? '状态未确认' : plugin.enabled === false ? '已禁用' : unavailable ? '已启用 · 异常' : '已启用'}</span>
      {typeof plugin.enabled !== 'boolean' && <small>请打开“查看状态”确认后操作</small>}
      {plugin.reason && plugin.reason !== 'plugin_disabled' && <small className="is-warning">{componentError(plugin.reason)}</small>}
      {plugin.revision && <button type="button" disabled title={previewReason}>查看状态</button>}
      {plugin.revision && typeof plugin.enabled === 'boolean' && <button type="button" disabled title={plugin.enabled && ['product-ui', 'components', 'status', 'events', 'setup'].includes(plugin.id) ? '不可禁用：管理界面必需' : previewReason}>{plugin.enabled ? '禁用' : '启用'}</button>}
      {['product-ui', 'components', 'status', 'events', 'setup'].includes(plugin.id) && <small>不可禁用：管理界面必需</small>}
    </td>
  </tr>;
}

function ExtensionRow({ extension, onManage }: { extension: ExtensionComponent; onManage(): void }) {
  const state = { ready: '可配置', not_installed: '未安装', incompatible: '模块版本不兼容', backend_unsupported: '当前后端不支持', dependency_missing: '缺少依赖', unknown: '状态未确认' }[extension.state];
  const absent = extension.state === 'not_installed' && !extension.available;
  const missing = extension.dependencies.filter(dependency => dependency.available === false);
  const warning = extension.state !== 'ready' && extension.state !== 'not_installed';
  return <tr>
    <td><strong>{extension.label}</strong><small>{extension.id}</small></td>
    <td><span>可选模块</span><small>{extension.id === 'https-compat' ? '为指定设备和网站提供 HTTPS 协议兼容' : '提供 ' + extension.label + ' 功能'}</small></td>
    <td><strong>{extension.installed_version ? displayVersion(extension.installed_version) : absent ? '未安装' : '安装版本未确认'}</strong>
      {extension.installed_version && <details><summary>版本详情</summary><small>{extension.installed_version}</small><small>{extension.package}</small></details>}</td>
    <td className="nf-component-actions">{extension.id === 'https-compat' ? <button type="button" onClick={onManage}><Settings aria-hidden="true" />配置</button> : <small>由对应功能插件配置</small>}</td>
    <td>
      {extension.state !== 'not_installed' && <small className={warning ? 'is-warning' : ''}>{state}</small>}
      {extension.reason && <small>{componentError(extension.reason)}</small>}
      {!absent && extension.dependencies.length > 0 && <details open={missing.length > 0 || undefined}>
        <summary className={missing.length ? 'is-warning' : ''}>{missing.length ? `缺少 ${missing.length} 项模块依赖` : `运行依赖（${extension.dependencies.length}）`}</summary>
        <small style={{ overflowWrap: 'anywhere' }}>{extension.package}</small>
        {extension.dependencies.map(dependency => <small key={dependency.id} className={dependency.available === false ? 'is-warning' : ''}>
          {dependency.id}：{dependency.available === null ? '未确认' : dependency.available ? dependency.installed_version ? displayVersion(dependency.installed_version) : '已安装' : '缺少'}
        </small>)}
      </details>}
    </td>
  </tr>;
}

function PluginPackages({ snapshot }: { snapshot: ComponentsSnapshot }) {
  return <section className="nf-component-modules"><h3>安装与维护独立插件</h3>
    <p>从设备已信任的软件源读取。默认功能插件也可独立更新，必需插件不可单独卸载；HTTPS 引擎由 HTTPS 插件中的独立更新入口管理。</p>
    <button type="button" disabled title={previewReason}>检查插件更新</button>
    {snapshot.plugin_packages?.length ? <div className="nf-table-wrap"><table><thead><tr><th>插件</th><th>安装与候选版本</th><th>软件包操作</th></tr></thead><tbody>
      {snapshot.plugin_packages.map(item => <tr key={item.name}><td><strong>{item.id}</strong><small>{item.description || pluginPurposes[item.id]}</small><small>{item.name}</small></td>
        <td><strong>{item.installed_version ? displayVersion(item.installed_version) : '未安装'}</strong><small>{item.available_version ? '更新源版本 ' + displayVersion(item.available_version) : '检查更新以读取候选版本'}</small></td>
        <td className="nf-component-actions">{!item.installed_version && item.available_version && <button disabled title={previewReason}>安装</button>}{item.update_available && <button disabled title={previewReason}>更新</button>}{item.installed_version && !item.required && <button disabled title={previewReason}>卸载</button>}</td></tr>)}
    </tbody></table></div> : <p>检查更新后显示软件源中的独立插件。</p>}
  </section>;
}

function DashboardRow({ dashboard }: { dashboard: DashboardComponent }) {
  return <tr>
    <td><strong>Zashboard</strong><small>查看实时连接、流量与代理组</small></td>
    <td><strong>{dashboard.available ? dashboard.installed_version ? displayVersion(dashboard.installed_version) : '版本未记录' : '未安装'}</strong>
      {dashboard.available && <small>已安装，可使用</small>}
      {!dashboard.managed && <small>{componentError(dashboard.reason || 'dashboard_managed_externally')}</small>}
    </td>
    <td className="nf-component-actions">
      <div>{dashboard.available_version && !dashboard.error ? dashboard.update_available ? `候选版本 ${displayVersion(dashboard.available_version)}` : '当前更新源暂无新版' : null}</div>
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
  const [section, setSection] = useState('software');
  const [detail, setDetail] = useState<string | null>(null);
  if (detail === 'https-compat') return <CompatibilityView extension={snapshot?.extensions?.find((item): item is ExtensionComponent => item.kind === 'optional' && item.id === detail)} onBack={() => setDetail(null)} />;
  const feed = snapshot?.feed;
  const dashboard = snapshot?.dashboard;
  const luci = snapshot?.components.find(component => component.id === 'luci');
  const missing = snapshot?.dependencies.filter(item => !item.available) || [];
  const packageFailed = operation && ['failed', 'interrupted'].includes(operation.state);
  const sameFeedFailure = packageFailed && operation.error === feed?.error && (!feed?.checked_at || feed.checked_at >= operation.started_at && feed.checked_at <= (operation.finished_at || 0));
  return <div className="nf-components">
    <nav className="nf-subtabs" aria-label="插件与更新分类">{[['software', '基础组件'], ['plugins', '功能插件']].map(([id, label]) => <button type="button" key={id} aria-current={section === id ? 'page' : undefined} onClick={() => setSection(id)}>{label}</button>)}</nav>
    <div className="nf-section-heading"><h2>{section === 'software' ? '版本与更新' : '插件目录'}</h2><div className="nf-components-actions">
      <button type="button" onClick={onRead} disabled={loading} title="刷新设备组件状态" aria-label="刷新设备组件状态"><RefreshCw aria-hidden="true" className={loading ? 'is-spinning' : ''} /></button>
      {section === 'software' ? <button type="button" disabled title={previewReason}><RefreshCw aria-hidden="true" />检查更新</button> : <button type="button" disabled title={previewReason}><ExternalLink aria-hidden="true" />软件包管理</button>}
    </div></div>
    {section === 'software' && <OperationProgress operation={operation} error={operationError} scope={scope} />}
    {error && <div className="nf-alert" role="alert">{error}</div>}
    {!snapshot ? <p>{loading ? '正在读取已安装组件…' : '当前设备尚未提供组件管理信息。'}</p> : <>
      {section === 'software' && feed?.error && !sameFeedFailure && (!operation || !['running', 'queued'].includes(operation.state)) && <ResultNotice scope={scope} slot="feed" identity={String(feed.checked_at || 0)} title="软件包源检查" warning>
        <span>{componentError(feed.error)}</span><span>{resultTime(feed.checked_at, '检查于') || '检查时间未记录'}</span>
      </ResultNotice>}
      {section === 'software' && dashboard?.managed && dashboard.error && <ResultNotice scope={scope} slot="dashboard" identity={String(dashboard.checked_at || 0)} title="面板检查" warning>
        <span>{componentError(dashboard.error)}</span><span>{resultTime(dashboard.checked_at, '检查于') || '检查时间未记录'}</span>
      </ResultNotice>}
      {section === 'software' && snapshot.product && <details className="nf-component-details" open={snapshot.product.missing.length > 0 || undefined}>
        <summary>{snapshot.product.missing.length ? `默认产品缺少 ${snapshot.product.missing.length} 个软件包` : '默认产品软件包齐全'}</summary>
        <p>此处核对安装组成；网络是否正常请查看概览，插件是否启用请查看功能插件。{snapshot.product.updates.length > 0 && `更新源有 ${snapshot.product.updates.length} 个产品包可更新。`}</p>
        {snapshot.product.missing.length > 0 && <p>请通过软件包管理重新安装 NetFleet 默认产品以补齐依赖。</p>}
        <ul>{snapshot.product.packages.map(item => <li key={item.name}><strong>{item.name}</strong> {item.installed_version || '未安装'}{snapshot.product?.updates.includes(item.name) && <small>可更新至 {item.available_version}</small>}</li>)}</ul>
      </details>}
      <div className="nf-table-wrap nf-software-table" hidden={section !== 'software'}><table><thead><tr>{['软件', '当前版本', '更新与操作'].map(label => <th key={label}>{label}</th>)}</tr></thead>
        <tbody>{snapshot.components.map(component => {
          const mismatch = component.id === 'mihomo' && component.installed_version && component.running_version && coreVersion(component.installed_version) !== coreVersion(component.running_version);
          const hasUpdate = component.update_available || component.id === 'netfleet' && luci?.update_available;
          const uiOnly = component.id === 'netfleet' && !component.update_available && luci?.update_available;
          const canUpdate = component.id !== 'luci' && snapshot.supported && feed?.configured && !feed.error && component.managed && hasUpdate && component.available_version;
          return <tr key={component.id}>
            <td><strong>{component.id === 'luci' ? 'LuCI 接入组件' : component.label}</strong><small>{component.id === 'netfleet' ? '管理运行策略、出口选优与网络恢复' : component.id === 'luci' ? '提供 LuCI 菜单、权限与插件页面加载；业务页面由 product-ui 提供' : '执行代理连接与流量转发'}</small></td>
            <td><strong>{component.id === 'mihomo' ? component.running_version ? displayVersion(component.running_version) : '核心运行版本暂不可读取' : component.installed_version ? displayVersion(component.installed_version) : '未安装'}</strong>
              {component.id === 'mihomo' && component.installed_version && <small>安装记录 {displayVersion(component.installed_version)}</small>}
              {mismatch && <span className="is-warning">运行版本与安装记录不一致</span>}
              {component.reason && <small>{componentError(component.reason)}</small>}
              <details><summary>版本详情</summary><small>完整包版本：{component.installed_version || '未安装'}</small>{component.running_version && <small>运行版本：{component.running_version}</small>}{component.available_version && <small>候选包版本：{component.available_version}</small>}</details>
            </td>
            <td className="nf-component-actions"><div>{component.available_version && !feed?.error ? hasUpdate ? <>{uiOnly ? `界面可更新至 ${displayVersion(luci.available_version)}` : `候选版本 ${displayVersion(component.available_version)}`}{component.id !== 'luci' && <small>{component.id === 'mihomo' ? '更新核心会中断已有代理连接' : '基础包更新会停止并恢复服务，私有配置保留'}</small>}</> : '当前更新源暂无新版' : null}</div>
              {component.id === 'luci' ? <small>由 NetFleet 更新入口管理</small> : canUpdate && <button type="button" disabled title={previewReason}><Download aria-hidden="true" />{mismatch ? '更新软件包' : uiOnly ? '更新界面' : '更新'}</button>}</td>
          </tr>;
        })}{dashboard && <DashboardRow dashboard={dashboard} />}</tbody></table></div>
      {section === 'software' && <div className="nf-component-checks" role="status">
        <span>{!snapshot.supported ? '软件包：当前安装方式不支持包管理' : !feed?.configured ? '软件包：未配置更新源' : `软件包：${feed.error ? '上次检查失败 · ' : ''}${checkedTime(feed.checked_at, feed.error)}`}</span>
        {dashboard && <span>{!dashboard.managed ? componentError(dashboard.reason || 'dashboard_managed_externally') : `面板：${dashboard.error ? '上次检查失败 · ' : ''}${checkedTime(dashboard.checked_at, dashboard.error)}`}</span>}
      </div>}
      <section className="nf-component-modules" hidden={section !== 'plugins'}>
        <p>启用表示允许使用；禁用保留软件与配置。安装、更新和卸载独立插件请使用下方的软件包管理。</p>
        {snapshot.extensions?.some(extension => extension.kind !== 'resource') ? <div className="nf-table-wrap nf-plugin-table"><table><thead><tr>{['插件', '分类与用途', '版本', '配置', '运行管理'].map(label => <th key={label}>{label}</th>)}</tr></thead><tbody>
          {snapshot.extensions.filter(extension => extension.kind !== 'resource').map(extension => extension.kind === 'plugin' ? <PluginRow key={`${extension.id}:${extension.instance || 'default'}`} plugin={extension} product={snapshot.product} /> : <ExtensionRow key={extension.id} extension={extension} onManage={() => setDetail(extension.id)} />)}
        </tbody></table></div> : <p>当前没有可管理的功能插件</p>}
        <PluginPackages snapshot={snapshot} />
      </section>
      <details className="nf-component-details" hidden={section !== 'software'}><summary>技术详情：更新源与安装信息</summary>
        {feed?.error && <p>软件包源最近错误：{componentError(feed.error)}</p>}
        {packageFailed && <p>最近组件操作：{componentError(operation.error || 'component_operation_failed')}{operation.recovery && `；${{ restored: '已恢复更新前状态', native: '已恢复 Mihomo 原生代理', unchanged: '已确认保持原运行模式', failed: '恢复失败', direct: '已恢复网络直通' }[operation.recovery]}`}</p>}
        {dashboard?.error && <p>面板最近错误：{componentError(dashboard.error)}</p>}
        <dl>
        {snapshot.architecture && <><dt>设备架构</dt><dd>{snapshot.architecture}</dd></>}
        {feed?.url && <><dt>软件包源</dt><dd>{feed.url}</dd></>}
        {dashboard?.release_url?.startsWith('https://github.com/') && <><dt>面板发行说明</dt><dd><a href={dashboard.release_url} target="_blank" rel="noopener noreferrer">Zashboard 发行说明<ExternalLink aria-hidden="true" /></a></dd></>}
      </dl></details>
      {snapshot.supported && snapshot.dependencies.length > 0 && <details className="nf-component-details nf-components-dependencies" hidden={section !== 'software'} open={missing.length > 0 || undefined}><summary className={missing.length ? 'is-warning' : ''}>{missing.length ? `缺少 ${missing.length} 项运行依赖` : '运行依赖正常'}</summary>
        {missing.length > 0 && <p>请通过 OpenWrt 软件包管理安装缺少的依赖。</p>}
        <ul>{snapshot.dependencies.map(item => <li key={item.id}><strong>{item.label}</strong><span className={item.available ? '' : 'is-warning'}>{item.available ? item.installed_version ? displayVersion(item.installed_version) : '已安装' : '缺少'}</span></li>)}</ul>
      </details>}
    </>}
  </div>;
}
