import { renderToStaticMarkup } from 'react-dom/server';
import { expect, it } from 'vitest';
import { fixtureScenarios } from '../data/fixtures';
import { RegionTable } from './Tables';

it('keeps the failed latest round separate from historical latency', () => {
  const snapshot = structuredClone(fixtureScenarios.healthy.status);
  const region = snapshot.regions.find(item => item.id === 'singapore')!;
  region.last_best_delay_ms = 39;
  region.measurement = { sampled_at: 1788853151, best_delay_ms: null, measured_count: 0, exclusions: { latency_health_failed: 1 } };
  const html = renderToStaticMarkup(<RegionTable snapshot={snapshot} />);
  expect(html).toContain('未取得有效测速');
  expect(html).toContain('未取得候选线路的测速成功记录；旧记录未保留细节：1 项');
  expect(html).toContain('39 ms');
  region.measurement = { sampled_at: 1788853251, best_delay_ms: 54, measured_count: 1, exclusions: {} };
  const recovered = renderToStaticMarkup(<RegionTable snapshot={snapshot} />);
  expect(recovered).toContain('54 ms');
  expect(recovered).not.toContain('未取得有效测速');
});

it('shows successful results alongside quota exclusions and names every candidate', () => {
  const snapshot = structuredClone(fixtureScenarios.healthy.status);
  const region = snapshot.regions.find(item => item.id === 'singapore')!;
  const provider = snapshot.providers[0];
  region.measurement = { sampled_at: 1788853251, best_delay_ms: 41, measured_count: 1, exclusions: { quota_exhausted: 2 }, entries: [
    { provider_id: provider.id, region_id: region.id, ok: true, delay_ms: 41, quota_state: 'available', reason: null, measurement_reason: null },
    { provider_id: 'exhausted-provider', region_id: region.id, ok: false, delay_ms: null, quota_state: 'exhausted', reason: 'quota_exhausted', measurement_reason: 'leaf_latency_unrecorded' },
  ] };
  const html = renderToStaticMarkup(<RegionTable snapshot={snapshot} />);
  expect(html).toContain('1 项测速成功');
  expect(html).toContain('2 项流量耗尽');
  expect(html).toContain('41 ms');
  expect(html).toContain('采样于');
  expect(html).toContain('exhausted-provider');
  expect(html).toContain('所选节点缺少该测速目标的健康记录');
  expect(html).toContain('流量已耗尽，不参与选优');
  expect(html).toContain('<details><summary>查看测速详情');
  expect(html).not.toContain('未通过');
});
