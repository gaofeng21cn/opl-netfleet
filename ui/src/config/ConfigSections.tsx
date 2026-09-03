import { CheckCircle2, CircleAlert, Gauge, Network, RefreshCw, ShieldCheck } from 'lucide-react';
import type { ConfigDraft } from './model';
import type { StatusSnapshot } from '../types';
import { regionalDisplayName } from '../lib/format';

interface SectionProps {
  draft: ConfigDraft;
  status: StatusSnapshot;
  onChange(next: ConfigDraft): void;
}

const replaceAt = <T extends { id: string }>(items: T[], id: string, update: Partial<T>) => (
  items.map((item) => item.id === id ? { ...item, ...update } : item)
);

function SectionHeading({ title, description }: { title: string; description: string }) {
  return <div className="nf-config-section-heading"><h2>{title}</h2><p>{description}</p></div>;
}

export function FoundationSection({ draft, status, onChange }: SectionProps) {
  const runtimeChecks = [
    ['Nikki 服务', status.runtime.nikki_enabled === true],
    ['Mihomo 核心', status.runtime.mihomo_running === true],
    ['控制接口', status.runtime.controller_available === true],
    ['网络接管', Boolean(status.runtime.lan_runtime?.transparent_proxy_ready && status.runtime.lan_runtime?.dns_ready)],
  ] as const;
  return <section className="nf-config-section">
    <SectionHeading title="基础接入" description="确认当前运行环境，并选择 NetFleet 的策略基础和退出目标。" />
    <div className="nf-environment-grid">
      {runtimeChecks.map(([label, ready]) => <div key={label}>
        {ready ? <CheckCircle2 aria-hidden="true" /> : <CircleAlert aria-hidden="true" />}
        <span>{label}</span><strong className={ready ? 'is-ok' : 'is-warning'}>{ready ? '可用' : '需要检查'}</strong>
      </div>)}
    </div>
    <div className="nf-form-rows">
      <div className="nf-form-row">
        <div><label>当前运行后端</label><p>当前实现由 Nikki 管理 OpenWrt 数据面，Mihomo 负责代理核心。</p></div>
        <div className="nf-readonly-field"><Network aria-hidden="true" />Nikki + Mihomo</div>
      </div>
      <fieldset className="nf-form-row">
        <div><legend>策略基础</legend><p>决定规则和稳定出口组从哪里开始生成。</p></div>
        <div className="nf-choice-list">
          <label><input type="radio" name="policy-source" checked={draft.policySource === 'bundle'} onChange={() => onChange({ ...draft, policySource: 'bundle' })} /><span><strong>NetFleet 内置基础策略</strong><small>机场无关，适合新安装</small></span></label>
          <label><input type="radio" name="policy-source" checked={draft.policySource === 'profile'} onChange={() => onChange({ ...draft, policySource: 'profile' })} /><span><strong>沿用当前 Nikki 配置</strong><small>用于迁移已有规则和策略组</small></span></label>
        </div>
      </fieldset>
      <div className="nf-form-row">
        <div><label htmlFor="nf-recovery-profile">退出与故障恢复</label><p>NetFleet 关闭或启用失败时优先恢复这份原生配置。</p></div>
        <select id="nf-recovery-profile" value={draft.recoveryProfile} onChange={(event) => onChange({ ...draft, recoveryProfile: event.target.value })}>
          <option value={draft.recoveryProfile}>{draft.recoveryProfile}</option>
        </select>
      </div>
    </div>
  </section>;
}

export function ProvidersSection({ draft, onChange }: SectionProps) {
  return <section className="nf-config-section">
    <SectionHeading title="机场" description="只选择 Nikki 已有订阅；订阅地址、节点和下载仍不在浏览器中编辑。" />
    <div className="nf-table-wrap nf-config-table">
      <table><thead><tr><th>参与</th><th>机场</th><th>真实资源</th><th>故障层级</th><th>计费方式</th></tr></thead>
        <tbody>{draft.providers.map((provider) => <tr key={provider.id}>
          <td><input aria-label={`${provider.displayName} 参与 NetFleet`} type="checkbox" checked={provider.enabled} onChange={(event) => onChange({ ...draft, providers: replaceAt(draft.providers, provider.id, { enabled: event.target.checked }) })} /></td>
          <td><strong>{provider.displayName}</strong><small>{provider.id}</small></td>
          <td>{provider.availableRegions ?? '未提供'} 个地区 / {provider.availableNodes ?? '未提供'} 个节点</td>
          <td><select aria-label={`${provider.displayName} 故障层级`} value={provider.role} disabled={!provider.enabled} onChange={(event) => onChange({ ...draft, providers: replaceAt(draft.providers, provider.id, { role: event.target.value as 'primary' | 'reserve' }) })}><option value="primary">主用机场</option><option value="reserve">备用机场</option></select></td>
          <td><select aria-label={`${provider.displayName} 计费方式`} value={provider.billing} disabled={!provider.enabled} onChange={(event) => onChange({ ...draft, providers: replaceAt(draft.providers, provider.id, { billing: event.target.value as 'subscription' | 'buyout' }) })}><option value="subscription">订阅制</option><option value="buyout">买断制</option></select></td>
        </tr>)}</tbody>
      </table>
    </div>
  </section>;
}

