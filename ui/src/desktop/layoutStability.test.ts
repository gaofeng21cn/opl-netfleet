import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';

// The desktop client keeps one page structure at every supported window width:
// narrower windows shorten, truncate, or move surplus fields into the detail
// pane. Width-based breakpoints here would silently re-architect the page.
const css = readFileSync(new URL('./desktop.css', import.meta.url), 'utf8');
const tables = readFileSync(new URL('../views/Tables.tsx', import.meta.url), 'utf8');
const events = readFileSync(new URL('../views/EventsView.tsx', import.meta.url), 'utf8');

const rules = [...css.matchAll(/([^{}]+)\{([^{}]*)\}/g)].map(([, selector, body]) => ({ selector: selector.trim(), body }));

describe('桌面布局稳定性', () => {
  it('桌面样式不用窗口宽度改写页面结构', () => {
    expect(css.match(/@(?:media|container)[^{]*\((?:max|min)-(?:width|inline-size)[^)]*\)/g) ?? []).toEqual([]);
  });
  it('桌面不靠横向滚动适配窗口，表格不设最小宽度', () => {
    const widened = rules.filter(rule => /table|nf-table-wrap/.test(rule.selector)
      && [...rule.body.matchAll(/min-width:\s*([^;]+)/g)]
        .some(([, value]) => Number.parseFloat(value) > 0));
    expect(widened).toEqual([]);
  });
  it('列预算按语义标识隐藏，不使用位置序号', () => {
    expect(css).toContain('.nf-col-role');
    expect(css).toContain('.nf-col-expiry');
    expect(rules.filter(rule => /nth-child\(/.test(rule.selector) && /display:\s*none/.test(rule.body))).toEqual([]);
    expect(tables).toContain('className="nf-col-role"');
    expect(tables).toContain('className="nf-col-expiry"');
  });
  it('长文本列在桌面换行，不撑出横向滚动', () => {
    expect(css).toContain('.nf-col-wide');
    expect(events).toContain('nf-col-wide');
  });
});
