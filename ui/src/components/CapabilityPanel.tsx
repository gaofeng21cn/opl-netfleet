import { ChevronRight, Globe2 } from 'lucide-react';
import { capabilityName, capabilityRoute, delay, failOpenOrder, modeName, reasonText, regionName } from '../lib/format';
import type { Capability, StatusSnapshot } from '../types';

export function CapabilityPanel({ snapshot, capability, compact = false }: { snapshot: StatusSnapshot; capability: Capability; compact?: boolean }) {
  const route = capabilityRoute(snapshot, capability);
  const failOpen = failOpenOrder(snapshot, capability);
  return (
    <article className={`nf-capability ${capability.alive ? 'is-healthy' : 'is-unhealthy'} ${compact ? 'is-compact' : ''}`}>
      <div className="nf-capability-heading">
        <span className="nf-capability-icon"><Globe2 aria-hidden="true" /></span>
        <div><h2>{capabilityName(capability)}</h2><span>{capability.base_groups?.join('、') || capability.base_group || '未绑定'}</span></div>
      </div>
      <div className="nf-route-block">
        <span className="nf-field-label">当前路由链</span>
        <div className="nf-route" aria-label="当前路由链">
          {route.map((step, index) => (
            <span className="nf-route-part" key={`${step}-${index}`}>
              <span>{step}</span>{index < route.length - 1 && <ChevronRight aria-hidden="true" />}
            </span>
          ))}
        </div>
      </div>
      <dl className="nf-capability-metrics">
        <div><dt>当前延迟</dt><dd className={capability.alive ? 'is-ok' : 'is-warning'}>{delay(capability.reason?.delay_ms)}</dd></div>
        <div><dt>健康状态</dt><dd><span className={`nf-health-dot ${capability.alive ? '' : 'is-bad'}`} />{capability.alive ? '健康' : '不可用'}</dd></div>
        <div><dt>模式</dt><dd>{modeName(capability)}</dd></div>
        <div className="nf-fail-open"><dt>运行时网络退路</dt><dd>{failOpen.join(' → ') || '未编译'}</dd></div>
      </dl>
      <p className="nf-capability-reason">{capability.user_mode === 'manual_region' ? `手动保持 ${regionName(snapshot, capability.manual_region_id || capability.region_id)} · 后台自动选优已暂停` : reasonText(snapshot, capability)}</p>
      {!compact && <label className="nf-region-preview">指定地区 <select aria-label={`${capabilityName(capability)}保持地区`} defaultValue={capability.manual_region_id || capability.region_id || ''}>
        {(capability.selectable_regions || []).map(id => <option key={id} value={id}>{regionName(snapshot, id)}</option>)}
      </select><button type="button" disabled title="本机参考面为只读，请在设备 LuCI 中确认切换">确认切换（设备端）</button></label>}
    </article>
  );
}
