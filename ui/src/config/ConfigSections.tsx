import { useState } from 'react';
import { CheckCircle2, CircleAlert, Files, Gauge, Network, Plus, RefreshCw, Route, ShieldCheck, Trash2, Waypoints } from 'lucide-react';
import type { ConfigDraft, RoutingRuleDraft } from './model';
import type { StatusSnapshot } from '../types';
import { regionalDisplayName } from '../lib/format';
import { SubscriptionsPreview } from './SubscriptionsPreview';

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
  const [migration, setMigration] = useState(false);
  const runtimeChecks = [
    ['运行后端', status.runtime.backend_enabled === true],
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
        <div><label>当前运行后端</label></div>
        <div className="nf-readonly-field"><Network aria-hidden="true" />{draft.backendDisplayName}{draft.backend === 'nikki-mihomo' && <button type="button" onClick={() => setMigration(true)}>迁移到 NetFleet 原生后端</button>}</div>
      </div>
      {migration && <div className="nf-config-validation" role="status"><p>NetFleet 将接管机场订阅、Mihomo、DNS 和透明代理。设备会检查新后端；失败时恢复旧后端。迁移期间网络可能短暂中断。</p><button type="button" onClick={() => setMigration(false)}>取消</button><button type="button" onClick={() => { onChange({ ...draft, backend: 'native-mihomo', backendDisplayName: 'NetFleet + Mihomo' }); setMigration(false); }}>确认本地预览</button></div>}
      <fieldset className="nf-form-row">
        <div><legend>策略基础</legend><p>决定规则和稳定出口组从哪里开始生成。</p></div>
        <div className="nf-choice-list">
          {draft.policySourceOptions.map((option) => <label key={`${option.kind}|${option.ref}`}><input type="radio" name="policy-source" checked={draft.policySource.kind === option.kind && draft.policySource.ref === option.ref} onChange={() => onChange({ ...draft, policySource: option })} /><span><strong>{option.displayName}</strong><small>{option.kind === 'bundle' ? '机场无关，适合新安装' : '沿用该配置的规则和策略组'}</small></span></label>)}
        </div>
      </fieldset>
      <div className="nf-form-row">
        <div><label htmlFor="nf-recovery-profile">退出与故障恢复</label><p>NetFleet 关闭或启用失败时优先恢复这份原生配置。</p></div>
        <select id="nf-recovery-profile" value={draft.recoveryProfile.ref} onChange={(event) => onChange({ ...draft, recoveryProfile: draft.recoveryProfileOptions.find((item) => item.ref === event.target.value) || draft.recoveryProfile })}>
          {draft.recoveryProfileOptions.map((option) => <option key={option.ref} value={option.ref}>{option.displayName}</option>)}
        </select>
      </div>
    </div>
  </section>;
}

