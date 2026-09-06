import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, it } from 'vitest';
import { fixtureScenarios } from '../data/fixtures';
import type { DeviceConfigSnapshot } from '../types';
import { ConfigView } from './ConfigView';
import { ProvidersSection, SafetySection } from './ConfigSections';
import { configSummary, createConfigDraft, validateConfigDraft, validCidr } from './model';

describe('本地配置参考模型', () => {
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
