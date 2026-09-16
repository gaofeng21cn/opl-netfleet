import { ChevronRight } from 'lucide-react';
import { CapabilityPanel, exitMeasurementState } from '../components/CapabilityPanel';
import { OverviewDigest } from '../components/OverviewDigest';
import type { EventsSnapshot } from '../types';
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
  const events: EventsSnapshot = snapshot.events ?? { events: [] };
  const capabilities = status?.capabilities.filter(item => item.enabled) ?? [];
  const attached = Boolean(status && snapshot.runtime.running && snapshot.runtime.mode === 'netfleet' && status.active);
  const exits = status ? exitMeasurementState(status, attached) : null;
  return <div className="nf-desktop-overview">
    {attention.length > 0 && <section className="nf-desktop-attention" aria-label="需要处理"><div><strong>需要处理</strong><ul>{attention.map(item => <li key={item}>{item}</li>)}</ul></div><button type="button" className="nf-button-secondary" onClick={() => onNavigate('events')}>查看诊断</button></section>}
    {!snapshot.runtime.configured ? <section className="nf-desktop-onboarding"><div><h2>添加订阅，即可开始</h2><p>订阅提供节点，NetFleet 内置策略负责双出口分流。</p></div><button type="button" className="nf-button-primary" disabled={disabled} onClick={() => onNavigate('providers')}>添加订阅</button></section> : <>
      <section className="nf-desktop-exits" aria-labelledby="nf-desktop-exits-title">
        <div className="nf-desktop-section-title">
          <div><h2 id="nf-desktop-exits-title">出口态势</h2><p>当前路径、选择方式与本轮测量</p></div>
          <button type="button" onClick={() => onNavigate('exits')}>全部详情<ChevronRight aria-hidden="true" /></button>
        </div>
        <div className="nf-exit-list">
          <div className="nf-exit-list-head" aria-hidden="true"><span>出口</span><span>当前路径</span><span>选择方式</span>{exits?.measured ? <><span>延迟</span><span>健康状态</span></> : <span className="nf-exit-list-measure-head">本轮测量</span>}<span /></div>
          {status && capabilities.map(item => <CapabilityPanel key={item.id} snapshot={status} capability={item} compact active={attached} disabled={disabled || !canSelect} onChooseRegion={() => onSelect(item.id)} onOpen={() => onNavigate('exits')} />)}
        </div>
        {status && !capabilities.length && <p className="nf-empty">暂无启用的业务出口。添加订阅并完成准备后显示。</p>}
      </section>
      {status && <OverviewDigest platform="desktop" status={status} events={events} showAttention={false} showMeasurementNote={false} measured={exits?.measured} onOpen={target => onNavigate(target)} />}
    </>}
  </div>;
}
