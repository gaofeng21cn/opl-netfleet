import { Fragment, useState } from 'react';
import { ArrowDownUp, ChevronDown } from 'lucide-react';
import { SubscriptionsPreview } from '../config/SubscriptionsPreview';
import { averageDelay, countPair, delay, delayClass, providerExpiry, providerName, quota, quotaResetLabel, regionName, sortProvidersForDisplay, sortRegionsForDisplay } from '../lib/format';
import type { Provider, StatusSnapshot, SubscriptionStatus } from '../types';

const role = (value: string) => value === 'reserve' ? '备用' : '主用';
const billing = (value: string) => ({ subscription: '订阅制', buyout: '买断制' }[value] || value || '未知');
const mode = (value: string) => ({ automatic: '自动选优', manual: '手动选择', manual_only: '仅手动' }[value] || value);
const sampledAt = (value?: number | null) => value
  ? new Date(value * 1000).toLocaleString([], { month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' })
  : '暂无有效测量';
const executionAt = (value?: number | null) => value ? sampledAt(value) : '尚未执行';
const duration = (value?: number | null) => value == null ? '未提供'
  : value % 86400 === 0 ? `${value / 86400} 天`
    : value % 3600 === 0 ? `${value / 3600} 小时`
      : value % 60 === 0 ? `${value / 60} 分钟` : `${value} 秒`;
const refreshResult = (value?: string | null) => ({
  updated: '更新完成并已重载', cache_updated: '缓存已更新', partially_updated: '部分机场更新成功',
  unchanged: '订阅无变化', update_failed: '更新失败，继续使用旧缓存',
  failed: '更新失败，继续使用旧版本',
  upstream_unavailable: '上游不可用，未更新', active_precondition_failed: '运行状态不满足安全更新条件',
  rollback_restored: '更新失败，已恢复更新前运行状态', rollback_failed: '更新与回滚均失败',
}[value || ''] || (value || '尚未执行'));

const failedRefreshResults = new Set([
  'failed', 'update_failed', 'upstream_unavailable', 'active_precondition_failed', 'rollback_restored', 'rollback_failed',
]);

const subscriptionResult = (value?: string | null) => value === 'updated'
  ? '缓存已更新'
  : refreshResult(value);

const subscriptions = (snapshot: StatusSnapshot) => snapshot.subscriptions || [];
const subscriptionFor = (snapshot: StatusSnapshot, provider: Provider) => {
  if (!provider.subscription_section) return undefined;
  return subscriptions(snapshot).find((entry) => entry.section === provider.subscription_section);
};
const subscriptionState = (entry?: SubscriptionStatus) => {
  if (!entry) return '订阅信息暂不可读';
  if (entry.pending_update || entry.last_result === 'pending') return entry.cache_present ? '待更新，沿用上次缓存' : '等待首次更新';
  if (!entry.cache_present) return '没有可用缓存';
  return entry.last_result ? subscriptionResult(entry.last_result) : '缓存可用';
};
const subscriptionStateClass = (entry?: SubscriptionStatus) => (
  !entry || !entry.cache_present || failedRefreshResults.has(entry.last_result || '') ? 'is-warning' : ''
);
const cacheVersion = (entry?: SubscriptionStatus) => {
  if (!entry?.cache_present) return '无可用缓存';
  return entry.cache_sha256 ? entry.cache_sha256.slice(0, 12) : '已缓存';
};
const providerNodes = (provider: Provider, entry?: SubscriptionStatus) => {
  if (!provider.node_count_known) return '节点清单暂不可读';
  const loaded = `${countPair(provider.available_node_count, provider.node_count)} 节点`;
  return entry?.node_count != null && Number(entry.node_count) !== Number(provider.node_count)
    ? `${loaded} · 订阅 ${entry.node_count} 条`
    : loaded;
};
const subscriptionSummary = (snapshot: StatusSnapshot) => {
  const entries = subscriptions(snapshot);
  if (!entries.length) return '暂无订阅';
  const healthy = entries.filter((entry) => entry.cache_present && !failedRefreshResults.has(entry.last_result || '')).length;
  return `${healthy} / ${snapshot.subscription_refresh?.provider_count ?? entries.length} 正常`;
};

export function ProviderTable({ snapshot, full = false }: { snapshot: StatusSnapshot; full?: boolean }) {
  const [expandedProviderId, setExpandedProviderId] = useState<string | null>(null);
  const [resetDayDrafts, setResetDayDrafts] = useState<Record<string, number | null>>({});
  const regionMargin = snapshot.selection?.region_switch_margin_ms;
  const availabilityMeasured = Boolean(
    snapshot.active && snapshot.runtime.netfleet_present && snapshot.runtime.controller_available,
  );
  const providers = sortProvidersForDisplay(snapshot);
  const refresh = snapshot.subscription_refresh;
  return (
    <>
    {full && <section className="nf-policy-summary">
      <div className="nf-section-heading"><h2>订阅更新</h2><SubscriptionsPreview status={snapshot} onResetDayChange={(id, day) => setResetDayDrafts((items) => ({ ...items, [id]: day }))} /></div>
      <div className="nf-policy-grid is-five">
        <dl><dt>自动更新</dt><dd>{refresh?.enabled ? '已启用' : '已关闭'}</dd></dl>
        <dl><dt>更新周期</dt><dd>{duration(refresh?.interval_seconds)}</dd></dl>
        <dl><dt>最近执行</dt><dd>{executionAt(refresh?.last_run_at)}</dd></dl>
        <dl><dt>订阅状态</dt><dd>{subscriptionSummary(snapshot)}</dd></dl>
        <dl><dt>最近结果</dt><dd>{refreshResult(refresh?.last_result)}</dd></dl>
      </div>
    </section>}
    <section className="nf-table-section">
      <div className="nf-section-heading"><div><h2>机场</h2>{full && <p>{availabilityMeasured ? '资源数：当前可用 / 已加载。延迟：历次选优中的有效测量，每轮取最快值。' : snapshot.active ? '控制接口暂不可读，当前资源状态无法确认；以下延迟为历史有效测量。' : 'NetFleet 未接管；以下延迟为历史有效测量。'}</p>}</div><ArrowDownUp aria-hidden="true" /></div>
      <div className="nf-table-wrap">
        <table className="nf-provider-table">
          <thead><tr><th>机场</th><th>定位</th><th>可用资源</th><th>最近最优</th><th>平均最优</th><th>订阅状态</th><th>剩余流量</th><th>到期时间</th><th><span className="nf-visually-hidden">详情</span></th></tr></thead>
          <tbody>{providers.map((provider) => {
            const subscription = subscriptionFor(snapshot, provider);
            const section = provider.subscription_section || '';
            const resetDay = section in resetDayDrafts ? resetDayDrafts[section] : provider.quota?.reset_day;
            const expanded = expandedProviderId === provider.id;
            return <Fragment key={provider.id}>
              <tr className={provider.selected ? 'is-selected' : ''}>
                <td><span className="nf-table-name">{providerName(snapshot, provider.id)}</span>{provider.selected && <small>当前使用</small>}</td>
                <td>{role(provider.role)} · {billing(provider.billing)}</td>
                <td><span>{availabilityMeasured ? `${countPair(provider.available_region_count, provider.region_count)} 地区` : snapshot.active ? '暂不可读' : '未接管'}</span>{availabilityMeasured && <small>{providerNodes(provider, subscription)}</small>}</td>
                {provider.delay_sample_count === 0 ? <td colSpan={2} className="nf-muted">暂无有效测量</td> : <>
                  <td className={delayClass(provider.last_best_delay_ms ?? provider.best_delay_ms, regionMargin)}>{delay(provider.last_best_delay_ms ?? provider.best_delay_ms)}</td>
                  <td><span>{averageDelay(provider.average_best_delay_ms, provider.delay_sample_count)}</span>{Number(provider.delay_sample_count) >= 2 && <small>{provider.delay_sample_count} 次有效测量</small>}</td>
                </>}
                <td className={subscriptionStateClass(subscription)}>{subscriptionState(subscription)}</td>
                <td>{quota(provider.quota)}{provider.billing === 'subscription' && quotaResetLabel(resetDay) && <small title="手动设置，仅供套餐参考；实际结算以机场为准">{quotaResetLabel(resetDay)}{section in resetDayDrafts && '（本地草稿）'}</small>}</td>
                <td>{providerExpiry(provider)}</td>
                <td><button className="nf-icon-button nf-provider-detail-toggle" type="button" title={`${expanded ? '收起' : '查看'}${providerName(snapshot, provider.id)}详情`} aria-expanded={expanded} onClick={() => setExpandedProviderId(expanded ? null : provider.id)}><ChevronDown aria-hidden="true" /><span className="nf-visually-hidden">{expanded ? '收起' : '查看'}详情</span></button></td>
              </tr>
              <tr className="nf-provider-detail-row" hidden={!expanded}>
                <td colSpan={9}><div className="nf-provider-detail-grid">
                  {subscription?.section && <dl><dt>订阅标识</dt><dd>{subscription.section}</dd></dl>}
                  <dl><dt>缓存版本</dt><dd>{cacheVersion(subscription)}</dd></dl>
                  <dl><dt>最近尝试</dt><dd>{executionAt(subscription?.last_attempt)}</dd></dl>
                  <dl><dt>订阅更新时间</dt><dd>{executionAt(subscription?.last_success)}</dd></dl>
                  {provider.delay_sampled_at && <dl><dt>最近有效测量</dt><dd>{sampledAt(provider.delay_sampled_at)}</dd></dl>}
                </div></td>
              </tr>
            </Fragment>;
          })}</tbody>
        </table>
      </div>
    </section>
    </>
  );
}

export function RegionTable({ snapshot, full = false }: { snapshot: StatusSnapshot; full?: boolean }) {
  const regionMargin = snapshot.selection?.region_switch_margin_ms;
  const regions = sortRegionsForDisplay(snapshot);
  return (
    <section className="nf-table-section nf-region-table">
      <div className="nf-section-heading"><div><h2>地区</h2><p>当前 {regions.length} 个地区可用。资源数：当前可用 / 已加载；延迟按每轮最快有效测量累计。</p></div><ArrowDownUp aria-hidden="true" /></div>
      <div className="nf-table-wrap">
        <table>
          <thead><tr><th>地区</th><th>可用机场</th><th>可用节点</th><th>最近最优</th><th>平均最优</th><th>有效测量</th><th>模式</th></tr></thead>
          <tbody>{regions.map((region) => (
            <tr className={region.selected ? 'is-selected' : ''} key={region.id}>
              <td><span className="nf-table-name">{regionName(snapshot, region.id)}</span>{region.selected && <small>当前使用</small>}</td>
              <td>{countPair(region.available_provider_count, region.provider_count)}</td>
              <td>{region.node_count == null ? '节点清单暂不可读' : countPair(region.available_node_count, region.node_count)}</td>
              {region.delay_sample_count === 0 ? <td colSpan={3} className="nf-muted">暂无有效测量</td> : <>
                <td className={delayClass(region.last_best_delay_ms, regionMargin)}>{delay(region.last_best_delay_ms)}</td>
                <td>{averageDelay(region.average_best_delay_ms, region.delay_sample_count)}</td>
                <td>{region.delay_sample_count == null ? '统计暂不可读' : `${region.delay_sample_count} 次`}{full && region.delay_sampled_at && <small>{sampledAt(region.delay_sampled_at)}</small>}</td>
              </>}<td>{mode(region.mode)}</td>
            </tr>
          ))}</tbody>
        </table>
      </div>
    </section>
  );
}
