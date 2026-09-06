import { displayEventName, eventDelay, eventReason, eventResult } from '../lib/format';
import type { ConnectionsSnapshot, EventsSnapshot, NetFleetClient, StatusSnapshot } from '../types';
import { CoreMaintenance } from './CoreMaintenance';

const actionName = (action: string, trigger?: string) => action === 'select' && trigger === 'scheduled'
  ? '定期选优'
  : action === 'select' ? (trigger === 'refresh' ? '订阅更新后选优' : '手动选优') : ({ enable: '启用', refresh: '更新订阅', disable: '关闭' }[action] || action);

const initiatorName = (initiator?: string) => ({
  luci: 'LuCI',
  cli: '命令行',
  deployer: '部署流程',
  supervisor: '后台选优',
}[initiator || ''] || initiator || '未提供');

export function EventsView({ snapshot, status, connections, connectionsLoading, connectionsError, error, client }: {
  snapshot: EventsSnapshot;
  status: StatusSnapshot;
  connections: ConnectionsSnapshot;
  connectionsLoading: boolean;
  connectionsError?: string | null;
  error?: string | null;
  client?: NetFleetClient;
}) {
  const rows = snapshot.events.slice().reverse();
  return (
    <div className="nf-view-stack">
      <section className="nf-diagnostic-strip" aria-label="诊断状态">
        <dl><dt>设备控制接口</dt><dd className={status.runtime.controller_available ? 'is-ok' : 'is-warning'}>{status.runtime.controller_available ? '可读取' : '不可用'}</dd></dl>
        <dl><dt>事件存储</dt><dd className={snapshot.store_valid === false ? 'is-warning' : 'is-ok'}>{snapshot.store_valid === false ? '异常' : '有效'}</dd></dl>
        <dl><dt>决策事件</dt><dd>{snapshot.events.length} 条</dd></dl>
        <dl><dt>当前连接</dt><dd className={connectionsError ? 'is-warning' : 'is-ok'}>{connectionsLoading ? '正在读取' : connectionsError ? '读取失败' : `${connections.connections.length} 条`}</dd></dl>
        <dl><dt>原始日志</dt><dd>{snapshot.core_lines_persistent === false ? '临时窗口' : '设备保留'}</dd></dl>
      </section>
      {error && <div className="nf-inline-warning">{error}；以下内容保留上一次成功读取结果。</div>}
      <CoreMaintenance client={client} />
      <section className="nf-table-section">
        <div className="nf-section-heading"><div><h2>当前规则命中链</h2><p>{connectionsError ? connectionsError : connections.truncated ? '仅显示前 50 条活动连接。' : '由 Mihomo 返回当前实际命中结果；不会写入展示缓存。'}</p></div></div>
        <div className="nf-table-wrap"><table>
          <thead><tr><th>目标</th><th>端口</th><th>网络</th><th>命中规则 / 规则集</th><th>实际链路</th></tr></thead>
          <tbody>{connections.connections.map((connection, index) => (
            <tr key={`${connection.destination}-${connection.destination_port || ''}-${index}`}>
              <td>{connection.destination}</td><td>{connection.destination_port ?? '未提供'}</td>
              <td>{connection.network?.toUpperCase() || '未提供'}</td>
              <td>{[connection.rule, connection.rule_payload].filter(Boolean).join(' / ') || '未提供'}</td>
              <td>{connection.chains.map(item => item === 'DIRECT' ? '直连' : item).join(' → ') || '直连'}</td>
            </tr>
          ))}{!connections.connections.length && <tr><td colSpan={5}>{connectionsLoading ? '正在读取当前活动连接…' : '当前没有活动连接'}</td></tr>}</tbody>
        </table></div>
      </section>
      <section className="nf-table-section">
        <div className="nf-section-heading"><div><h2>选路事件</h2><p>只展示设备已确认完成的事件。</p></div></div>
        <div className="nf-table-wrap"><table>
          <thead><tr><th>时间</th><th>操作</th><th>来源</th><th>出口</th><th>结果</th><th>延迟</th><th>原因</th></tr></thead>
          <tbody>{rows.map((event, index) => (
            <tr key={`${event.at}-${index}`}>
              <td>{new Date(event.at * 1000).toLocaleString()}</td><td>{actionName(event.action, event.trigger)}</td>
              <td>{initiatorName(event.initiator)}</td><td>{displayEventName(snapshot, 'capabilities', event.capability)}</td>
              <td>{eventResult(snapshot, event)}</td>
              <td>{eventDelay(event)}</td><td>{eventReason(status, event)}</td>
            </tr>
          ))}</tbody>
        </table></div>
      </section>
      <section className="nf-log-section"><h2>Mihomo 原始日志</h2><pre>{(snapshot.core_lines || []).join('\n') || '暂无相关原始日志。'}</pre></section>
    </div>
  );
}
