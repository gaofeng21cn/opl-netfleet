import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, it } from 'vitest';
import { fixtureScenarios } from '../data/fixtures';
import { EventsView } from './EventsView';

describe('事件页阅读顺序', () => {
  it('事件优先、每页二十条，连接快照默认折叠', () => {
    const scenario = fixtureScenarios.healthy;
    const snapshot = structuredClone(scenario.events);
    snapshot.events = Array.from({ length: 21 }, (_, index) => ({ ...snapshot.events[0], at: index + 1 }));
    const html = renderToStaticMarkup(<EventsView snapshot={snapshot} status={scenario.status}
      connections={{ connections: [], count: 0, truncated: false }} connectionsLoading={false} />);
    expect(html.indexOf('选路事件')).toBeLessThan(html.indexOf('诊断状态'));
    expect(html).toContain('第 1 / 2 页，共 21 条');
    expect(html).toContain('<details class="nf-connection-details">');
    const eventTable = html.slice(html.indexOf('<tbody>'), html.indexOf('</tbody>'));
    expect(eventTable.match(/<tr>/g)).toHaveLength(20);
  });
});