export function RegionsSection({ draft, onChange }: SectionProps) {
  return <section className="nf-config-section">
    <SectionHeading title="地区映射" description="地区来自当前机场的真实节点；只修正识别结果，不预设必须存在的地区。" />
    <div className="nf-table-wrap nf-config-table">
      <table><thead><tr><th>识别状态</th><th>地区名称</th><th>真实覆盖</th><th>自动选优</th></tr></thead>
        <tbody>{draft.regions.map((region) => <tr key={region.id}>
          <td><span className="nf-mapping-ok"><CheckCircle2 aria-hidden="true" />已识别</span></td>
          <td><input aria-label={`${regionalDisplayName(region.displayName)} 地区名称`} value={regionalDisplayName(region.displayName)} onChange={(event) => onChange({ ...draft, regions: replaceAt(draft.regions, region.id, { displayName: event.target.value }) })} /></td>
          <td>{region.availableProviders ?? '未提供'} 个机场 / {region.availableNodes ?? '未提供'} 个节点</td>
          <td><select aria-label={`${regionalDisplayName(region.displayName)} 地区模式`} value={region.mode} onChange={(event) => onChange({ ...draft, regions: replaceAt(draft.regions, region.id, { mode: event.target.value as 'automatic' | 'manual_only' }) })}><option value="automatic">参与自动选优</option><option value="manual_only">仅手动使用</option></select></td>
        </tr>)}</tbody>
      </table>
    </div>
  </section>;
}

export function ExitsSection({ draft, onChange }: SectionProps) {
  const capabilityName = (id?: string | null) => draft.capabilities.find((item) => item.id === id)?.displayName || '其他出口';
  return <section className="nf-config-section">
    <SectionHeading title="出口策略" description="决定哪些业务出口由 NetFleet 增强，以及自动选择可以使用哪些地区。" />
    <div className="nf-config-exits">
      {draft.capabilities.map((capability) => <article className="nf-config-exit" key={capability.id}>
        <div className="nf-config-exit-head">
          <div><strong>{capability.displayName}</strong><small>{capability.baseGroups.length ? `接管：${capability.baseGroups.join('、')}` : '尚未绑定原始策略组'}</small></div>
          <label className="nf-switch"><input type="checkbox" checked={capability.enabled} onChange={(event) => onChange({ ...draft, capabilities: replaceAt(draft.capabilities, capability.id, { enabled: event.target.checked }) })} /><span aria-hidden="true" /><b>{capability.enabled ? '已启用' : '已关闭'}</b></label>
        </div>
        <div className="nf-config-exit-body">
          <div><span className="nf-form-label">运行方式</span><div className="nf-segmented" role="group" aria-label={`${capability.displayName} 运行方式`}>
            <button type="button" className={capability.mode === 'automatic' ? 'is-active' : ''} disabled={!capability.enabled} onClick={() => onChange({ ...draft, capabilities: replaceAt(draft.capabilities, capability.id, { mode: 'automatic' }) })}>自动选优</button>
            <button type="button" className={capability.mode === 'manual' ? 'is-active' : ''} disabled={!capability.enabled} onClick={() => onChange({ ...draft, capabilities: replaceAt(draft.capabilities, capability.id, { mode: 'manual' }) })}>手动选择</button>
          </div></div>
          <div><span className="nf-form-label">地区限制</span><div className="nf-region-checks">
            {draft.regions.map((region) => <label key={region.id}><input type="checkbox" checked={!capability.excludedRegions.includes(region.id)} disabled={!capability.enabled} onChange={(event) => {
              const excludedRegions = event.target.checked
                ? capability.excludedRegions.filter((id) => id !== region.id)
                : [...capability.excludedRegions, region.id];
              onChange({ ...draft, capabilities: replaceAt(draft.capabilities, capability.id, { excludedRegions }) });
            }} />{regionalDisplayName(region.displayName)}</label>)}
          </div></div>
          {capability.preferRegionFrom && <p className="nf-config-follow">优先跟随“{capabilityName(capability.preferRegionFrom)}”的合规地区；该地区不合规时独立选择。</p>}
        </div>
      </article>)}
    </div>
  </section>;
}

