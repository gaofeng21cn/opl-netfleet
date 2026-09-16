import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';

// 控件规范：按钮、输入框、下拉和文本域的形状只在共享样式表的规范块里定义。
// 上下文规则再画一次边框就会出现双层边框，再声明一次高度就会让同一页出现多种控件尺寸，
// 所以这里只断言可机械证明的事实：边框只有一个来源，组合控件内部归零，圆角只取 token。
const shared = readFileSync(new URL('./styles.css', import.meta.url), 'utf8');
const desktop = readFileSync(new URL('./desktop/desktop.css', import.meta.url), 'utf8');

const rules = (css: string) => [...css.matchAll(/([^{}]+)\{([^{}]*)\}/g)]
  .map(([, selector, body]) => ({ selector: selector.trim().split('\n').pop()!.trim(), body }));
const all = () => [...rules(shared), ...rules(desktop)];
const field = /(^|[\s,>~+])(input|select|textarea)(?![\w-])/;
const drawsBorder = (body: string) => [...body.matchAll(/border(?:-(?:top|bottom|left|right))?:\s*([^;]+)/g)]
  .some(([, value]) => !/^\s*(0|none)\b/.test(value));

describe('控件规范', () => {
  it('表单控件的边框只在规范块一处绘制', () => {
    const painted = all().filter((rule) => field.test(rule.selector) && drawsBorder(rule.body));
    expect(painted.map((rule) => rule.selector)).toEqual([
      '.nf-app :where(input, select, textarea):where(:not([type="checkbox"]):not([type="radio"]):not([type="range"]):not([type="file"]))',
    ]);
    expect(painted[0].body).toContain('var(--nf-border)');
    expect(painted[0].body).toContain('min-height: var(--nf-control-height)');
    expect(painted[0].body).toContain('border-radius: var(--nf-radius-control)');
  });

  it('组合控件整体只有一个边框，内部输入归零', () => {
    const composite = ['.nf-search > input', '.nf-number-field input'];
    for (const selector of composite) {
      const rule = all().find((item) => item.selector === selector);
      expect(rule, `${selector} 应显式归零内部边框`).toBeDefined();
      expect(rule!.body, `${selector} 不能再画边框`).toMatch(/border:\s*0\s*;/);
      expect(rule!.body, `${selector} 不能再占高度`).toMatch(/min-height:\s*0\s*;/);
    }
    const wrapper = all().find((rule) => rule.selector === '.nf-search');
    expect(wrapper?.body).toContain('height: var(--nf-control-height)');
    expect(drawsBorder(wrapper?.body ?? '')).toBe(true);
  });

  it('圆角只取 token，不再出现中间值', () => {
    const literals = [...shared.matchAll(/border-radius:\s*([^;]+)/g), ...desktop.matchAll(/border-radius:\s*([^;]+)/g)]
      .map(([, value]) => value.trim())
      .filter((value) => /\d+px/.test(value) && !value.startsWith('var('));
    expect(literals).toEqual([]);
    expect([...shared.matchAll(/--nf-radius-[\w-]+:\s*(\d+px)/g)].map(([, value]) => value).sort())
      .toEqual(['2px', '6px', '8px', '999px']);
  });

  it('两个平台只覆盖密度，形状 token 保持一致', () => {
    const token = (css: string, name: string) => css.match(new RegExp(`--${name}:\\s*([^;]+);`))?.[1].trim();
    expect(token(desktop, 'nf-radius-control')).toBe(token(shared, 'nf-radius-control'));
    expect(token(desktop, 'nf-radius-surface')).toBe(token(shared, 'nf-radius-surface'));
    expect(token(desktop, 'nf-control-height')).toBe('32px');
    expect(token(shared, 'nf-control-height')).toBe('38px');
    // 下拉自绘箭头，才能和输入框共用同一高度、圆角与边框。
    expect(shared).toMatch(/\.nf-app select \{[^}]*appearance: none/);
  });
});
