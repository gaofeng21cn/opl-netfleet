import { ChevronRight } from 'lucide-react';
import { CapabilityPanel } from '../components/CapabilityPanel';
import { sampledAt } from './presentation';
import { displayEventName, eventResult } from '../lib/format';
import type { ViewId } from '../types';
import type { DesktopSnapshot } from './types';

export function overviewAttention(snapshot: DesktopSnapshot): string[] {
  const result: string[] = [];
  if (snapshot.network.recoveryRequired || snapshot.network.clean === false && !snapshot.runtime.running)
    result.push('网络恢复尚未确认，请查看诊断。');
  if (snapshot.runtime.mode === 'unconfirmed') result.push('当前连接状态待确认。');
  if (snapshot.runtime.lastError) result.push('上次代理操作失败，请查看诊断。');
  if (snapshot.runtime.requestedMode !== 'direct' && !snapshot.runtime.running)
    result.push('代理意外停止，请重新启动或查看诊断。');
  if (snapshot.runtime.running && !snapshot.runtime.controllerReady) result.push('核心控制接口暂不可用。');
  if (snapshot.configError) result.push('业务配置读取失败，请检查配置。');
  const exhausted = snapshot.status?.providers.filter(item => item.quota?.state === 'exhausted') ?? [];
  if (exhausted.length) result.push(`${exhausted.length} 个机场流量已耗尽。`);
  return result;
}

export function DesktopOverview({ snapshot, disabled, canSelect, onNavigate, onSelect }: {
  snapshot: DesktopSnapshot; disabled: boolean; canSelect: boolean;
  onNavigate(view: ViewId): void; onSelect(capability: string): void;
}) {
  const status = snapshot.status;
  const attention = overviewAttention(snapshot);
  const recent = snapshot.events?.events.slice().sort((a, b) => b.at - a.at).slice(0, 2) ?? [];
  return <div className="nf-desktop-overview">
    {attention.length > 0 && <section className="nf-desktop-attention" aria-label="需要处理"><div><strong>需要处理</strong><ul>{attention.map(item => <li key={item}>{item}</li>)}</ul></div><button type="button" className="nf-button-secondary" onClick={() => onNavigate('events')}>查看诊断</button></section>}
    {!snapshot.runtime.configured ? <section className="nf-desktop-onboarding"><div><h2>添加订阅，即可开始</h2><p>订阅提供节点，NetFleet 内置策略负责双出口分流。</p></div><button type="button" className="nf-button-primary" disabled={disabled} onClick={() => onNavigate('providers')}>添加订阅</button></section> : <section aria-label="业务出口">
      <div className="nf-desktop-section-title"><h2>业务出口</h2><button type="button" onClick={() => onNavigate('exits')}>全部详情<ChevronRight aria-hidden="true" /></button></div>
      <div className="nf-exit-list">{status?.capabilities.filter(item => item.enabled).map(item => <CapabilityPanel key={item.id} snapshot={status} capability={item} compact active={snapshot.runtime.running && snapshot.runtime.mode === 'netfleet' && status.active} disabled={disabled || !canSelect} onChooseRegion={() => onSelect(item.id)} onOpen={() => onNavigate('exits')} />)}</div>
    </section>}
    <nav className="nf-desktop-resource-links" aria-label="资源快捷入口">
      <button type="button" onClick={() => onNavigate('providers')}><span>机场</span><strong>{status?.providers.length ?? 0}</strong><ChevronRight aria-hidden="true" /></button>
      <button type="button" onClick={() => onNavigate('regions')}><span>已配置地区</span><strong>{status?.regions.length ?? 0}</strong><ChevronRight aria-hidden="true" /></button>
      <button type="button" onClick={() => onNavigate('config')}><span>策略与配置</span><ChevronRight aria-hidden="true" /></button>
    </nav>
    <section className="nf-desktop-recent"><div className="nf-desktop-section-title"><h2>最近决策</h2><button type="button" onClick={() => onNavigate('events')}>全部记录<ChevronRight aria-hidden="true" /></button></div>
      {recent.length ? <ul>{recent.map((item, i) => <li key={i}><time>{sampledAt(item.at)}</time><span>{item.capability && <strong>{displayEventName(snapshot.events!, 'capabilities', item.capability)} · </strong>}{eventResult(snapshot.events!, item)}</span></li>)}</ul> : <p>暂无决策记录。启用后会记录实际选路结果。</p>}
    </section>
  </div>;
}