export function ProvidersSection({ draft, status, onChange }: SectionProps) {
  const available = draft.providerOptions.filter((option) => !draft.providers.some((item) => item.id === option.id));
  const [selected, setSelected] = useState('');
  const selectedId = available.some((item) => item.id === selected) ? selected : available[0]?.id || '';
  return <section className="nf-config-section">
    <SectionHeading title="机场" description="选择参与 NetFleet 的订阅及其运行角色。" />
    <SubscriptionsPreview status={status} />
    <div className="nf-table-wrap nf-config-table">
      <table><thead><tr><th>参与</th><th>机场</th><th>真实资源</th><th>故障层级</th><th>计费方式</th><th>操作</th></tr></thead>
        <tbody>{draft.providers.map((provider) => <tr key={provider.id}>
          <td><input aria-label={`${provider.displayName} 参与 NetFleet`} type="checkbox" checked={provider.enabled} onChange={(event) => onChange({ ...draft, providers: replaceAt(draft.providers, provider.id, { enabled: event.target.checked }) })} /></td>
          <td><strong>{provider.displayName}</strong><small>{provider.id}</small></td>
          <td>{provider.availableRegions ?? '未提供'} 个地区 / {provider.availableNodes ?? '未提供'} 个节点</td>
          <td><select aria-label={`${provider.displayName} 故障层级`} value={provider.role} disabled={!provider.enabled} onChange={(event) => onChange({ ...draft, providers: replaceAt(draft.providers, provider.id, { role: event.target.value as 'primary' | 'reserve' }) })}><option value="primary">主用机场</option><option value="reserve">备用机场</option></select></td>
          <td><select aria-label={`${provider.displayName} 计费方式`} value={provider.billing} disabled={!provider.enabled} onChange={(event) => onChange({ ...draft, providers: replaceAt(draft.providers, provider.id, { billing: event.target.value as 'subscription' | 'buyout' }) })}><option value="subscription">订阅制</option><option value="buyout">买断制</option></select></td>
          <td><button className="nf-icon-button" type="button" title="移除机场" aria-label={`移除 ${provider.displayName}`} onClick={() => onChange({ ...draft, providers: draft.providers.filter((item) => item.id !== provider.id) })}><Trash2 aria-hidden="true" /></button></td>
        </tr>)}</tbody>
      </table>
    </div>
    {available.length > 0 && <div className="nf-inline-add"><select aria-label="可添加机场" value={selectedId} onChange={(event) => setSelected(event.target.value)}>{available.map((option) => <option key={option.id} value={option.id}>{option.displayName}</option>)}</select><button type="button" onClick={() => {
      const option = available.find((item) => item.id === selectedId);
      if (!option) return;
      const missingRegions = option.regionIds.filter((id) => !draft.regions.some((region) => region.id === id)).map((id) => {
        const region = draft.regionOptions.find((item) => item.id === id);
        return region ? { id: region.id, displayName: region.displayName, flag: region.code, displayOrder: region.displayOrder, mode: 'automatic' as const } : null;
      }).filter((item): item is NonNullable<typeof item> => item !== null);
      onChange({ ...draft, providers: [...draft.providers, { ...option, enabled: true, role: 'primary', billing: 'subscription' }], regions: [...draft.regions, ...missingRegions] });
    }}><Plus aria-hidden="true" />添加机场</button></div>}
  </section>;
}

