import { renderToStaticMarkup } from 'react-dom/server';
import { afterEach, expect, it, vi } from 'vitest';
import { ResultNotice } from './ResultNotice';

afterEach(() => vi.unstubAllGlobals());

it('isolates dismissed identities by target and operation type and shows new results', () => {
  vi.stubGlobal('sessionStorage', { getItem: (key: string) => key === 'netfleet:result:v1:target-a:subscription' ? 'operation-1' : null });
  const render = (scope: string, slot: string, identity: string) => renderToStaticMarkup(
    <ResultNotice scope={scope} slot={slot} identity={identity} title="订阅更新">已完成</ResultNotice>,
  );
  expect(render('target-a', 'subscription', 'operation-1')).toBe('');
  expect(render('target-a', 'subscription', 'operation-2')).toContain('关闭订阅更新结果');
  expect(render('target-b', 'subscription', 'operation-1')).toContain('已完成');
  expect(render('target-a', 'packages', 'operation-1')).toContain('已完成');
});

it('does not break the page when browser storage is unavailable', () => {
  vi.stubGlobal('sessionStorage', { getItem() { throw new Error('blocked'); } });
  expect(renderToStaticMarkup(<ResultNotice slot="subscription" identity="operation-1" title="订阅更新">已完成</ResultNotice>)).toContain('已完成');
});
