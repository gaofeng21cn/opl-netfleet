import { ArrowDownUp } from 'lucide-react';
import { averageDelay, countPair, delay, delayClass, providerExpiry, providerName, quota, regionName, sortProvidersForDisplay, sortRegionsForDisplay } from '../lib/format';
import type { StatusSnapshot } from '../types';

const role = (value: string) => value === 'reserve' ? '备用' : '主用';
const billing = (value: string) => ({ subscription: '订阅制', buyout: '买断制' }[value] || value || '未知');
const mode = (value: string) => ({ automatic: '自动选优', manual: '手动选择', manual_only: '仅手动' }[value] || value);
const sampledAt = (value?: number | null) => value
  ? new Date(value * 1000).toLocaleString([], { month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' })
  : '未提供';
const duration = (value?: number | null) => value == null ? '未提供'
  : value % 86400 === 0 ? `${value / 86400} 天`
    : value % 3600 === 0 ? `${value / 3600} 小时`
      : value % 60 === 0 ? `${value / 60} 分钟` : `${value} 秒`;
const refreshResult = (value?: string | null) => ({
  updated: '更新完成并已重载', cache_updated: '缓存已更新', partially_updated: '部分机场更新成功',
  unchanged: '订阅无变化', update_failed: '更新失败，继续使用旧缓存',
  upstream_unavailable: '上游不可用，未更新', active_precondition_failed: '运行状态不满足安全更新条件',
  rollback_restored: '更新失败，已恢复更新前运行状态', rollback_failed: '更新与回滚均失败',
}[value || ''] || (value || '尚未执行'));

export function ProviderTable({ snapshot, full = false }: { snapshot: StatusSnapshot; full?: boolean }) {
  const regionMargin = snapshot.selection?.region_switch_margin_ms;
  const availabilityMeasured = Boolean(
    snapshot.active && snapshot.runtime.netfleet_present && snapshot.runtime.controller_available,
  );
  const providers = sortProvidersForDisplay(snapshot);
  const refresh = snapshot.subscription_refresh;
  return (
    <>
    {full && <section className="nf-policy-summary">
      <div className="nf-section-heading"><div><h2>订阅更新</h2><p>NetFleet 统一调度，下载、格式校验和单机场缓存仍由 Nikki 负责。</p></div></div>
      <div className="nf-policy-grid">
        <dl><dt>自动更新</dt><dd>{refresh?.enabled ? '已启用' : '已关闭'}</dd></dl>
        <dl><dt>更新周期</dt><dd>{duration(refresh?.interval_seconds)}</dd></dl>
        <dl><dt>最近执行</dt><dd>{sampledAt(refresh?.last_run_at)}</dd></dl>
        <dl><dt>最近结果</dt><dd>{refreshResult(refresh?.last_result)}</dd></dl>
      </div>
    </section>}
    <section className="nf-table-section">
      <div className="nf-section-heading"><div><h2>机场</h2>{full && <p>{availabilityMeasured ? '运行资格和配额来自同一次设备状态读取；平均最优至少汇总 2 个有效样本。' : 'NetFleet 当前未接管，实时可用性未测量；历史延迟、配额和到期时间仍可查看。'}</p>}</div><ArrowDownUp aria-hidden="true" /></div>
      <div className="nf-table-wrap">
        <table>
          <thead><tr><th>机场</th><th>层级</th><th>计费</th><th>可用地区</th>{full && <th>候选组</th>}<th>最近最优</th><th>平均最优</th><th>样本</th>{full && <th>最后测量</th>}<th>剩余流量</th><th>到期时间</th></tr></thead>
          <tbody>{providers.map((provider) => (
            <tr className={provider.selected ? 'is-selected' : ''} key={provider.id}>
              <td><span className="nf-table-name">{providerName(snapshot, provider.id)}</span>{provider.selected && <small>当前使用</small>}</td>
              <td>{role(provider.role)}</td><td>{billing(provider.billing)}</td>
              <td>{availabilityMeasured ? countPair(provider.available_region_count, provider.region_count) : '未测量'}</td>
              {full && <td>{availabilityMeasured ? countPair(provider.available_count, provider.candidate_count) : '未测量'}</td>}
              <td className={delayClass(provider.last_best_delay_ms ?? provider.best_delay_ms, regionMargin)}>{delay(provider.last_best_delay_ms ?? provider.best_delay_ms)}</td>
              <td>{averageDelay(provider.average_best_delay_ms, provider.delay_sample_count)}</td>
              <td>{provider.delay_sample_count ?? '未提供'}</td>
              {full && <td>{sampledAt(provider.delay_sampled_at)}</td>}
              <td>{quota(provider.quota)}</td>
              <td>{providerExpiry(provider)}</td>
            </tr>
          ))}</tbody>
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
