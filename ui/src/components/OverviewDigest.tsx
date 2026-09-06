import { AlertTriangle, BellRing, ChevronRight, Globe2, PlaneTakeoff } from 'lucide-react';
import { averageDelay, delay, displayEventName, eventDelay, eventReason, eventResult, latestDecision, providerName, regionName, sortRegionsForDisplay } from '../lib/format';
import type { EventsSnapshot, StatusSnapshot } from '../types';

type SummaryTarget = 'providers' | 'regions' | 'events';

const finite = (value?: number | null) => value != null && Number.isFinite(Number(value));

const fastest = <T,>(items: T[], value: (item: T) => number | null | undefined) => items.reduce<T | null>((best, item) => {
  if (!finite(value(item))) return best;
  if (!best || Number(value(item)) < Number(value(best))) return item;
  return best;
}, null);

const joined = (values: string[]) => values.length > 0 ? values.join('、') : '暂无';

export function OverviewDigest({
  status,
  events,
  onOpen,
}: {
  status: StatusSnapshot;
  events: EventsSnapshot;
  onOpen(target: SummaryTarget): void;
}) {
  const availabilityMeasured = Boolean(
    status.active && status.runtime.netfleet_present && status.runtime.controller_available,
  );
  const availableProviders = status.providers.filter((provider) => (
    availabilityMeasured && Number(provider.available_count) > 0 && Number(provider.available_region_count) > 0
  ));
  const selectedProviders = availabilityMeasured ? status.providers.filter((provider) => provider.selected) : [];
  const fastestProvider = fastest(availableProviders, (provider) => provider.last_best_delay_ms ?? provider.best_delay_ms);
  const fastestAverageProvider = fastest(
    availableProviders.filter((provider) => Number(provider.delay_sample_count) >= 2),
    (provider) => provider.average_best_delay_ms,
  );

  const availableRegions = availabilityMeasured ? sortRegionsForDisplay(status) : [];
  const selectedRegions = availabilityMeasured ? status.regions.filter((region) => region.selected) : [];
  const fastestRegion = fastest(availableRegions, (region) => region.last_best_delay_ms);
  const fastestAverageRegion = fastest(
    availableRegions.filter((region) => Number(region.delay_sample_count) >= 2),
    (region) => region.average_best_delay_ms,
  );
  const latest = latestDecision(events.events);

  const unavailableProviders = status.providers.filter((provider) => (
    provider.quota?.state !== 'exhausted' &&
    ((provider.available_count != null && Number(provider.available_count) === 0) ||
    (provider.available_region_count != null && Number(provider.available_region_count) === 0)
    )
  ));
  const exhaustedProviders = status.providers.filter((provider) => provider.quota?.state === 'exhausted');
  const unavailableSelectedRegions = status.regions.filter((region) => (
    region.selected &&
    region.available_count != null && region.available_provider_count != null &&
    (Number(region.available_count) === 0 || Number(region.available_provider_count) === 0)
  ));
  const attention = [
    !status.runtime.mihomo_running ? 'Mihomo 未运行' : null,
    !status.runtime.controller_available ? '设备控制接口不可用' : null,
    status.active && !status.runtime.lan_runtime?.transparent_proxy_ready ? 'LAN 透明代理不可用' : null,
    availabilityMeasured && unavailableProviders.length > 0 ? `不可用机场：${unavailableProviders.map((provider) => providerName(status, provider.id)).join('、')}` : null,
    exhaustedProviders.length > 0 ? `流量已耗尽：${exhaustedProviders.map((provider) => providerName(status, provider.id)).join('、')}` : null,
    unavailableSelectedRegions.length > 0 ? `当前使用地区已无可用路径：${unavailableSelectedRegions.map((region) => regionName(status, region.id)).join('、')}` : null,
  ].filter((item): item is string => Boolean(item));

  return (
    <>
      <section className="nf-overview-insights" aria-label="运行摘要">
        <article className="nf-overview-insight">
          <div className="nf-overview-insight-heading"><span><PlaneTakeoff aria-hidden="true" />机场态势</span><button type="button" onClick={() => onOpen('providers')} title="查看全部机场"><ChevronRight aria-hidden="true" /></button></div>
          <strong className="nf-overview-count">{availabilityMeasured ? availableProviders.length : '未测量'}<small>{availabilityMeasured ? ` / ${status.providers.length} 可用` : ' NetFleet 未接管'}</small></strong>
          <dl className="nf-overview-facts">
            <div><dt>当前使用</dt><dd>{joined(selectedProviders.map((provider) => providerName(status, provider.id)))}</dd></div>
            <div><dt>最近最优</dt><dd>{fastestProvider ? `${providerName(status, fastestProvider.id)} · ${delay(fastestProvider.last_best_delay_ms ?? fastestProvider.best_delay_ms)}` : '未测量'}</dd></div>
            <div><dt>平均最优</dt><dd>{fastestAverageProvider ? `${providerName(status, fastestAverageProvider.id)} · ${averageDelay(fastestAverageProvider.average_best_delay_ms, fastestAverageProvider.delay_sample_count)}` : '样本不足'}</dd></div>
          </dl>
        </article>

        <article className="nf-overview-insight">
          <div className="nf-overview-insight-heading"><span><Globe2 aria-hidden="true" />地区态势</span><button type="button" onClick={() => onOpen('regions')} title="查看全部地区"><ChevronRight aria-hidden="true" /></button></div>
          <strong className="nf-overview-count">{availabilityMeasured ? availableRegions.length : '未测量'}<small>{availabilityMeasured ? ' 个当前可用' : ' NetFleet 未接管'}</small></strong>
          <dl className="nf-overview-facts">
            <div><dt>当前使用</dt><dd>{joined(selectedRegions.map((region) => regionName(status, region.id)))}</dd></div>
            <div><dt>最近最优</dt><dd>{fastestRegion ? `${regionName(status, fastestRegion.id)} · ${delay(fastestRegion.last_best_delay_ms)}` : '未测量'}</dd></div>
            <div><dt>平均最优</dt><dd>{fastestAverageRegion ? `${regionName(status, fastestAverageRegion.id)} · ${averageDelay(fastestAverageRegion.average_best_delay_ms, fastestAverageRegion.delay_sample_count)}` : '样本不足'}</dd></div>
          </dl>
        </article>

        <article className="nf-overview-insight nf-overview-decision">
          <div className="nf-overview-insight-heading"><span><BellRing aria-hidden="true" />最近决策</span><button type="button" onClick={() => onOpen('events')} title="查看全部事件"><ChevronRight aria-hidden="true" /></button></div>
          {latest ? <>
            <time dateTime={new Date(latest.at * 1000).toISOString()}>{new Date(latest.at * 1000).toLocaleString()}</time>
            <strong>{displayEventName(events, 'capabilities', latest.capability)}</strong>
            <p>{eventResult(events, latest)}</p>
            <dl className="nf-overview-decision-meta">
              <div><dt>延迟</dt><dd>{eventDelay(latest)}</dd></div>
              <div><dt>原因</dt><dd>{eventReason(status, latest)}</dd></div>
            </dl>
          </> : <p className="nf-overview-empty">暂无决策记录</p>}
        </article>
      </section>

      {!availabilityMeasured && <p className="nf-overview-empty">NetFleet 当前未接管，机场和地区的实时可用性未测量。</p>}

      {attention.length > 0 && <section className="nf-overview-attention" aria-label="需要关注">
        <div><AlertTriangle aria-hidden="true" /><strong>需要关注</strong></div>
        <ul>{attention.map((item) => <li key={item}>{item}</li>)}</ul>
      </section>}
    </>
  );
}
