import { ChevronRight, Globe2, PlaneTakeoff, Settings2 } from 'lucide-react';
import { capabilityName, delay, modeName, providerName, regionName } from '../lib/format';
import type { Capability, StatusSnapshot, ViewId } from '../types';
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

function exitSummary(status: StatusSnapshot, item: Capability, measured: boolean) {
  if (!measured) {
    const mode = item.user_mode || item.mode;
    if (mode === 'direct') return ['手动直连', '启用后按直连设置运行'];
    if (mode === 'manual_region') return ['手动保持地区', '启用后沿用已设置的地区'];
    if (mode === 'native_profile') return ['等待启用', '启用 NetFleet 后按业务策略运行'];
    if (mode !== 'automatic') return [modeName(item), '启用后按已保存的策略运行'];
    return ['启动后自动选优', item.prefer_region_from ? '优先沿用合规地区，必要时独立选择' : '从可用机场与地区中自动选择'];
  }
  if (item.data_path === 'direct_manual') return ['直连', '按你的设置，不经过机场'];
  if (item.data_path === 'direct_fallback') return ['直连退路', '代理路径不可用，已回退直连'];
  if (item.data_path === 'provider_fallback') return ['机场回退', providerName(status, item.provider_id)];
  if (item.data_path === 'not_compiled') return ['尚未编译', '请在配置页检查业务策略'];
  return [regionName(status, item.region_id), providerName(status, item.provider_id)];
}

export function DesktopOverview({ snapshot, disabled, canSelect, onNavigate, onSelect }: {
  snapshot: DesktopSnapshot; disabled: boolean; canSelect: boolean;
  onNavigate(view: ViewId): void; onSelect(capability: string): void;
}) {
  const status = snapshot.status;
  const measured = Boolean(snapshot.runtime.running && snapshot.runtime.mode === 'netfleet' && status?.active);
  const capabilities = status?.capabilities.filter(item => item.enabled) ?? [];
  const attention = overviewAttention(snapshot);
  return <div className="nf-desktop-overview">
    {attention.length > 0 && <section className="nf-desktop-attention" aria-label="需要处理"><div><strong>需要处理</strong><ul>{attention.map(item => <li key={item}>{item}</li>)}</ul></div><button type="button" className="nf-button-secondary" onClick={() => onNavigate('events')}>查看诊断</button></section>}
    {!snapshot.runtime.configured ? <section className="nf-desktop-onboarding"><div><h2>{Object.keys(snapshot.subscriptions).length ? '完成订阅准备' : '添加订阅，即可开始'}</h2><p>自动生成海外加速与 AI 双出口，随后可启动代理。</p></div><button type="button" className="nf-button-primary" disabled={disabled} onClick={() => onNavigate('providers')}>管理订阅</button></section> : <section aria-label="业务出口">
      <div className="nf-desktop-section-title"><h2>业务出口</h2><button type="button" onClick={() => onNavigate('exits')}>查看详情<ChevronRight aria-hidden="true" /></button></div>
      <div className="nf-desktop-exit-grid">{capabilities.map(item => { const [title, detail] = exitSummary(status!, item, measured); return <article className="nf-desktop-exit-card" key={item.id}>
        <div className="nf-desktop-exit-title"><h3>{capabilityName(item)}</h3><span>{measured ? item.data_path.startsWith('direct_') ? '直连' : item.alive ? delay(item.reason?.delay_ms) : '不可用' : snapshot.runtime.running ? '未接管' : '未运行'}</span></div>
        <strong className="nf-desktop-exit-region">{title}</strong>
        <p>{detail}</p>
        <div className="nf-desktop-exit-foot"><span>{measured ? modeName(item) : '配置已就绪'}</span><button type="button" className="nf-button-secondary" disabled={disabled} onClick={() => canSelect ? onSelect(item.id) : onNavigate('exits')}>{canSelect ? '选择地区' : '查看出口'}</button></div>
      </article>; })}</div>
      {!capabilities.length && <p className="nf-empty">尚未读取业务出口。<button type="button" onClick={() => onNavigate('config')}>检查配置</button></p>}
    </section>}
    <nav className="nf-desktop-resource-links" aria-label="资源快捷入口">
      <button type="button" onClick={() => onNavigate('providers')}><PlaneTakeoff aria-hidden="true" /><span>机场订阅</span><strong>{Object.values(snapshot.subscriptions).filter(item => item.enabled).length}</strong><ChevronRight aria-hidden="true" /></button>
      <button type="button" onClick={() => onNavigate('regions')}><Globe2 aria-hidden="true" /><span>已配置地区</span><strong>{status?.regions.length ?? 0}</strong><ChevronRight aria-hidden="true" /></button>
      <button type="button" onClick={() => onNavigate('events')}><Settings2 aria-hidden="true" /><span>诊断与记录</span><ChevronRight aria-hidden="true" /></button>
    </nav>
  </div>;
}