export function RegionsSection({ draft, onChange }: SectionProps) {
  const available = draft.regionOptions.filter((option) => !draft.regions.some((item) => item.id === option.id) && draft.providers.some((provider) => {
    const providerOption = draft.providerOptions.find((item) => item.id === provider.id);
    return providerOption?.regionIds.includes(option.id);
  }));
  const [selected, setSelected] = useState('');
  const selectedId = available.some((item) => item.id === selected) ? selected : available[0]?.id || '';
  return <section className="nf-config-section">
    <SectionHeading title="地区映射" description="地区来自当前机场的真实节点；只修正识别结果，不预设必须存在的地区。" />
    <div className="nf-table-wrap nf-config-table">
      <table><thead><tr><th>识别状态</th><th>地区名称</th><th>真实覆盖</th><th>使用机场</th><th>自动选优</th><th>操作</th></tr></thead>
        <tbody>{draft.regions.map((region) => <tr key={region.id}>
          <td><span className="nf-mapping-ok"><CheckCircle2 aria-hidden="true" />已识别</span></td>
          <td><input aria-label={`${regionalDisplayName(region.displayName)} 地区名称`} value={regionalDisplayName(region.displayName)} onChange={(event) => onChange({ ...draft, regions: replaceAt(draft.regions, region.id, { displayName: event.target.value }) })} /></td>
          <td>{region.availableProviders ?? '未提供'} 个机场 / {region.availableNodes ?? '未提供'} 个节点</td>
          <td><div className="nf-region-checks">{draft.providers.map((provider) => {
            const option = draft.providerOptions.find((item) => item.id === provider.id);
            const supported = provider.regionIds.includes(region.id) || option?.regionIds.includes(region.id);
            return <label key={provider.id}><input type="checkbox" checked={provider.regionIds.includes(region.id)} disabled={!supported} onChange={(event) => {
              const regionIds = event.target.checked ? [...provider.regionIds, region.id] : provider.regionIds.filter((id) => id !== region.id);
              onChange({ ...draft, providers: replaceAt(draft.providers, provider.id, { regionIds }) });
            }} />{provider.displayName}</label>;
          })}</div></td>
          <td><select aria-label={`${regionalDisplayName(region.displayName)} 地区模式`} value={region.mode} onChange={(event) => onChange({ ...draft, regions: replaceAt(draft.regions, region.id, { mode: event.target.value as 'automatic' | 'manual_only' }) })}><option value="automatic">参与自动选优</option><option value="manual_only">仅手动使用</option></select></td>
          <td><button className="nf-icon-button" type="button" title="移除地区" aria-label={`移除 ${region.displayName}`} onClick={() => onChange({
            ...draft,
            regions: draft.regions.filter((item) => item.id !== region.id),
            providers: draft.providers.map((item) => ({ ...item, regionIds: item.regionIds.filter((id) => id !== region.id) })),
            capabilities: draft.capabilities.map((item) => ({ ...item, regionIds: item.regionIds.filter((id) => id !== region.id) })),
          })}><Trash2 aria-hidden="true" /></button></td>
        </tr>)}</tbody>
      </table>
    </div>
    {available.length > 0 && <div className="nf-inline-add"><select aria-label="可添加地区" value={selectedId} onChange={(event) => setSelected(event.target.value)}>{available.map((option) => <option key={option.id} value={option.id}>{option.code} {option.displayName}</option>)}</select><button type="button" onClick={() => {
      const option = available.find((item) => item.id === selectedId);
      if (!option) return;
      onChange({
        ...draft,
        regions: [...draft.regions, { id: option.id, displayName: option.displayName, flag: option.code, displayOrder: option.displayOrder, mode: 'automatic' }],
        providers: draft.providers.map((provider) => {
          const providerOption = draft.providerOptions.find((item) => item.id === provider.id);
          return providerOption?.regionIds.includes(option.id) ? { ...provider, regionIds: [...provider.regionIds, option.id] } : provider;
        }),
      });
    }}><Plus aria-hidden="true" />添加地区</button></div>}
  </section>;
}

