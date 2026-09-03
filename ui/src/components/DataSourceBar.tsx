import { Clock3, Database, LockKeyhole, Signal, Wifi, WifiOff } from 'lucide-react';
import { sourceFreshness, sourceTargetLabel } from '../lib/format';
import type { DataSourceInfo } from '../types';

const time = (value?: number | null) => value
  ? new Date(value * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' })
  : '尚未读取';

export function DataSourceBar({
  source,
  statusError,
}: {
  source: DataSourceInfo;
  statusError?: string | null;
  eventsError?: string | null;
}) {
  const connected = source.connected !== false && !statusError;
  const ConnectionIcon = connected ? Wifi : WifiOff;
  const freshness = sourceFreshness(source, statusError);
  return (
    <section className={`nf-source-bar ${connected ? '' : 'is-disconnected'}`} aria-label="数据来源">
      <div className="nf-source-primary">
        <span className="nf-source-icon"><Database aria-hidden="true" /></span>
        <div><span>数据来源</span><strong>{source.label}</strong></div>
      </div>
      <div><ConnectionIcon aria-hidden="true" /><span>目标</span><strong>{sourceTargetLabel(source)}</strong></div>
      <div><Clock3 aria-hidden="true" /><span>最后读取</span><strong>{time(source.fetched_at)}</strong></div>
      <div><Signal aria-hidden="true" /><span>新鲜度</span><strong>{freshness}</strong></div>
      <div><LockKeyhole aria-hidden="true" /><span>{source.read_only ? '只读' : '设备控制'}</span><strong>{source.read_only ? '只读' : '可写入'}</strong></div>
      {source.duration_ms != null && <small>{(source.duration_ms / 1000).toFixed(1)} 秒</small>}
    </section>
  );
}
