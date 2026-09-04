import { Fragment, useState } from 'react';
import { ArrowDownUp, ChevronDown, ExternalLink } from 'lucide-react';
import { averageDelay, countPair, delay, delayClass, providerExpiry, providerName, quota, regionName, sortProvidersForDisplay, sortRegionsForDisplay } from '../lib/format';
import type { Provider, StatusSnapshot, SubscriptionStatus } from '../types';

const role = (value: string) => value === 'reserve' ? '备用' : '主用';
const billing = (value: string) => ({ subscription: '订阅制', buyout: '买断制' }[value] || value || '未知');
const mode = (value: string) => ({ automatic: '自动选优', manual: '手动选择', manual_only: '仅手动' }[value] || value);
const sampledAt = (value?: number | null) => value
  ? new Date(value * 1000).toLocaleString([], { month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' })
  : '未提供';
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
  if (!entry) return '未提供';
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
  if (!provider.node_count_known) return '节点未提供';
  const loaded = `${countPair(provider.available_node_count, provider.node_count)} 节点`;
  return entry?.node_count != null && Number(entry.node_count) !== Number(provider.node_count)
    ? `${loaded} · 订阅 ${entry.node_count} 条`
    : loaded;
};
const subscriptionSummary = (snapshot: StatusSnapshot) => {
  const entries = subscriptions(snapshot);
  if (!entries.length) return '未提供';
  const healthy = entries.filter((entry) => entry.cache_present && !failedRefreshResults.has(entry.last_result || '')).length;
  return `${healthy} / ${snapshot.subscription_refresh?.provider_count ?? entries.length} 正常`;
};

export function ProviderTable({ snapshot, full = false }: { snapshot: StatusSnapshot; full?: boolean }) {
  const [expandedProviderId, setExpandedProviderId] = useState<string | null>(null);
  const regionMargin = snapshot.selection?.region_switch_margin_ms;
  const availabilityMeasured = Boolean(
    snapshot.active && snapshot.runtime.netfleet_present && snapshot.runtime.controller_available,
  );
  const providers = sortProvidersForDisplay(snapshot);
  const refresh = snapshot.subscription_refresh;
  return (
    <>
    {full && <section className="nf-policy-summary">
      <div className="nf-section-heading"><div><h2>订阅更新</h2><p>订阅地址和凭据由设备端 Nikki 管理；NetFleet 负责安全更新、机场角色和自动选优。</p></div><a className="nf-inline-link" href="/cgi-bin/luci/admin/services/nikki/profile" target="_blank" rel="noreferrer" title="在新标签页打开 Nikki 订阅管理"><ExternalLink aria-hidden="true" />管理订阅</a></div>
      <div className="nf-policy-grid is-five">
        <dl><dt>自动更新</dt><dd>{refresh?.enabled ? '已启用' : '已关闭'}</dd></dl>
        <dl><dt>更新周期</dt><dd>{duration(refresh?.interval_seconds)}</dd></dl>
        <dl><dt>最近执行</dt><dd>{executionAt(refresh?.last_run_at)}</dd></dl>
        <dl><dt>订阅状态</dt><dd>{subscriptionSummary(snapshot)}</dd></dl>
        <dl><dt>最近结果</dt><dd>{refreshResult(refresh?.last_result)}</dd></dl>
      </div>
    </section>}
    <section className="nf-table-section">
      <div className="nf-section-heading"><div><h2>机场</h2>{full && <p>{availabilityMeasured ? '每行汇总订阅状态和运行质量；平均最优至少汇总 2 个有效样本。' : 'NetFleet 当前未接管，实时可用性未测量；订阅状态、历史延迟、配额和到期时间仍可查看。'}</p>}</div><ArrowDownUp aria-hidden="true" /></div>
      <div className="nf-table-wrap">
        <table className="nf-provider-table">
          <thead><tr><th>机场</th><th>定位</th><th>可用资源</th><th>最近最优</th><th>平均最优</th><th>订阅状态</th><th>剩余流量</th><th>到期时间</th><th><span className="nf-visually-hidden">详情</span></th></tr></thead>
          <tbody>{providers.map((provider) => {
            const subscription = subscriptionFor(snapshot, provider);
            const expanded = expandedProviderId === provider.id;
            return <Fragment key={provider.id}>
              <tr className={provider.selected ? 'is-selected' : ''}>
                <td><span className="nf-table-name">{providerName(snapshot, provider.id)}</span>{provider.selected && <small>当前使用</small>}</td>
                <td>{role(provider.role)} · {billing(provider.billing)}</td>
                <td><span>{availabilityMeasured ? `${countPair(provider.available_region_count, provider.region_count)} 地区` : '未测量'}</span>{availabilityMeasured && <small>{providerNodes(provider, subscription)}</small>}</td>
                <td className={delayClass(provider.last_best_delay_ms ?? provider.best_delay_ms, regionMargin)}>{delay(provider.last_best_delay_ms ?? provider.best_delay_ms)}</td>
                <td><span>{averageDelay(provider.average_best_delay_ms, provider.delay_sample_count)}</span><small>{provider.delay_sample_count ?? '未提供'} 个样本</small></td>
                <td className={subscriptionStateClass(subscription)}>{subscriptionState(subscription)}</td>
                <td>{quota(provider.quota)}</td>
                <td>{providerExpiry(provider)}</td>
                <td><button className="nf-icon-button nf-provider-detail-toggle" type="button" title={`${expanded ? '收起' : '查看'}${providerName(snapshot, provider.id)}详情`} aria-expanded={expanded} onClick={() => setExpandedProviderId(expanded ? null : provider.id)}><ChevronDown aria-hidden="true" /><span className="nf-visually-hidden">{expanded ? '收起' : '查看'}详情</span></button></td>
              </tr>
              <tr className="nf-provider-detail-row" hidden={!expanded}>
                <td colSpan={9}><div className="nf-provider-detail-grid">
                  <dl><dt>订阅标识</dt><dd>{subscription?.section || '未提供'}</dd></dl>
                  <dl><dt>缓存版本</dt><dd>{cacheVersion(subscription)}</dd></dl>
                  <dl><dt>最近尝试</dt><dd>{executionAt(subscription?.last_attempt)}</dd></dl>
                  <dl><dt>订阅更新时间</dt><dd>{executionAt(subscription?.last_success)}</dd></dl>
                  <dl><dt>最后测量</dt><dd>{sampledAt(provider.delay_sampled_at)}</dd></dl>
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
      <div className="nf-section-heading"><div><h2>地区</h2><p>当前 {regions.length} 个地区有真实可用路径；平均最优至少汇总 2 个有效样本。</p></div><ArrowDownUp aria-hidden="true" /></div>
      <div className="nf-table-wrap">
        <table>
          <thead><tr><th>地区</th><th>可用机场</th><th>节点</th><th>最近最优</th><th>平均最优</th><th>样本</th>{full && <th>最后测量</th>}<th>模式</th></tr></thead>
          <tbody>{regions.map((region) => (
            <tr className={region.selected ? 'is-selected' : ''} key={region.id}>
              <td><span className="nf-table-name">{regionName(snapshot, region.id)}</span>{region.selected && <small>当前使用</small>}</td>
              <td>{countPair(region.available_provider_count, region.provider_count)}</td>
              <td>{countPair(region.available_node_count, region.node_count)}</td>
              <td className={delayClass(region.last_best_delay_ms, regionMargin)}>{delay(region.last_best_delay_ms)}</td>
              <td>{averageDelay(region.average_best_delay_ms, region.delay_sample_count)}</td><td>{region.delay_sample_count ?? '未提供'}</td>{full && <td>{sampledAt(region.delay_sampled_at)}</td>}<td>{mode(region.mode)}</td>
            </tr>
          ))}</tbody>
        </table>
      </div>
    </section>
  );
}
