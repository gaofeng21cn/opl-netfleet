import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, it } from 'vitest';
import { fixtureScenarios } from '../data/fixtures';
import { OverviewDigest } from './OverviewDigest';
import { OverviewExitSummary } from './OverviewExitSummary';
import { ProviderTable, RegionTable } from '../views/Tables';

describe('概览信息层级', () => {
  it('出口摘要只显示态势，不复制出口页诊断内容', () => {
    const html = renderToStaticMarkup(
      <OverviewExitSummary snapshot={fixtureScenarios.healthy.status} onOpen={() => undefined} />,
    );

    expect(html).toContain('出口态势');
    expect(html).toContain('Alpha 正式机场');
    expect(html).toContain('JP 日本');
    expect(html).toContain('78 ms');
    expect(html).not.toContain('JP-Tokyo-02');
    expect(html).not.toContain('运行时网络退路');
    expect(html).not.toContain('保护探针');
  });

  it('机场、地区和最近决策显示可行动的具体内容', () => {
    const html = renderToStaticMarkup(
      <OverviewDigest
        status={fixtureScenarios.healthy.status}
        events={fixtureScenarios.healthy.events}
        onOpen={() => undefined}
      />,
    );

    expect(html).toContain('机场态势');
    expect(html).toContain('Alpha 正式机场 · 78 ms');
    expect(html).toContain('Alpha 正式机场 · 84 ms');
    expect(html).toContain('地区态势');
    expect(html).toContain('JP 日本 · 78 ms');
    expect(html).toContain('JP 日本 · 84 ms');
    expect(html).toContain('AI 出口');
    expect(html).toContain('SG 新加坡 / Beta 高级机场 / SG-Singapore-01');
    expect(html).toContain('同轮最快合格候选');
    expect(html).not.toContain('需要关注');
  });

  it('只有异常时才显示需要关注区域', () => {
    const html = renderToStaticMarkup(
      <OverviewDigest
        status={fixtureScenarios.degraded.status}
        events={fixtureScenarios.degraded.events}
        onOpen={() => undefined}
      />,
    );

    expect(html).toContain('需要关注');
    expect(html).toContain('不可用机场：Alpha 正式机场');
  });

  it('未接管时把实时状态显示为未测量而不是机场下线', () => {
    const status = structuredClone(fixtureScenarios.degraded.status);
    status.active = false;
    status.runtime.netfleet_present = false;

    const html = renderToStaticMarkup(
      <OverviewDigest status={status} events={fixtureScenarios.degraded.events} onOpen={() => undefined} />,
    );
    const providers = renderToStaticMarkup(<ProviderTable snapshot={status} full />);

    expect(html).toContain('NetFleet 当前未接管，机场和地区的实时可用性未测量');
    expect(html).toContain('未测量<small> NetFleet 未接管</small>');
    expect(html).not.toContain('不可用机场：');
    expect(providers).toContain('NetFleet 当前未接管，实时可用性未测量');
    expect(providers).toContain('<span>未测量</span>');
    expect(providers).not.toContain('<td>0 /');
  });

  it('机场页聚合订阅状态和运行质量，诊断信息默认折叠', () => {
    const html = renderToStaticMarkup(<ProviderTable snapshot={fixtureScenarios.healthy.status} full />);

    expect(html).toContain('3 / 3 正常');
    expect(html).toContain('每行汇总订阅状态和运行质量');
    expect(html).toContain('<th>定位</th>');
    expect(html).toContain('<th>可用资源</th>');
    expect(html).toContain('<th>订阅状态</th>');
    expect(html).toContain('42/46 节点 · 订阅 48 条');
    expect(html).not.toContain('18/20 节点');
    expect(html).toContain('缓存已更新');
    expect(html).not.toContain('更新完成并已重载</td>');
    expect(html).toContain('缓存版本');
    expect(html).toContain('hidden=""');
    expect(html).not.toContain('<h2>订阅缓存</h2>');
    expect(html).toContain('管理机场订阅');
    expect(html).toContain('/cgi-bin/luci/admin/services/nikki/profile');
  });

  it('尚未运行订阅更新时不把空时间显示成数据缺失', () => {
    const status = structuredClone(fixtureScenarios.healthy.status);
    status.subscription_refresh!.last_run_at = null;
    status.subscriptions![0].last_attempt = null;
    status.subscriptions![0].last_success = null;

    const html = renderToStaticMarkup(<ProviderTable snapshot={status} full />);

    expect(html).toContain('<dt>最近执行</dt><dd>尚未执行</dd>');
    expect(html).toContain('<dt>最近尝试</dt><dd>尚未执行</dd>');
    expect(html).toContain('<dt>订阅更新时间</dt><dd>尚未执行</dd>');
  });

  it('机场与订阅只通过明确绑定聚合，不按显示名猜测', () => {
    const status = structuredClone(fixtureScenarios.healthy.status);
    status.providers[0].subscription_section = 'missing';
    status.subscriptions![0].display_name = status.providers[0].display_name;

    const html = renderToStaticMarkup(<ProviderTable snapshot={status} full />);

    expect(html).toContain('未提供');
    expect(html).not.toContain('aaaaaaaaaaaa');
  });

  it('零路径目录项不进入当前地区规划或首页警告', () => {
    const status = structuredClone(fixtureScenarios.healthy.status);
    status.regions.push({
      id: 'switzerland', display_name: '🇨🇭 瑞士', mode: 'automatic',
      available_provider_count: 0, provider_count: 1, available_node_count: 0, node_count: 1,
      last_best_delay_ms: null, average_best_delay_ms: null, delay_sample_count: 0,
    });

    const overview = renderToStaticMarkup(
      <OverviewDigest status={status} events={fixtureScenarios.healthy.events} onOpen={() => undefined} />,
    );
    const regions = renderToStaticMarkup(<RegionTable snapshot={status} full />);

    expect(overview).toContain('5<small> 个当前可用</small>');
    expect(overview).not.toContain('CH 瑞士');
    expect(overview).not.toContain('不可用地区');
    expect(regions).toContain('当前 5 个地区有真实可用路径');
    expect(regions).not.toContain('CH 瑞士');
  });

  it('当前使用地区失去路径时仍作为运行异常提示', () => {
    const status = structuredClone(fixtureScenarios.healthy.status);
    status.regions[0].available_provider_count = 0;
    status.regions[0].available_node_count = 0;

    const html = renderToStaticMarkup(
      <OverviewDigest status={status} events={fixtureScenarios.healthy.events} onOpen={() => undefined} />,
    );

    expect(html).toContain('需要关注');
    expect(html).toContain('当前使用地区已无可用路径：JP 日本');
  });
});
