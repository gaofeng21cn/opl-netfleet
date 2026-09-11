import { capabilityName, capabilityRoute, delay, failOpenOrder, modeName, reasonText, regionName, providerName } from '../lib/format';
import type { Capability, StatusSnapshot } from '../types';

export function CapabilityPanel({ snapshot, capability, compact = false, onChooseRegion, onSelectAuto, onOpen, active, disabled = false }: {
  snapshot: StatusSnapshot; capability: Capability; compact?: boolean; disabled?: boolean; active?: boolean;
  onChooseRegion?(): void; onSelectAuto?(): void; onOpen?(): void;
}) {
  const attached = (active ?? snapshot.active) && snapshot.runtime.netfleet_present !== false;
  const measured = attached && snapshot.runtime.controller_available !== false;
  const stopped = snapshot.runtime.mihomo_running === false;
  const direct = capability.data_path === 'direct_manual' || capability.data_path === 'direct_fallback';
  const current = !attached ? '未接管' : !measured ? '状态待确认' : direct ? '直连' : capability.data_path === 'provider_fallback' ? '机场退路' : regionName(snapshot, capability.region_id);
  const provider = !attached ? '启用后显示当前路径' : !measured ? '控制接口暂不可读' : direct ? '不经过机场' : providerName(snapshot, capability.provider_id);
  const selection = measured || ['direct', 'manual_region'].includes(capability.user_mode || '') ? modeName(capability) : capability.mode === 'automatic' ? '自动选优' : capability.mode === 'manual' ? '手动选择' : '按已保存策略';
  const reason = !measured ? '' : capability.user_mode === 'manual_region' ? `手动保持 ${regionName(snapshot, capability.manual_region_id || capability.region_id)} · 后台自动选优已暂停` : reasonText(snapshot, capability);
  const business = capability.business_routes ?? [];
  return <article className={`nf-exit-panel${compact ? ' is-compact' : ''}`}>
    <div className="nf-exit-panel-heading"><h2>{capabilityName(capability)}</h2><div className="nf-exit-actions">
      {onSelectAuto && snapshot.selection?.automation_paused && <button type="button" className="nf-button-secondary" disabled={disabled} onClick={onSelectAuto}>恢复自动选优</button>}
      {compact && disabled && onOpen ? <button type="button" className="nf-button-secondary" onClick={onOpen}>查看详情</button> : <button type="button" className="nf-button-secondary" disabled={disabled || !onChooseRegion || !capability.can_select_region} title={disabled ? '启用 NetFleet 并确认状态后可指定地区' : '指定地区并暂停后台自动选优'} onClick={onChooseRegion}>指定地区</button>}
    </div></div>
    <dl className="nf-exit-current"><div className="nf-exit-path"><dt>当前路径</dt><dd>{current}<small>{provider}</small></dd></div><div><dt>选择方式</dt><dd>{selection}</dd></div><div><dt>延迟</dt><dd>{measured && !direct ? delay(capability.reason?.delay_ms) : '未测量'}</dd></div><div><dt>健康状态</dt><dd>{measured ? direct ? capability.data_path === 'direct_manual' ? '手动直连' : '直连退路' : capability.alive ? '健康' : '不可用' : '未测量'}</dd></div></dl>
    {reason && <p className="nf-exit-reason">{reason}</p>}
    {!compact && <details className="nf-exit-details"><summary>业务范围与路径详情</summary>
      {(['capability', 'direct', 'unknown'] as const).map(kind => { const routes = business.filter(item => kind === 'unknown' ? !['capability', 'direct'].includes(item.default_route) : item.default_route === kind); return routes.length > 0 && <div className="nf-exit-business" key={kind}><strong>{kind === 'capability' ? '默认走此出口' : kind === 'direct' ? '默认直连' : '默认方式未提供'}</strong><span>{routes.map(item => item.name).join('、')}</span></div>; })}
      {!business.length && <div className="nf-exit-business"><strong>已绑定业务组</strong><span>{capability.base_groups?.join('、') || capability.base_group || '未提供'}<small>当前状态未提供各业务的默认方式。</small></span></div>}
      <dl className="nf-exit-detail-fields"><div><dt>完整节点链路</dt><dd>{measured ? capabilityRoute(snapshot, capability).join(' → ') : attached ? '当前路径暂不可读' : stopped ? '代理已停止' : '当前使用原生配置'}</dd></div><div><dt>运行时故障退路</dt><dd>{failOpenOrder(snapshot, capability).join(' → ')}</dd></div></dl>
    </details>}
  </article>;
}
