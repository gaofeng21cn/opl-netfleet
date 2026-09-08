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
  expect(html).toContain('本轮无有效测速');
  expect(html).toContain('测速目标未通过 1 组');
  expect(html).toContain('39 ms');
  region.measurement = { sampled_at: 1788853251, best_delay_ms: 54, measured_count: 1, exclusions: {} };
  const recovered = renderToStaticMarkup(<RegionTable snapshot={snapshot} />);
  expect(recovered).toContain('54 ms');
  expect(recovered).not.toContain('本轮无有效测速');
});
