import { useEffect, useRef, useState } from 'react';
import { Search, X } from 'lucide-react';
import { SubscriptionsPreview } from '../config/SubscriptionsPreview';
import { averageDelay, countPair, delay, providerExpiry, providerName, quota, quotaResetLabel, regionName, sortProvidersForDisplay, sortRegionsForDisplay } from '../lib/format';
import type { Measurement, Provider, StatusSnapshot, SubscriptionStatus } from '../types';

const role = (value: string) => value === 'reserve' ? '备用' : '主用';
const billing = (value: string) => ({ subscription: '订阅制', buyout: '买断制' }[value] || value || '未知');
const mode = (value: string) => ({ automatic: '自动选优', manual: '手动选择', manual_only: '仅手动' }[value] || value);
const sampledAt = (value?: number | null) => value
  ? new Date(value * 1000).toLocaleString([], { month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' })
  : '暂无有效测量';
const executionAt = (value?: number | null) => value ? sampledAt(value) : '尚未执行';
const measurementReasons: Record<string, string> = {
  "quota_exhausted": "流量已耗尽，不参与选优",
  "group_unavailable": "候选线路尚未加载",
  "group_members_unavailable": "候选线路的节点列表不可读",
  "selected_leaf_unavailable": "候选线路未选中有效成员",
  "no_proxy_leaf": "候选线路未选中代理节点",
  "provider_nodes_unavailable": "机场的节点清单不可读",
  "leaf_not_in_provider": "所选节点不在该机场的节点清单中",
  "leaf_identity_ambiguous": "机场内存在同名节点，无法确认归属",
  "leaf_type_unavailable": "所选节点缺少类型信息",
  "group_latency_failed": "候选线路的测速健康记录为失败（未提供底层错误）",
  "group_latency_unrecorded": "候选线路缺少该测速目标的健康记录",
  "leaf_latency_failed": "所选节点的测速健康记录为失败（未提供底层错误）",
  "leaf_latency_unrecorded": "所选节点缺少该测速目标的健康记录",
  "delay_unavailable": "未取得本轮新增的有效延迟记录",
  "latency_health_failed": "未取得候选线路的测速成功记录；旧记录未保留细节",
  "no_verified_leaf": "未能确认节点归属或测速健康；旧记录未保留细节",
  "measurement_unavailable": "未取得有效测速，记录未提供具体原因"
};
function MeasurementCell({ value, snapshot }: { value?: Measurement | null; snapshot: StatusSnapshot }) {
  if (!value) return <td>尚无测速记录</td>;
  const entries = value.entries || [];
  const exhausted = value.exclusions.quota_exhausted || 0;
  const unmeasured = entries.filter(entry => !entry.ok && entry.quota_state !== 'exhausted').length;
  const explanation = (reason: string | null) => measurementReasons[reason || 'measurement_unavailable'] || '未取得有效测速，原因暂无法解释';
  return <td className="nf-measurement"><span>{delay(value.best_delay_ms, '未取得有效测速')}</span>
    <small>{value.measured_count} 项测速成功{exhausted > 0 && ` · ${exhausted} 项流量耗尽`}{unmeasured > 0 && ` · ${unmeasured} 项无有效结果`}</small>
    <small>采样于 {sampledAt(value.sampled_at)}</small>
    <details><summary>查看测速详情{entries.length > 0 && `（${entries.length} 项）`}</summary>
      <p>每项对应一个机场在一个地区的候选线路，不代表节点数。测速结果不等于业务保护检查结果。</p>
      {entries.length ? <ul>{entries.map((entry, index) => <li key={index}>
        <strong>{providerName(snapshot, entry.provider_id)} · {regionName(snapshot, entry.region_id)}</strong>
        <div>{entry.ok ? `测速成功 · ${delay(entry.delay_ms)}` : explanation(entry.measurement_reason)}</div>
        {entry.quota_state === 'exhausted' && <div>{measurementReasons.quota_exhausted}</div>}
      </li>)}</ul> : <p>此记录没有逐项详情。{Object.entries(value.exclusions).map(([reason, count]) => `${explanation(reason)}：${count} 项`).join('；')}</p>}
    </details>
  </td>;
}

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

function TableTools({ query, onQuery, sort, onSort, selectedOnly, onSelectedOnly, label }: {
  query: string; onQuery(value: string): void; sort: string; onSort(value: string): void;
  selectedOnly: boolean; onSelectedOnly(value: boolean): void; label: string;
}) {
  return <div className="nf-table-tools">
    <label className="nf-search"><Search aria-hidden="true" /><input aria-label={`搜索${label}`} placeholder={`搜索${label}`} value={query} onChange={e => onQuery(e.target.value)} /></label>
    <select aria-label={`${label}排序`} value={sort} onChange={e => onSort(e.target.value)}>
      <option value="default">默认排序</option><option value="name">名称</option><option value="latest">最近测量最快</option><option value="average">历史平均最低</option>
    </select>
    <label><input type="checkbox" checked={selectedOnly} onChange={e => onSelectedOnly(e.target.checked)} />仅当前使用</label>
  </div>;
}

export function QuotaMeter({ provider }: { provider: Provider }) {
  const value = provider.quota;
  if (!value || value.total_bytes == null || value.remaining_bytes == null || !Number.isFinite(value.total_bytes) || !Number.isFinite(value.remaining_bytes) || value.total_bytes <= 0 || value.remaining_bytes < 0 || value.remaining_bytes > value.total_bytes) return null;
  return <meter className="nf-quota-meter" aria-label="剩余流量比例" min={0} max={value.total_bytes} value={value.remaining_bytes} title={`剩余 ${Math.round(value.remaining_bytes / value.total_bytes * 100)}%`} />;
}

export function ProviderTable({ snapshot, full = false, onManageSubscriptions, subscriptionsManaged = false }: { snapshot: StatusSnapshot; full?: boolean; subscriptionsManaged?: boolean; onManageSubscriptions?(): void }) {
  const [expandedProviderId, setExpandedProviderId] = useState<string | null>(null);
  const [query, setQuery] = useState('');
  const [sort, setSort] = useState('default');
  const [selectedOnly, setSelectedOnly] = useState(false);
  const opener = useRef<HTMLButtonElement | null>(null);
  const dismiss = useRef<HTMLButtonElement | null>(null);
  useEffect(() => { if (expandedProviderId) dismiss.current?.focus({ preventScroll: true }); }, [expandedProviderId]);
  const [resetDayDrafts, setResetDayDrafts] = useState<Record<string, number | null>>({});
  const availabilityMeasured = Boolean(
    snapshot.active && snapshot.runtime.netfleet_present && snapshot.runtime.controller_available,
  );
  const providers = sortProvidersForDisplay(snapshot).filter(p => (!selectedOnly || p.selected) && providerName(snapshot, p.id).toLocaleLowerCase().includes(query.toLocaleLowerCase()));
  if (sort !== 'default') providers.sort((a, b) => sort === 'name' ? providerName(snapshot, a.id).localeCompare(providerName(snapshot, b.id), 'zh-CN') :
    (sort === 'average' ? (Number(a.delay_sample_count) >= 2 ? a.average_best_delay_ms : null) ?? Infinity : a.last_best_delay_ms ?? a.best_delay_ms ?? Infinity) -
    (sort === 'average' ? (Number(b.delay_sample_count) >= 2 ? b.average_best_delay_ms : null) ?? Infinity : b.last_best_delay_ms ?? b.best_delay_ms ?? Infinity));
  const focused = snapshot.providers.find(p => p.id === expandedProviderId);
  const focusedSubscription = focused ? subscriptionFor(snapshot, focused) : undefined;
  const focusedSection = focused?.subscription_section || '';
  const focusedResetDay = focusedSection in resetDayDrafts ? resetDayDrafts[focusedSection] : focused?.quota?.reset_day;
  const close = () => { setExpandedProviderId(null); opener.current?.focus({ preventScroll: true }); };
  const refresh = snapshot.subscription_refresh;
  return (
    <>
    {full && <section className="nf-policy-summary">
      <div className="nf-section-heading"><h2>订阅更新</h2><>{onManageSubscriptions ? <button type="button" className="nf-button-secondary" onClick={onManageSubscriptions}>管理订阅</button> : !subscriptionsManaged && <SubscriptionsPreview status={snapshot} onResetDayChange={(id, day) => setResetDayDrafts((items) => ({ ...items, [id]: day }))} />}</></div>
      <div className="nf-policy-grid is-five">
        <dl><dt>自动更新</dt><dd>{refresh?.enabled ? '已启用' : '已关闭'}</dd></dl>
        <dl><dt>更新周期</dt><dd>{duration(refresh?.interval_seconds)}</dd></dl>
        <dl><dt>最近执行</dt><dd>{executionAt(refresh?.last_run_at)}</dd></dl>
        <dl><dt>订阅状态</dt><dd>{subscriptionSummary(snapshot)}</dd></dl>
        <dl><dt>最近结果</dt><dd>{refreshResult(refresh?.last_result)}</dd></dl>
      </div>
    </section>}
    <section className="nf-table-section">
      <TableTools label="机场" query={query} onQuery={setQuery} sort={sort} onSort={setSort} selectedOnly={selectedOnly} onSelectedOnly={setSelectedOnly} />
      {full && <p className="nf-table-caption">{availabilityMeasured ? '资源数：当前可用 / 已加载。延迟：每轮最快的有效测量。' : snapshot.active ? '控制接口暂不可读；以下延迟为历史有效测量。' : 'NetFleet 未接管；以下延迟为历史有效测量。'}</p>}
      <div className={`nf-master-detail ${focused ? 'has-detail' : ''}`}>
      <div className="nf-table-wrap">
        <table className="nf-provider-table">
          <thead><tr><th>机场</th><th>定位</th><th>可用资源</th><th>最近一次测速</th><th>订阅状态</th><th>剩余流量</th><th>到期时间</th></tr></thead>
          <tbody>{providers.map((provider) => {
            const subscription = subscriptionFor(snapshot, provider);
            const section = provider.subscription_section || '';
            const resetDay = section in resetDayDrafts ? resetDayDrafts[section] : provider.quota?.reset_day;
            const expanded = expandedProviderId === provider.id;
            return <tr key={provider.id} className={expanded ? 'is-inspected' : provider.selected ? 'is-selected' : ''}>
                <td><button className="nf-name-link" type="button" aria-expanded={expanded} aria-controls={focused ? 'nf-provider-inspector' : undefined} onClick={e => { opener.current = e.currentTarget; setExpandedProviderId(provider.id); }}>{providerName(snapshot, provider.id)}</button>{provider.selected && <small>当前使用</small>}</td>
                <td>{role(provider.role)} · {billing(provider.billing)}</td>
                <td><span>{availabilityMeasured ? `${countPair(provider.available_region_count, provider.region_count)} 地区` : snapshot.active ? '暂不可读' : '未接管'}</span>{availabilityMeasured && <small>{providerNodes(provider, subscription)}</small>}</td>
                <MeasurementCell value={provider.measurement} snapshot={snapshot} />
                <td className={subscriptionStateClass(subscription)}>{subscriptionState(subscription)}</td>
                <td>{quota(provider.quota)}<QuotaMeter provider={provider} />{provider.billing === 'subscription' && quotaResetLabel(resetDay) && <small title="手动设置，仅供套餐参考；实际结算以机场为准">{quotaResetLabel(resetDay)}{section in resetDayDrafts && '（本地草稿）'}</small>}</td>
                <td >{providerExpiry(provider)}</td>
              </tr>;
          })}</tbody>
        </table>
        {providers.length === 0 && <p className="nf-empty">没有匹配的机场</p>}
      </div>
      {focused && <aside className="nf-inspector" id="nf-provider-inspector" aria-label="机场详情" onKeyDown={e => { if (e.key === 'Escape') close(); }}>
        <div className="nf-inspector-heading"><h2>{providerName(snapshot, focused.id)}</h2><button ref={dismiss} className="nf-icon-button" type="button" title="关闭机场详情" aria-label="关闭机场详情" onClick={close}><X aria-hidden="true" /></button></div>
        <p>{role(focused.role)} · {billing(focused.billing)}</p>
        <h3>运行质量</h3><dl className="nf-inspector-facts">
          <div><dt>可用资源</dt><dd>{availabilityMeasured ? providerNodes(focused, focusedSubscription) : snapshot.active ? '暂不可读' : '未接管'}</dd></div>
          <div><dt>最近测量最快</dt><dd>{delay(focused.last_best_delay_ms ?? focused.best_delay_ms)}</dd></div>
          <div><dt>历史平均最低</dt><dd>{averageDelay(focused.average_best_delay_ms, focused.delay_sample_count)}</dd></div>
          <div><dt>有效测量</dt><dd>{focused.delay_sample_count == null ? '统计暂不可读' : `${focused.delay_sample_count} 次`}</dd></div>
          {focused.delay_sampled_at && <div><dt>最后测量</dt><dd>{sampledAt(focused.delay_sampled_at)}</dd></div>}
        </dl>
        <h3>订阅与用量</h3><dl className="nf-inspector-facts">
          <div><dt>订阅状态</dt><dd>{subscriptionState(focusedSubscription)}</dd></div>
          <div><dt>剩余流量</dt><dd>{quota(focused.quota)}<QuotaMeter provider={focused} /></dd></div>
          <div><dt>到期时间</dt><dd>{providerExpiry(focused)}</dd></div>
          {focused.billing === 'subscription' && quotaResetLabel(focusedResetDay) && <div><dt>流量重置</dt><dd>{quotaResetLabel(focusedResetDay)}{focusedSection in resetDayDrafts && '（本地草稿）'}</dd></div>}
        </dl>
        <>{onManageSubscriptions ? <button type="button" className="nf-button-secondary" onClick={onManageSubscriptions}>管理订阅</button> : !subscriptionsManaged && <SubscriptionsPreview status={snapshot} onResetDayChange={(id, day) => setResetDayDrafts(items => ({ ...items, [id]: day }))} />}</>
        <h3>更新记录</h3><dl className="nf-inspector-facts">
          {focusedSubscription?.section && <div><dt>订阅标识</dt><dd>{focusedSubscription.section}</dd></div>}
          <div><dt>缓存版本</dt><dd>{cacheVersion(focusedSubscription)}</dd></div>
          <div><dt>最近尝试</dt><dd>{executionAt(focusedSubscription?.last_attempt)}</dd></div>
          <div><dt>订阅更新时间</dt><dd>{executionAt(focusedSubscription?.last_success)}</dd></div>
        </dl>
      </aside>}
      </div>
    </section>
    </>
  );
}

export function RegionTable({ snapshot, full = false, onChooseRegion, blockedReason }: { snapshot: StatusSnapshot; full?: boolean; onChooseRegion?(region: string): void; blockedReason?: string }) {
  const [query, setQuery] = useState('');
  const [sort, setSort] = useState('default');
  const [selectedOnly, setSelectedOnly] = useState(false);
  const regions = sortRegionsForDisplay(snapshot, true).filter(r => (!selectedOnly || r.selected) && regionName(snapshot, r.id).toLocaleLowerCase().includes(query.toLocaleLowerCase()));
  if (sort !== 'default') regions.sort((a, b) => sort === 'name' ? regionName(snapshot, a.id).localeCompare(regionName(snapshot, b.id), 'zh-CN') :
    (sort === 'average' ? (Number(a.delay_sample_count) >= 2 ? a.average_best_delay_ms : null) ?? Infinity : a.last_best_delay_ms ?? Infinity) -
    (sort === 'average' ? (Number(b.delay_sample_count) >= 2 ? b.average_best_delay_ms : null) ?? Infinity : b.last_best_delay_ms ?? Infinity));
  return (
    <section className="nf-table-section nf-region-table">
      <TableTools label="地区" query={query} onQuery={setQuery} sort={sort} onSort={setSort} selectedOnly={selectedOnly} onSelectedOnly={setSelectedOnly} />
      <p className="nf-table-caption">已配置 {snapshot.regions.length} 个地区 · {snapshot.active && snapshot.runtime.controller_available ? `${sortRegionsForDisplay(snapshot).length} 个有健康记录` : '实时状态未测量'} · 显示 {regions.length} 个</p>
      <div className="nf-table-wrap">
        <table>
          <thead><tr><th>地区</th><th>可用机场</th><th>可用节点</th><th>最近一次测速</th><th>历史测量</th><th>参与方式</th>{onChooseRegion && <th className="nf-region-action">操作</th>}</tr></thead>
          <tbody>{regions.map((region) => (
            <tr className={region.selected ? 'is-selected' : ''} key={region.id}>
              <td><span className="nf-table-name">{regionName(snapshot, region.id)}</span>{region.selected && <small>{snapshot.capabilities.filter(item => item.enabled && item.region_id === region.id && ['preferred', 'manual_region'].includes(item.data_path)).map(item => item.display_name || item.id).join('、') || '当前使用'}</small>}</td>
              <td>{snapshot.active && snapshot.runtime.controller_available ? countPair(region.available_provider_count, region.provider_count) : '未测量'}</td>
              <td>{!snapshot.active || !snapshot.runtime.controller_available ? '未测量' : region.node_count == null ? '节点清单暂不可读' : countPair(region.available_node_count, region.node_count)}</td>
              <MeasurementCell value={region.measurement} snapshot={snapshot} />
              <td><details><summary>历史测量</summary><div>最近 {delay(region.last_best_delay_ms)}</div><div>平均 {averageDelay(region.average_best_delay_ms, region.delay_sample_count)}</div><small>{region.delay_sample_count == null ? '统计暂不可读' : `${region.delay_sample_count} 次`}{full && region.delay_sampled_at && ` · ${sampledAt(region.delay_sampled_at)}`}</small></details></td><td>{mode(region.mode)}</td>{onChooseRegion && <td className="nf-region-action"><button type="button" className="nf-button-secondary" disabled={Boolean(blockedReason) || !snapshot.capabilities.some(item => item.can_select_region && item.selectable_regions?.includes(region.id))} title={blockedReason || (snapshot.capabilities.some(item => item.can_select_region && item.selectable_regions?.includes(region.id)) ? '手动保持指定地区，地区内节点继续由核心选择' : '当前没有可切换的授权地区')} onClick={() => onChooseRegion(region.id)}>改用此地区</button></td>}
            </tr>
          ))}</tbody>
        </table>
        {regions.length === 0 && <p className="nf-empty">{query || selectedOnly ? '没有匹配的地区，请调整筛选。' : '尚未配置地区，请先添加机场订阅。'}</p>}
      </div>
    </section>
  );
}