export function ExitsSection({ draft, onChange }: SectionProps) {
  const capabilityName = (id?: string | null) => draft.capabilities.find((item) => item.id === id)?.displayName || '其他出口';
  const [newId, setNewId] = useState('');
  const [newName, setNewName] = useState('');
  const usedGroups = (exceptId?: string) => new Set(draft.capabilities.filter((item) => item.id !== exceptId).flatMap((item) => [item.entryGroup, ...item.policyGroups].filter(Boolean)) as string[]);
  const availableEntryGroups = draft.policyGroups.filter((group) => !usedGroups().has(group));
  const [newEntry, setNewEntry] = useState('');
  const selectedEntry = availableEntryGroups.includes(newEntry) ? newEntry : availableEntryGroups[0] || '';
  return <section className="nf-config-section">
    <SectionHeading title="出口策略" description="决定哪些业务出口由 NetFleet 增强，以及自动选择可以使用哪些地区。" />
    <div className="nf-config-exits">
      {draft.capabilities.map((capability) => <article className="nf-config-exit" key={capability.id}>
        <div className="nf-config-exit-head">
          <div><input aria-label={`${capability.id} 出口名称`} value={capability.displayName} onChange={(event) => onChange({ ...draft, capabilities: replaceAt(draft.capabilities, capability.id, { displayName: event.target.value }) })} /><small>{capability.id}</small></div>
          <div className="nf-inline-actions"><label className="nf-switch"><input type="checkbox" checked={capability.enabled} onChange={(event) => onChange({ ...draft, capabilities: replaceAt(draft.capabilities, capability.id, { enabled: event.target.checked }) })} /><span aria-hidden="true" /><b>{capability.enabled ? '已启用' : '已关闭'}</b></label><button className="nf-icon-button" type="button" title="移除出口" aria-label={`移除 ${capability.displayName}`} onClick={() => onChange({ ...draft, capabilities: draft.capabilities.filter((item) => item.id !== capability.id).map((item) => item.preferRegionFrom === capability.id ? { ...item, preferRegionFrom: null } : item), routingRules: draft.routingRules.filter((rule) => rule.capability !== capability.id) })}><Trash2 aria-hidden="true" /></button></div>
        </div>
        <div className="nf-config-exit-body">
          <div><span className="nf-form-label">运行方式</span><div className="nf-segmented" role="group" aria-label={`${capability.displayName} 运行方式`}>
            <button type="button" className={capability.mode === 'automatic' ? 'is-active' : ''} disabled={!capability.enabled} onClick={() => onChange({ ...draft, capabilities: replaceAt(draft.capabilities, capability.id, { mode: 'automatic' }) })}>自动选优</button>
            <button type="button" className={capability.mode === 'manual' ? 'is-active' : ''} disabled={!capability.enabled} onClick={() => onChange({ ...draft, capabilities: replaceAt(draft.capabilities, capability.id, { mode: 'manual' }) })}>手动选择</button>
          </div></div>
          <div><span className="nf-form-label">默认出口组</span><select value={capability.entryGroup || ''} disabled={!capability.enabled} onChange={(event) => onChange({ ...draft, capabilities: replaceAt(draft.capabilities, capability.id, { entryGroup: event.target.value || null }) })}><option value="">请选择</option>{draft.policyGroups.map((group) => <option key={group} value={group} disabled={usedGroups(capability.id).has(group)}>{group}</option>)}</select></div>
          <div><span className="nf-form-label">业务分类</span><div className="nf-region-checks">{draft.policyGroups.filter((group) => group !== capability.entryGroup).map((group) => <label key={group}><input type="checkbox" checked={capability.policyGroups.includes(group)} disabled={!capability.enabled || usedGroups(capability.id).has(group)} onChange={(event) => {
            const policyGroups = event.target.checked ? [...capability.policyGroups, group] : capability.policyGroups.filter((item) => item !== group);
            onChange({ ...draft, capabilities: replaceAt(draft.capabilities, capability.id, { policyGroups }) });
          }} />{group}</label>)}</div></div>
          <div><span className="nf-form-label">地区限制</span><div className="nf-region-checks">
            {draft.regions.map((region) => <label key={region.id}><input type="checkbox" checked={capability.regionIds.includes(region.id)} disabled={!capability.enabled} onChange={(event) => {
              const regionIds = event.target.checked
                ? [...capability.regionIds, region.id]
                : capability.regionIds.filter((id) => id !== region.id);
              onChange({ ...draft, capabilities: replaceAt(draft.capabilities, capability.id, { regionIds }) });
            }} />{regionalDisplayName(region.displayName)}</label>)}
          </div></div>
          <div><span className="nf-form-label">地区协同</span><select value={capability.preferRegionFrom || ''} disabled={!capability.enabled || capability.mode !== 'automatic'} onChange={(event) => onChange({ ...draft, capabilities: replaceAt(draft.capabilities, capability.id, { preferRegionFrom: event.target.value || null }) })}><option value="">独立选择</option>{draft.capabilities.filter((item) => item.id !== capability.id && item.enabled && item.mode === 'automatic').map((item) => <option value={item.id} key={item.id}>跟随 {item.displayName}</option>)}</select>{capability.preferRegionFrom && <p className="nf-config-follow">优先跟随“{capabilityName(capability.preferRegionFrom)}”的合规地区；该地区不合规时独立选择。</p>}</div>
        </div>
      </article>)}
    </div>
    {availableEntryGroups.length > 0 && <div className="nf-inline-add"><input value={newId} placeholder="稳定 ID，如 streaming" onChange={(event) => setNewId(event.target.value)} /><input value={newName} placeholder="显示名称" onChange={(event) => setNewName(event.target.value)} /><select value={selectedEntry} onChange={(event) => setNewEntry(event.target.value)}>{availableEntryGroups.map((group) => <option key={group} value={group}>{group}</option>)}</select><button type="button" disabled={!/^[A-Za-z0-9][A-Za-z0-9_-]*$/.test(newId) || !newName.trim() || draft.capabilities.some((item) => item.id === newId)} onClick={() => {
      onChange({ ...draft, capabilities: [...draft.capabilities, { id: newId, displayName: newName.trim(), enabled: true, mode: 'manual', entryGroup: selectedEntry, policyGroups: [], regionIds: draft.regions.map((region) => region.id), preferRegionFrom: null }] });
      setNewId(''); setNewName(''); setNewEntry('');
    }}><Plus aria-hidden="true" />添加出口</button></div>}
  </section>;
}

