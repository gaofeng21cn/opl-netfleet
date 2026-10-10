import { renderToStaticMarkup } from 'react-dom/server';
import { Children, isValidElement, type ReactNode } from 'react';
import { describe, expect, it } from 'vitest';
import { fixtureScenarios } from '../data/fixtures';
import type { DeviceConfigSnapshot } from '../types';
import { ConfigView } from './ConfigView';
import { FoundationSection, ProvidersSection, SafetySection } from './ConfigSections';
import { configChanges, configSummary, createConfigDraft, validateConfigDraft, validCidr } from './model';
import { desktopConfigRequest } from '../desktop/policy';

function inputIn(node: ReactNode, id: string): { onChange?: (event: { target: { value: string } }) => void } | undefined {
  if (!isValidElement<{ id?: string; children?: ReactNode; onChange?: (event: { target: { value: string } }) => void }>(node)) return undefined;
  if (node.type === 'input' && node.props.id === id) return node.props;
  let found;
  Children.forEach(node.props.children, child => { found ??= inputIn(child, id); });
  return found;
}

describe('本地配置参考模型', () => {
  it('策略基础下拉使用设备候选及真实选中值', () => {
    const status = fixtureScenarios.healthy.status;
    const draft = createConfigDraft(status);
    draft.policySourceOptions = [{ kind: 'profile', ref: 'file:custom.json', displayName: '自定义配置' }];
    draft.policySource = draft.policySourceOptions[0];
    const html = renderToStaticMarkup(<FoundationSection status={status} draft={draft} onChange={() => undefined} />);
    expect(html).toContain('<select id="nf-policy-source">');
    expect(html).toContain('<option value="profile|file:custom.json" selected="">自定义配置</option>');
    expect(html).not.toContain('name="policy-source"');
  });
  it('变更预览区分新增、删除、修改以及同数量规则替换', () => {
    const before = createConfigDraft(fixtureScenarios.healthy.status);
    expect(configChanges(before, structuredClone(before))).toEqual([]);
    before.routingRules = [{ kind: 'domain_suffix', value: 'old.example', target: 'direct' }];
    const after = structuredClone(before);
    const removed = after.providers.pop()!;
    after.providers[0].role = 'reserve';
    after.regions.push({ id: 'new', displayName: '新地区', mode: 'manual_only' });
    after.automation.subscriptionRefreshEnabled = !before.automation.subscriptionRefreshEnabled;
    after.routingRules[0].value = 'new.example';
    expect(configChanges(before, after)).toEqual(expect.arrayContaining([
      `移除机场：${removed.displayName}`, `修改机场：${before.providers[0].displayName}`, '新增地区：新地区',
      '自动运行周期已修改', '业务规则已修改：1 条 → 1 条',
    ]));
  });
  it('原生后端投影保留真实后端身份，不再提供 Nikki 订阅入口', () => {
    const status = structuredClone(fixtureScenarios.nativeInactive.status);
    const draft = createConfigDraft(status);
    expect(draft.backend).toBe('native-mihomo');
    expect(draft.backendDisplayName).toBe('NetFleet + Mihomo');
    const props = { status, draft, onChange: () => undefined };
    const providers = renderToStaticMarkup(<ProvidersSection {...props} />);
    expect(providers).toContain('管理订阅');
    expect(providers).not.toContain('/services/nikki');
    expect(renderToStaticMarkup(<SafetySection {...props} />)).toContain('NetFleet + Mihomo');
  });
  it('只从当前 status 初始化机场、地区和出口资源', () => {
    const status = structuredClone(fixtureScenarios.healthy.status);
    status.regions.push({
      id: 'switzerland',
      display_name: 'CH 瑞士',
      available_provider_count: 0,
      available_node_count: 0,
      mode: 'automatic',
    }, {
      id: 'detached',
      display_name: 'ZZ 未关联地区',
      available_provider_count: 0,
      available_node_count: 1,
      mode: 'automatic',
    }, {
      id: 'paths-only',
      display_name: 'XX 路径可用',
      available_count: 2,
      available_provider_count: 1,
      available_node_count: null,
      mode: 'automatic',
    });
    const draft = createConfigDraft(status);

    expect(draft.providers.map((item) => item.displayName)).toEqual([
      'Alpha 正式机场', 'Beta 高级机场', 'Gamma 备用机场',
    ]);
    expect(draft.regions.map((item) => item.id)).not.toContain('switzerland');
    expect(draft.regions.map((item) => item.id)).not.toContain('detached');
    expect(draft.regions.map((item) => item.id)).toContain('paths-only');
    expect(draft.regions.find((item) => item.id === 'paths-only')).toMatchObject({ availablePaths: 2, availableNodes: null });
    expect(draft.regions).toHaveLength(status.regions.length - 2);
    expect(draft.capabilities.map((item) => item.displayName)).toEqual(['海外加速', 'AI 出口']);
    expect(draft.capabilities[1].regionIds).not.toContain('hong_kong');
    expect(configSummary(draft)).toMatchObject({ providerCount: 3, primaryCount: 2, reserveCount: 1, capabilityCount: 2 });
  });

  it('拦截没有主用机场和没有启用出口的草稿', () => {
    const draft = createConfigDraft(fixtureScenarios.healthy.status);
    draft.providers = draft.providers.map((provider) => ({ ...provider, role: 'reserve' }));
    draft.capabilities = draft.capabilities.map((capability) => ({ ...capability, enabled: false }));

    expect(validateConfigDraft(draft)).toEqual(expect.arrayContaining([
      '至少需要一个主用机场。',
      '至少启用一个出口能力。',
    ]));
  });

  it('优先使用设备 config projection，不从运行状态猜映射和绑定', () => {
    const status = structuredClone(fixtureScenarios.healthy.status);
    const config: DeviceConfigSnapshot = {
      revision: 'a'.repeat(64), active: true, pending_apply: false,
      backend: { id: 'nikki-mihomo', display_name: 'Nikki + Mihomo' },
      policy_source: { kind: 'bundle', ref: 'bundle:base-v1', display_name: 'NetFleet 内置基础策略' },
      policy_source_options: [{ kind: 'bundle', ref: 'bundle:base-v1', display_name: 'NetFleet 内置基础策略' }],
      policy_groups: ['OUTBOUND', 'AI'],
      recovery_profile: { ref: 'subscription:recovery', display_name: '示例恢复配置' },
      recovery_profile_options: [{ ref: 'subscription:recovery', display_name: '示例恢复配置' }],
      providers: [{ id: 'alpha', section: 'alpha-source', display_name: 'Alpha 正式机场', enabled: true, role: 'primary', billing: 'subscription', region_ids: ['japan'] }],
      provider_options: [{ id: 'alpha', section: 'alpha-source', display_name: 'Alpha 正式机场', region_ids: ['japan', 'singapore'] }],
      regions: [{ id: 'japan', flag: 'JP', display_name: '日本', display_order: 10, mode: 'automatic' }],
      region_options: [
        { id: 'japan', code: 'JP', display_name: '日本', display_order: 10 },
        { id: 'singapore', code: 'SG', display_name: '新加坡', display_order: 20 },
      ],
      capabilities: [{ id: 'standard', display_name: '海外加速', enabled: true, mode: 'automatic', region_ids: ['japan'], prefer_region_from: null, entry_group: 'OUTBOUND', policy_groups: [], base_groups: ['OUTBOUND'] }],
      routing_rules: [{ kind: 'domain_suffix', value: 'example.com', capability: 'standard' }],
      automation: { enabled: true, selection_interval_seconds: 1800, subscription_refresh_enabled: true, subscription_refresh_interval_seconds: 43200 },
      safety: { region_switch_margin_ms: 150, leaf_switch_margin_ms: 150, runtime_grace_seconds: 45, latency_url: 'https://latency.invalid', path_probe_url: 'https://path.invalid', guard_probe_url: 'https://guard.invalid' },
    };

    const draft = createConfigDraft(status, config);
    expect(draft.providers).toHaveLength(1);
    expect(draft.providers[0].section).toBe('alpha-source');
    expect(draft.providers[0].regionIds).toEqual(['japan']);
    expect(draft.regions.map((item) => item.id)).toEqual(['japan']);
    expect(draft.capabilities[0]).toMatchObject({ entryGroup: 'OUTBOUND', policyGroups: [] });
    expect(draft.routingRules).toEqual([{ kind: 'domain_suffix', value: 'example.com', capability: 'standard' }]);
    expect(desktopConfigRequest(config, draft).safety).toMatchObject({ path_probe_url: 'https://path.invalid', guard_probe_url: 'https://guard.invalid', runtime_grace_seconds: 45 });
    const untouched = structuredClone(draft);
    const distinctForm = SafetySection({ status, draft, onChange: next => Object.assign(draft, next) });
    inputIn(distinctForm, 'nf-path-probe-url')!.onChange!({ target: { value: 'https://new-path.invalid' } });
    expect(desktopConfigRequest(config, draft).safety).toMatchObject({ path_probe_url: 'https://new-path.invalid', guard_probe_url: 'https://guard.invalid' });
    inputIn(SafetySection({ status, draft, onChange: next => Object.assign(draft, next) }), 'nf-guard-probe-url')!.onChange!({ target: { value: 'https://new-guard.invalid' } });
    expect(desktopConfigRequest(config, draft).safety).toMatchObject({ path_probe_url: 'https://new-path.invalid', guard_probe_url: 'https://new-guard.invalid' });
    const sharedConfig = { ...config, health_probes_shared: true, safety: { ...config.safety, guard_probe_url: config.safety.path_probe_url } };
    const sharedDraft = createConfigDraft(status, sharedConfig);
    const sharedForm = SafetySection({ status, draft: sharedDraft, onChange: next => Object.assign(sharedDraft, next) });
    expect(inputIn(sharedForm, 'nf-guard-probe-url')).toBeUndefined();
    inputIn(sharedForm, 'nf-path-probe-url')!.onChange!({ target: { value: 'https://shared.invalid' } });
    expect(desktopConfigRequest(sharedConfig, sharedDraft).safety).toMatchObject({ path_probe_url: 'https://shared.invalid', guard_probe_url: 'https://shared.invalid' });
    const formHtml = renderToStaticMarkup(<SafetySection status={status} draft={untouched} onChange={() => undefined} />);
    expect(formHtml).toContain('id="nf-runtime-grace" type="number" min="15" max="300" value="45"');
  });

  it('保留零切换门槛，并校验运行失联保护的实际秒数', () => {
    const status = structuredClone(fixtureScenarios.healthy.status);
    status.selection!.region_switch_margin_ms = 0;
    status.selection!.leaf_switch_margin_ms = 0;
    const draft = createConfigDraft(status);
    expect(draft.safety.regionSwitchMarginMs).toBe(0);
    expect(draft.safety.leafSwitchMarginMs).toBe(0);
    for (const value of [14, 301, 45.5, NaN]) {
      draft.safety.runtimeGraceSeconds = value;
      expect(validateConfigDraft(draft)).toContain('运行失联保护必须为 15 至 300 秒。');
    }
    draft.safety.runtimeGraceSeconds = 45;
    expect(validateConfigDraft(draft)).not.toContain('运行失联保护必须为 15 至 300 秒。');
  });

  it('明确本地预览边界且不展示未实现后端选项', () => {
    const status = fixtureScenarios.healthy.status;
    const draft = createConfigDraft(status);
    const html = renderToStaticMarkup(<ConfigView
      draft={draft}
      savedDraft={draft}
      status={status}
      onChange={() => undefined}
      onSave={() => undefined}
    />);

    expect(html).toContain('本地配置交互预览');
    expect(html).toContain('不会写入设备');
    expect(html).toContain('基础接入');
    expect(html).toContain('网络接入');
    expect(html).toContain('配置文件与备份');
    expect(html).toContain('机场');
    expect(html).toContain('Nikki + Mihomo');
    expect(html).not.toContain('sing-box');
  });

  it('支持 IPv4/IPv6 网段及直连目标，并拒绝非法网段和双重目标', () => {
    expect(validCidr('203.0.113.0/24')).toBe(true);
    expect(validCidr('2001:db8::/32')).toBe(true);
    for (const value of ['999.0.0.0/24', '203.0.113.0/33', '2001:db8::/129', 'bad:address::/64', '203.0.113.1', '127.1/8']) expect(validCidr(value)).toBe(false);
    const draft = createConfigDraft(fixtureScenarios.healthy.status);
    draft.routingRules = [{ kind: 'ip_cidr', value: '2001:db8::/32', target: 'direct' }];
    expect(validateConfigDraft(draft).some(error => error.includes('规则'))).toBe(false);
    draft.routingRules[0].capability = draft.capabilities[0].id;
    expect(validateConfigDraft(draft)).toContain('每条规则需要选择一个有效出口或直连。');
  });
});
