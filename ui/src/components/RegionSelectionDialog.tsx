import { useState } from 'react';
import { ConfirmDialog } from './ConfirmDialog';
import { capabilityName, capabilityRoute, regionName } from '../lib/format';
import type { StatusSnapshot } from '../types';

export function RegionSelectionDialog({ snapshot, initialCapability, initialRegion, blockedReason, onCancel, onConfirm }: {
  snapshot: StatusSnapshot;
  initialCapability?: string;
  initialRegion?: string;
  blockedReason?: string;
  onCancel(): void;
  onConfirm(capability: string, region: string): void;
}) {
  const [capabilityId, setCapabilityId] = useState(initialCapability || '');
  const [regionId, setRegionId] = useState(initialRegion || '');
  const capabilities = snapshot.capabilities.filter(item => item.can_select_region &&
    (!initialRegion || item.selectable_regions?.includes(initialRegion)));
  const capability = capabilities.find(item => item.id === capabilityId) || capabilities[0];
  const regions = capability?.selectable_regions || [];
  const preferred = regionId || capability?.manual_region_id || capability?.region_id;
  const region = regions.find(id => id === preferred) || regions[0] || '';
  const reason = blockedReason || (!capability || !region ? '当前没有可切换的授权地区' : undefined);
  return <ConfirmDialog title="指定地区" description="仅切换此出口，其他出口保持当前路径。地区内继续自动选择节点；整轮后台自动选优暂停，直到恢复自动选优。重新应用配置或启用时会按策略重新选择。" confirmLabel="确认切换" busy={Boolean(reason)} onCancel={onCancel}
    onConfirm={() => { if (!reason && capability && regions.includes(region)) onConfirm(capability.id, region); }}>
    <div className="nf-region-dialog-fields">
      <label>出口<select value={capability?.id || ''} disabled={Boolean(reason)} onChange={event => { setCapabilityId(event.target.value); setRegionId(initialRegion || ''); }}>
        {!capability && <option value="">无可选出口</option>}
        {capabilities.map(item => <option value={item.id} key={item.id}>{capabilityName(item)}</option>)}
      </select></label>
      {capability && <p>当前路径：{capabilityRoute(snapshot, capability).join(' → ')}</p>}
      <label>保持地区<select value={region} disabled={Boolean(reason)} onChange={event => setRegionId(event.target.value)}>
        {!region && <option value="">无授权地区</option>}
        {regions.map(id => <option value={id} key={id}>{regionName(snapshot, id)}</option>)}
      </select></label>
      <p>切换后验证业务连通性；验证失败则恢复此前健康选择。</p>
      {reason && <p role="status" className="nf-inline-warning">{reason}</p>}
    </div>
  </ConfirmDialog>;
}