export function RoutingSection({ draft, onChange }: SectionProps) {
  const [value, setValue] = useState('');
  const [kind, setKind] = useState<RoutingRuleDraft['kind']>('domain_suffix');
  const [capability, setCapability] = useState('');
  const selectedCapability = capability === '__direct' || draft.capabilities.some((item) => item.id === capability) ? capability : draft.capabilities[0]?.id || '__direct';
  const route = (rule: RoutingRuleDraft, target: string): RoutingRuleDraft => target === '__direct'
    ? { kind: rule.kind, value: rule.value, target: 'direct' }
    : { kind: rule.kind, value: rule.value, capability: target };
  const options = <><option value="__direct">直连</option>{draft.capabilities.map(item => <option key={item.id} value={item.id}>{item.displayName}</option>)}</>;
  const kinds = <><option value="domain_suffix">域名后缀</option><option value="ip_cidr">IP 网段</option></>;
  return <section className="nf-config-section">
    <SectionHeading title="业务规则" description="为域名后缀或 IPv4 / IPv6 网段指定出口或直连，按列表顺序匹配。" />
    <div className="nf-table-wrap nf-config-table"><table><thead><tr><th>类型</th><th>匹配内容</th><th>使用出口</th><th>操作</th></tr></thead><tbody>{draft.routingRules.map((rule, index) => <tr key={index}>
      <td><select aria-label={`规则 ${index + 1} 类型`} value={rule.kind} onChange={event => onChange({ ...draft, routingRules: draft.routingRules.map((item, at) => at === index ? { ...item, kind: event.target.value as RoutingRuleDraft['kind'] } : item) })}>{kinds}</select></td>
      <td><input aria-label={`规则 ${index + 1} 匹配内容`} value={rule.value} onChange={event => onChange({ ...draft, routingRules: draft.routingRules.map((item, at) => at === index ? { ...item, value: event.target.value.trim() } : item) })} /></td>
      <td><select aria-label={`规则 ${index + 1} 出口`} value={rule.target === 'direct' ? '__direct' : rule.capability || ''} onChange={event => onChange({ ...draft, routingRules: draft.routingRules.map((item, at) => at === index ? route(item, event.target.value) : item) })}>{options}</select></td>
      <td><button className="nf-icon-button" type="button" title="移除规则" aria-label={`移除 ${rule.value}`} onClick={() => onChange({ ...draft, routingRules: draft.routingRules.filter((_, at) => at !== index) })}><Trash2 aria-hidden="true" /></button></td></tr>)}</tbody></table></div>
    <div className="nf-inline-add nf-rule-add"><select aria-label="新规则类型" value={kind} onChange={event => setKind(event.target.value as RoutingRuleDraft['kind'])}>{kinds}</select><input aria-label="新规则匹配内容" value={value} placeholder={kind === 'domain_suffix' ? 'example.com' : '203.0.113.0/24 或 2001:db8::/32'} onChange={event => setValue(event.target.value)} /><select aria-label="新规则出口" value={selectedCapability} onChange={event => setCapability(event.target.value)}>{options}</select><button type="button" disabled={!value.trim()} onClick={() => { onChange({ ...draft, routingRules: [...draft.routingRules, route({ kind, value: value.trim() }, selectedCapability)] }); setValue(''); }}><Plus aria-hidden="true" />添加规则</button></div>
  </section>;
}

