import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { configSectionsFor, pageEntries, pagesFor } from './lib/vocabulary';

// 共享词汇表是页面名与配置分类名的唯一来源。React 直接引用它，设备页与插件清单仍是
// 字面量，所以这里只断言可机械证明的事实：设备页清单、页面标题映射和配置分类表
// 与同一份词汇表逐项一致；出现新名称或顺序漂移时失败。
const repo = new URL('../../', import.meta.url);
const read = (path: string) => readFileSync(new URL(path, repo), 'utf8');

const arrayLiteral = (source: string, start: string): string => {
  const at = source.indexOf(start);
  if (at < 0) throw new Error(`literal not found: ${start}`);
  const from = source.indexOf('[', at);
  let depth = 0;
  for (let index = from; index < source.length; index++) {
    if (source[index] === '[') depth++;
    else if (source[index] === ']' && --depth === 0) return source.slice(from, index + 1);
  }
  throw new Error(`unterminated literal: ${start}`);
};

describe('共享词汇表', () => {
  it('设备插件清单的页面顺序与页面名来自同一份词汇表', () => {
    const manifest = JSON.parse(read('plugins/product-ui/manifest.json')) as { ui: Array<{ id: string; title: string }> };
    expect(manifest.ui.map((page) => [page.id, page.title])).toEqual(pagesFor('openwrt').map((page) => [page.id, page.label]));
    expect(pagesFor('desktop').some((page) => page.id === 'components')).toBe(false);
  });

  it('设备页面的标题映射只使用词汇表里的名称', () => {
    const source = read('plugins/product-ui/resources/product-pages.js');
    const at = source.indexOf('const title = ({');
    const end = source.indexOf('})[this.currentView]', at);
    expect(at).toBeGreaterThan(-1);
    const body = source.slice(at + 'const title = ({'.length, end);
    const parsed = JSON.parse(`{${body}}`.replace(/([{,]\s*)([A-Za-z_][\w]*)\s*:/g, '$1"$2":').replace(/'/g, '"')) as Record<string, string>;
    expect(Object.entries(parsed)).toEqual(pageEntries.map((page) => [page.id, page.label]));
  });

  it('设备配置分类的标识、名称和顺序与词汇表一致', () => {
    const source = read('plugins/product-ui/resources/config.js');
    const literal = arrayLiteral(source, 'const SECTIONS =');
    const parsed = JSON.parse(literal.replace(/([{,[]\s*)'/g, '$1"').replace(/'(\s*[,\]])/g, '"$1')) as Array<[string, string]>;
    expect(parsed).toEqual(configSectionsFor('openwrt').map((section) => [section.id, section.label]));
    // 设备页用 'network' 作为“设备与文件”分组起点，它必须与词汇表的分组一致。
    expect(configSectionsFor('openwrt').find((section) => section.id === 'network')?.group).toBe('device');
    expect(source).toContain("item[0] === 'network'");
  });

  it('每个名称只出现一次，页面名与配置分类名不重名', () => {
    const overlap = pagesFor('openwrt').map((page) => page.label).filter((label) => configSectionsFor('openwrt').some((section) => section.label === label));
    expect(overlap).toEqual([]);
    const duplicated = pageEntries.map((page) => page.label).filter((label, index, all) => all.indexOf(label) !== index);
    expect(duplicated).toEqual([]);
  });
});