export function AutomationSection({ draft, onChange }: SectionProps) {
  return <section className="nf-config-section">
    <SectionHeading title="自动运行" description="设置 NetFleet 何时重新比较出口，以及何时请求 Nikki 刷新已有订阅。" />
    <div className="nf-form-rows">
      <div className="nf-form-row"><div><label>周期选优</label><p>关闭后仍可手动执行单次选优。</p></div><label className="nf-switch"><input type="checkbox" checked={draft.automation.enabled} onChange={(event) => onChange({ ...draft, automation: { ...draft.automation, enabled: event.target.checked } })} /><span aria-hidden="true" /><b>{draft.automation.enabled ? '已开启' : '已关闭'}</b></label></div>
      <div className="nf-form-row"><div><label htmlFor="nf-selection-interval">选优周期</label><p>只在自动模式下执行同一套有界选择。</p></div><select id="nf-selection-interval" value={draft.automation.selectionIntervalSeconds} disabled={!draft.automation.enabled} onChange={(event) => onChange({ ...draft, automation: { ...draft.automation, selectionIntervalSeconds: Number(event.target.value) } })}><option value={900}>15 分钟</option><option value={1800}>30 分钟</option><option value={3600}>1 小时</option><option value={7200}>2 小时</option></select></div>
      <div className="nf-form-row"><div><label>定期更新订阅</label><p>实际下载和缓存仍由 Nikki 官方更新器负责。</p></div><label className="nf-switch"><input type="checkbox" checked={draft.automation.subscriptionRefreshEnabled} onChange={(event) => onChange({ ...draft, automation: { ...draft.automation, subscriptionRefreshEnabled: event.target.checked } })} /><span aria-hidden="true" /><b>{draft.automation.subscriptionRefreshEnabled ? '已开启' : '已关闭'}</b></label></div>
      <div className="nf-form-row"><div><label htmlFor="nf-refresh-interval">订阅更新周期</label><p>只有内容摘要变化时才重新生成和选优。</p></div><select id="nf-refresh-interval" value={draft.automation.subscriptionRefreshIntervalSeconds} disabled={!draft.automation.subscriptionRefreshEnabled} onChange={(event) => onChange({ ...draft, automation: { ...draft.automation, subscriptionRefreshIntervalSeconds: Number(event.target.value) } })}><option value={21600}>6 小时</option><option value={43200}>12 小时</option><option value={86400}>24 小时</option></select></div>
    </div>
  </section>;
}

export function SafetySection({ draft, onChange }: SectionProps) {
  return <section className="nf-config-section">
    <SectionHeading title="安全与恢复" description="默认值适合日常使用；只有明确需要时才调整高级门槛和检查地址。" />
    <div className="nf-safety-summary">
      <ShieldCheck aria-hidden="true" /><div><strong>优先恢复：{draft.recoveryProfile}</strong><p>只有原生配置恢复失败时，最终退路才是停止 Nikki 并恢复网络直通。</p></div>
    </div>
    <details className="nf-advanced-settings">
      <summary>高级设置</summary>
      <div className="nf-form-rows">
        <div className="nf-form-row"><div><label htmlFor="nf-region-margin">地区切换门槛</label><p>当前地区仍可用时，替代地区至少快到该数值才切换。</p></div><div className="nf-number-field"><Gauge aria-hidden="true" /><input id="nf-region-margin" type="number" min="0" value={draft.safety.regionSwitchMarginMs} onChange={(event) => onChange({ ...draft, safety: { ...draft.safety, regionSwitchMarginMs: Number(event.target.value) } })} /><span>ms</span></div></div>
        <div className="nf-form-row"><div><label htmlFor="nf-leaf-margin">节点切换门槛</label><p>避免同一地区内因微小延迟差异频繁换节点。</p></div><div className="nf-number-field"><Gauge aria-hidden="true" /><input id="nf-leaf-margin" type="number" min="0" value={draft.safety.leafSwitchMarginMs} onChange={(event) => onChange({ ...draft, safety: { ...draft.safety, leafSwitchMarginMs: Number(event.target.value) } })} /><span>ms</span></div></div>
        <div className="nf-form-row"><div><label htmlFor="nf-runtime-grace">运行失联保护</label><p>连续失联超过该时间后进入受保护恢复。</p></div><select id="nf-runtime-grace" value={draft.safety.runtimeGraceSeconds} onChange={(event) => onChange({ ...draft, safety: { ...draft.safety, runtimeGraceSeconds: Number(event.target.value) } })}><option value={60}>1 分钟</option><option value={120}>2 分钟</option><option value={300}>5 分钟</option></select></div>
        <div className="nf-form-row"><div><label htmlFor="nf-latency-url">测速地址</label><p>只用于同轮延迟比较，不代表业务资格。</p></div><input id="nf-latency-url" type="url" value={draft.safety.latencyUrl} onChange={(event) => onChange({ ...draft, safety: { ...draft.safety, latencyUrl: event.target.value } })} /></div>
        <div className="nf-form-row"><div><label htmlFor="nf-protected-url">业务保护地址</label><p>用于启用和切换后的业务可达性确认。</p></div><input id="nf-protected-url" type="url" value={draft.safety.protectedUrl} onChange={(event) => onChange({ ...draft, safety: { ...draft.safety, protectedUrl: event.target.value } })} /></div>
      </div>
    </details>
  </section>;
}

export const sectionMeta = [
  { id: 'foundation' as const, label: '基础接入', icon: Network },
  { id: 'providers' as const, label: '机场', icon: RefreshCw },
  { id: 'regions' as const, label: '地区映射', icon: CheckCircle2 },
  { id: 'exits' as const, label: '出口策略', icon: Gauge },
  { id: 'automation' as const, label: '自动运行', icon: RefreshCw },
  { id: 'safety' as const, label: '安全与恢复', icon: ShieldCheck },
];