export function AutomationSection({ draft, onChange }: SectionProps) {
  return <section className="nf-config-section">
    <SectionHeading title="自动运行" description="设置重新比较出口和更新已有订阅的周期。" />
    <div className="nf-form-rows">
      <div className="nf-form-row"><div><label>周期选优</label><p>关闭后仍可手动执行单次选优。</p></div><label className="nf-switch"><input type="checkbox" checked={draft.automation.enabled} onChange={(event) => onChange({ ...draft, automation: { ...draft.automation, enabled: event.target.checked } })} /><span aria-hidden="true" /><b>{draft.automation.enabled ? '已开启' : '已关闭'}</b></label></div>
      <div className="nf-form-row"><div><label htmlFor="nf-selection-interval">选优周期</label><p>只在自动模式下执行同一套有界选择。</p></div><select id="nf-selection-interval" value={draft.automation.selectionIntervalSeconds} disabled={!draft.automation.enabled} onChange={(event) => onChange({ ...draft, automation: { ...draft.automation, selectionIntervalSeconds: Number(event.target.value) } })}><option value={900}>15 分钟</option><option value={1800}>30 分钟</option><option value={3600}>1 小时</option><option value={7200}>2 小时</option></select></div>
      <div className="nf-form-row"><div><label>定期更新订阅</label></div><label className="nf-switch"><input type="checkbox" checked={draft.automation.subscriptionRefreshEnabled} onChange={(event) => onChange({ ...draft, automation: { ...draft.automation, subscriptionRefreshEnabled: event.target.checked } })} /><span aria-hidden="true" /><b>{draft.automation.subscriptionRefreshEnabled ? '已开启' : '已关闭'}</b></label></div>
      <div className="nf-form-row"><div><label htmlFor="nf-refresh-interval">订阅更新周期</label><p>只有内容摘要变化时才重新生成和选优。</p></div><select id="nf-refresh-interval" value={draft.automation.subscriptionRefreshIntervalSeconds} disabled={!draft.automation.subscriptionRefreshEnabled} onChange={(event) => onChange({ ...draft, automation: { ...draft.automation, subscriptionRefreshIntervalSeconds: Number(event.target.value) } })}><option value={21600}>6 小时</option><option value={43200}>12 小时</option><option value={86400}>24 小时</option></select></div>
    </div>
  </section>;
}

export function SafetySection({ draft, onChange }: SectionProps) {
  return <section className="nf-config-section">
    <SectionHeading title="安全与恢复" description="默认值适合日常使用；只有明确需要时才调整高级门槛和检查地址。" />
    <div className="nf-safety-summary">
      <ShieldCheck aria-hidden="true" /><div><strong>优先恢复：{draft.recoveryProfile.displayName} 原生配置</strong><p>只有原生配置恢复失败时，最终退路才是停止 {draft.backendDisplayName} 并恢复网络直通。</p></div>
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
  { id: 'network' as const, label: '网络接入', icon: Waypoints },
  { id: 'providers' as const, label: '机场', icon: RefreshCw },
  { id: 'regions' as const, label: '地区映射', icon: CheckCircle2 },
  { id: 'exits' as const, label: '出口策略', icon: Gauge },
  { id: 'routing' as const, label: '业务规则', icon: Route },
  { id: 'automation' as const, label: '自动运行', icon: RefreshCw },
  { id: 'safety' as const, label: '安全与恢复', icon: ShieldCheck },
  { id: 'compatibility' as const, label: 'HTTPS 兼容', icon: ShieldCheck },
  { id: 'files' as const, label: '配置文件与备份', icon: Files },
];
