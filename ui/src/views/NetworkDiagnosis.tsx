import { useState } from 'react';
import { RefreshCw, Search } from 'lucide-react';
import { diagnose, targetHost } from '../lib/diagnosis';
import { regionalDisplayName } from '../lib/format';
import type { ConnectionsSnapshot, StatusSnapshot } from '../types';

export function NetworkDiagnosis({ status, connections, loading, error, stale, refresh }: {
  status: StatusSnapshot; connections: ConnectionsSnapshot; loading: boolean; error?: string | null;
  stale?: boolean; refresh?: () => void;
}) {
  const [input, setInput] = useState('');
  const [query, setQuery] = useState('');
  const result = diagnose(status, connections, query, error, stale);
  return <section className="nf-management nf-network-diagnosis" aria-label="网站诊断">
    <div className="nf-section-heading"><h2>网站诊断</h2><button type="button" disabled={loading || !refresh} onClick={refresh}><RefreshCw aria-hidden="true" />{loading ? '正在读取' : '重新读取'}</button></div>
    <form className="nf-diagnosis-query" onSubmit={event => { event.preventDefault(); const host = targetHost(input); setQuery(host || input); if (host) setInput(host); }}>
      <label htmlFor="nf-diagnosis-target">目标网站或 IP</label><input id="nf-diagnosis-target" type="text" value={input} maxLength={2048} placeholder="example.com" onChange={event => setInput(event.target.value)} />
      <button type="submit" disabled={!input.trim() || loading}><Search aria-hidden="true" />查看链路</button>
    </form>
    <dl className="nf-diagnosis-checks">{result.checks.map(check => <div key={check.label}><dt>{check.label}</dt><dd>{check.value}</dd></div>)}</dl>
    <p className="nf-management-note">{status.active ? '当前由 NetFleet 接管。' : 'NetFleet 当前未接管，连接由现有运行配置负责。'} DNS 接入就绪不等于此网站解析成功。</p>
    <div role="status"><p>{loading ? '正在读取当前设备证据…' : result.message}</p><p>{result.next}</p></div>
    {result.host && result.matches.length > 0 && <div className="nf-table-wrap"><table><thead><tr><th>目标</th><th>协议 / 端口</th><th>实际命中规则</th><th>实际链路</th></tr></thead><tbody>{result.matches.map((item, index) => <tr key={index}>
      <td>{item.destination}</td><td>{[item.network?.toUpperCase(), item.destination_port].filter(Boolean).join(' / ') || '未记录'}</td><td>{[item.rule, item.rule_payload].filter(Boolean).join(' / ') || '未记录'}</td>
      <td>{item.chains.map(value => value === 'DIRECT' ? '直连' : regionalDisplayName(value)).join(' → ') || '未记录链路'}</td>
    </tr>)}</tbody></table></div>}
    <p className="nf-management-note">连接读取：{result.readAt ? new Date(result.readAt * 1000).toLocaleString() : '尚无读取时间'}{result.truncated ? '；快照最多包含 50 条连接，不是全部连接。' : ''}</p>
  </section>;
}
