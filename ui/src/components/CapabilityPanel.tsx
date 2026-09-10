import { ChevronRight, Globe2 } from 'lucide-react';
import { capabilityName, capabilityRoute, delay, failOpenOrder, modeName, reasonText, regionName } from '../lib/format';
import type { Capability, StatusSnapshot } from '../types';

export function CapabilityPanel({ snapshot, capability, compact = false, onChooseRegion, onSelectAuto, disabled = false }: {
  snapshot: StatusSnapshot; capability: Capability; compact?: boolean; disabled?: boolean;
  onChooseRegion?(): void; onSelectAuto?(): void;
}) {
  const route = capabilityRoute(snapshot, capability);
  const failOpen = failOpenOrder(snapshot, capability);
  return (
    <article className={`nf-capability ${capability.alive ? 'is-healthy' : 'is-unhealthy'} ${compact ? 'is-compact' : ''}`}>
      <div className="nf-capability-heading">
        <span className="nf-capability-icon"><Globe2 aria-hidden="true" /></span>
        <div><h2>{capabilityName(capability)}</h2><span>{capability.base_groups?.join('、') || capability.base_group || '未绑定'}</span></div>
      </div>
      <details className="nf-route-block"><summary>完整节点链路</summary>
        <span className="nf-field-label">当前路由链</span>
        <div className="nf-route" aria-label="当前路由链">
          {route.map((step, index) => (
            <span className="nf-route-part" key={`${step}-${index}`}>
              <span>{step}</span>{index < route.length - 1 && <ChevronRight aria-hidden="true" />}
            </span>
          ))}
        </div>
      </details>
      <dl className="nf-capability-metrics">
        <div><dt>当前延迟</dt><dd className={capability.alive ? 'is-ok' : 'is-warning'}>{delay(capability.reason?.delay_ms)}</dd></div>
        <div><dt>健康状态</dt><dd><span className={`nf-health-dot ${capability.alive ? '' : 'is-bad'}`} />{capability.alive ? '健康' : '不可用'}</dd></div>
        <div><dt>模式</dt><dd>{modeName(capability)}</dd></div>
        <div className="nf-fail-open"><dt>运行时网络退路</dt><dd>{failOpen.join(' → ') || '未编译'}</dd></div>
      </dl>
      <p className="nf-capability-reason">{capability.user_mode === 'manual_region' ? `手动保持 ${regionName(snapshot, capability.manual_region_id || capability.region_id)} · 整轮后台自动选优已暂停` : reasonText(snapshot, capability)}</p>
      {!compact && <div className="nf-region-preview"><button type="button" className="nf-button-secondary" disabled={disabled || !onChooseRegion || !capability.can_select_region} title={disabled ? '当前状态不可操作，请确认 NetFleet 已启用且状态读取正常' : onChooseRegion ? '指定地区并暂停整轮后台自动选优' : '本机参考面为只读，请在设备 LuCI 中确认切换'} onClick={onChooseRegion}>指定地区</button>
      {onSelectAuto && snapshot.selection?.automation_paused && <button type="button" className="nf-button-secondary" disabled={disabled} onClick={onSelectAuto}>恢复自动选优</button>}</div>}
    </article>
  );
}
