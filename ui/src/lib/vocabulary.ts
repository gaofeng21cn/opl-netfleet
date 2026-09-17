import data from './vocabulary.json';

// 共享词汇表：页面标题、导航与配置分类名称只有这一份来源。
// OpenWrt 设备页与 macOS/参考 React 面各自渲染，但同一对象始终使用同一名称；
// React 直接引用本模块，设备页字面量由 ui/src/vocabulary.test.ts 机械核对。
export type VocabularySurface = 'openwrt' | 'reference' | 'desktop';

type PageEntry = { id: string; label: string; desktop?: boolean };
type SectionEntry = {
  key: string;
  label: string;
  group: SectionGroup;
  desktop?: boolean;
  openwrt?: boolean;
  reference?: boolean;
  openwrtId?: string;
  desktopId?: string;
};

export type SectionGroup = 'strategy' | 'device';

const pages = data.pages as PageEntry[];
const sections = data.configSections as SectionEntry[];
const visible = (entry: { openwrt?: boolean; reference?: boolean; desktop?: boolean }, surface: VocabularySurface) => entry[surface] !== false;

export const pageEntries = pages;
export const configSectionEntries = sections;

export const pageLabel = (id: string) => pages.find((page) => page.id === id)?.label || id;

export const pagesFor = (surface: VocabularySurface) => pages
  .filter((page) => visible(page, surface))
  .map((page) => ({ id: page.id, label: page.label }));

export type ConfigSection = { key: string; id: string; label: string; group: SectionGroup };

export const configSectionsFor = (surface: VocabularySurface): ConfigSection[] => sections
  .filter((section) => visible(section, surface))
  .map((section) => ({
    key: section.key,
    id: surface === 'openwrt' ? section.openwrtId || section.key : surface === 'desktop' ? section.desktopId || section.key : section.key,
    label: section.label,
    group: section.group,
  }));

export const configSectionLabel = (key: string) => sections.find((section) => section.key === key)?.label || key;

export const sectionGroupLabels: Record<SectionGroup, string> = { strategy: '运行策略', device: '设备与文件' };
