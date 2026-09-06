import { Download, RefreshCw } from 'lucide-react';
import type { ComponentsSnapshot, OperationSnapshot } from '../types';
import { OperationProgress } from '../components/OperationProgress';
import { componentError } from '../lib/componentError';

export function ComponentsView({ snapshot, operation, error, operationError, loading, onRead }: {
  snapshot: ComponentsSnapshot | null;
  operation: OperationSnapshot | null;
  error: string | null;
  operationError: string | null;
  loading: boolean;
  onRead(): void;
}) {
  const feed = snapshot?.feed;
  return <div className="nf-components">
    <div className="nf-section-heading"><h2>已安装组件</h2><div className="nf-components-actions">
      <button type="button" onClick={onRead} disabled={loading} title="重新读取设备组件信息"><RefreshCw aria-hidden="true" className={loading ? 'is-spinning' : ''} />重新读取</button>
      <button type="button" disabled title="本机预览只读，请在设备 LuCI 中检查更新"><Download aria-hidden="true" />检查更新</button>
    </div></div>
    <OperationProgress operation={operation} error={operationError} />
    {error && <div className="nf-alert" role="alert">{error}</div>}
    {!snapshot ? <p>{loading ? '正在读取已安装组件…' : '当前设备尚未提供组件管理信息。'}</p> : <>
      <div className="nf-table-wrap"><table><thead><tr>{['组件', '已安装版本', '运行版本', '可用版本', '状态', '操作'].map(label => <th key={label}>{label}</th>)}</tr></thead>
        <tbody>{snapshot.components.map(component => <tr key={component.id}>
          <td><strong>{component.label}</strong></td><td>{component.installed_version || '未安装'}</td><td>{component.running_version || (component.id === 'mihomo' ? '未提供' : '不适用')}</td>
          <td>{component.available_version || '尚未检查'}</td>
          <td>{component.reason ? componentError(component.reason) : component.update_available ? '可更新' : component.available_version ? '已是当前源最新版本' : '等待检查'}</td>
          <td>{component.id === 'luci' ? '随 NetFleet 更新' : <button type="button" disabled title="本机预览只读，请在设备 LuCI 中更新"><Download aria-hidden="true" />更新</button>}</td>
        </tr>)}</tbody></table></div>
      <section className="nf-components-feed"><h2>更新源</h2><dl>
        <dt>设备架构</dt><dd>{snapshot.architecture || '未提供'}</dd>
        <dt>Feed</dt><dd>{feed?.configured ? feed.url || '已配置' : '未配置'}</dd>
        <dt>最后检查</dt><dd>{feed?.checked_at ? new Date(feed.checked_at * 1000).toLocaleString() : '尚未检查'}</dd>
        <dt>更新方式</dt><dd>手动确认更新</dd>
      </dl>{feed?.error && <div className="nf-alert">{componentError(feed.error)}</div>}</section>
      <details className="nf-components-dependencies"><summary>运行依赖（{snapshot.dependencies.filter(item => item.available).length} / {snapshot.dependencies.length} 可用）</summary>
        <ul>{snapshot.dependencies.map(item => <li key={item.id}><strong>{item.label}</strong><span>{item.available ? item.installed_version || '已安装' : '缺少'}</span></li>)}</ul>
      </details>
    </>}
  </div>;
}
