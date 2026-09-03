import { ChevronRight, Route } from 'lucide-react';
import { capabilityName, delay, modeName, providerName, regionName } from '../lib/format';
import type { StatusSnapshot } from '../types';

const currentRegion = (snapshot: StatusSnapshot, dataPath: string, regionId?: string | null) => {
  if (dataPath === 'native_profile') return '原生配置';
  if (dataPath === 'provider_fallback') return '机场回退';
  if (dataPath === 'direct_fallback' || dataPath === 'direct_manual') return '直连';
  return regionName(snapshot, regionId);
};

const currentProvider = (snapshot: StatusSnapshot, dataPath: string, providerId?: string | null) => {
  if (dataPath === 'native_profile') return snapshot.recovery_profile_display_name || '当前原生配置';
  if (dataPath === 'direct_fallback' || dataPath === 'direct_manual') return '不经过机场';
  return providerName(snapshot, providerId);
};

export function OverviewExitSummary({ snapshot, onOpen }: { snapshot: StatusSnapshot; onOpen(): void }) {
  const capabilities = snapshot.capabilities.filter((capability) => capability.enabled);
  return (
    <section className="nf-overview-exits" aria-labelledby="nf-overview-exits-title">
      <div className="nf-section-heading nf-overview-section-heading">
        <div>
          <h2 id="nf-overview-exits-title"><Route aria-hidden="true" />出口态势</h2>
          <p>当前地区、机场和运行状态</p>
        </div>
        <button className="nf-summary-link" type="button" onClick={onOpen}>查看详情<ChevronRight aria-hidden="true" /></button>
      </div>
      <div className="nf-overview-exit-table" role="table" aria-label="出口态势">
        <div className="nf-overview-exit-head" role="row">
          <span role="columnheader">出口</span><span role="columnheader">当前地区</span><span role="columnheader">当前机场</span>
          <span role="columnheader">当前延迟</span><span role="columnheader">健康状态</span><span role="columnheader">模式</span>
        </div>
        {capabilities.map((capability) => (
          <div className="nf-overview-exit-row" role="row" key={capability.id}>
            <strong role="cell">{capabilityName(capability)}</strong>
            <span role="cell">{currentRegion(snapshot, capability.data_path, capability.region_id)}</span>
            <span role="cell">{currentProvider(snapshot, capability.data_path, capability.provider_id)}</span>
            <span className={capability.alive ? 'is-ok' : 'is-warning'} role="cell">{delay(capability.reason?.delay_ms)}</span>
            <span role="cell"><i className={`nf-health-dot ${capability.alive ? '' : 'is-bad'}`} />{capability.alive ? '健康' : '不可用'}</span>
            <span role="cell">{modeName(capability)}</span>
          </div>
        ))}
      </div>
    </section>
  );
}
