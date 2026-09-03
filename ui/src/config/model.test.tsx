import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, it } from 'vitest';
import { fixtureScenarios } from '../data/fixtures';
import { ConfigView } from './ConfigView';
import { configSummary, createConfigDraft, validateConfigDraft } from './model';

describe('本地配置参考模型', () => {
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
    });
    const draft = createConfigDraft(status);

    expect(draft.providers.map((item) => item.displayName)).toEqual([
      'Alpha 正式机场', 'Beta 高级机场', 'Gamma 备用机场',
    ]);
    expect(draft.regions.map((item) => item.id)).not.toContain('switzerland');
    expect(draft.regions.map((item) => item.id)).not.toContain('detached');
    expect(draft.regions).toHaveLength(status.regions.length - 2);
    expect(draft.capabilities.map((item) => item.displayName)).toEqual(['海外加速', 'AI 出口']);
    expect(draft.capabilities[1].excludedRegions).toEqual(['hong_kong']);
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
    expect(html).toContain('机场');
    expect(html).toContain('Nikki + Mihomo');
    expect(html).not.toContain('sing-box');
  });
});
