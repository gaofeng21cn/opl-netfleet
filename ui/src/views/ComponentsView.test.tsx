import { renderToStaticMarkup } from 'react-dom/server';
import { expect, it } from 'vitest';
import { ComponentsView } from './ComponentsView';
import type { ComponentsSnapshot, DashboardComponent } from '../types';

const dashboard: DashboardComponent = { id: 'zashboard', label: 'Zashboard', installed_version: null, available_version: null, available: true, managed: true, update_available: false, checked_at: null, error: null, reason: null, release_url: null };
function snapshot(): ComponentsSnapshot {
  const common = { installed_version: '1.0.0-r1', running_version: null, available_version: null, update_available: false, managed: true, reason: null };
  return { supported: true, backend: 'native-mihomo', architecture: 'aarch64', feed: { configured: true, url: 'https://packages.example/packages.adb', checked_at: null, error: null },
    components: [{ ...common, id: 'netfleet', label: 'NetFleet' }, { ...common, id: 'luci', label: 'LuCI 界面' }, { ...common, id: 'mihomo', label: 'Mihomo', installed_version: '1.19.29', running_version: 'v1.19.30', available_version: '1.19.30-r1', update_available: true }],
    dependencies: [{ id: 'curl', label: 'curl', installed_version: '8.0', available: true }], dashboard: { ...dashboard } };
}
const render = (value: ComponentsSnapshot) => renderToStaticMarkup(<ComponentsView snapshot={value} operation={null} error={null} operationError={null} loading={false} onRead={() => {}} />);

it('distinguishes installed unversioned Zashboard resources from an absent installation', () => {
  const html = render(snapshot());
  expect(html).toContain('版本未记录');
  expect(html).toContain('可使用');
  expect(html).toContain('本机预览只读');
  expect(html).not.toContain('>未安装<');
  const missing = render({ ...snapshot(), dashboard: { ...dashboard, available: false } });
  expect(missing).toContain('未安装');
  expect(missing).not.toContain('版本未记录');
});

it('groups the paired packages and shows core version mismatch without guessing an upgrade', () => {
  const value = snapshot();
  const html = render(value);
  expect(html.match(/<tr>/g)).toHaveLength(4);
  expect(html).toContain('随 NetFleet 更新');
  expect(html).toContain('运行版本与安装记录不一致');
  expect(html).toContain('更新软件包');
  expect(html).not.toContain('不适用');
  expect(html).not.toContain('未提供');
  value.components[2].installed_version = '1.19.30-r1';
  expect(render(value)).not.toContain('运行版本与安装记录不一致');
  value.components[1].installed_version = '0.9.0-r1';
  expect(render(value)).toContain('NetFleet 与 LuCI 安装版本不一致');
  value.components[0].available_version = '1.0.0-r1';
  value.components[1].available_version = '1.0.0-r1';
  value.components[1].update_available = true;
  expect(render(value)).toContain('候选版本 1.0.0-r1');
});

it('does not mistake a missing unpacker for externally managed dashboard resources', () => {
  const html = render({ ...snapshot(), dashboard: { ...dashboard, managed: false, reason: 'dashboard_unpacker_unavailable' } });
  expect(html).toContain('请安装 unzip');
  expect(html).not.toContain('由 Nikki 管理');
});

it('keeps checks neutral, separates source failures and folds healthy dependencies', () => {
  const value = snapshot();
  expect(render(value).match(/尚未检查更新/g)).toHaveLength(2);
  expect(render(value)).toContain('运行依赖正常');
  expect(render(value)).not.toContain('<details class="nf-component-details nf-components-dependencies" open');
  value.feed.error = 'feed_check_failed';
  value.dashboard = { ...dashboard, checked_at: 100, installed_version: 'v3.0.0', available_version: 'v3.0.0' };
  let html = render(value);
  expect(html).toContain('软件包检查失败');
  expect(html).toContain('当前更新源暂无新版');
  expect(html).not.toContain('更新软件包');
  value.dependencies[0].available = false;
  html = render(value);
  expect(html).toContain('缺少 1 项运行依赖');
  expect(html).toContain('open=""');
});
