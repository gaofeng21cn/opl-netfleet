import { renderToStaticMarkup } from 'react-dom/server';
import { expect, it } from 'vitest';
import { DashboardComponentSection } from './ComponentsView';
import type { DashboardComponent } from '../types';

it('distinguishes installed unversioned Zashboard resources from an absent installation', () => {
  const dashboard: DashboardComponent = { id: 'zashboard', label: 'Zashboard', installed_version: null, available_version: null, available: true, managed: true, update_available: false, checked_at: null, error: null, reason: null, release_url: null };
  const html = renderToStaticMarkup(<DashboardComponentSection dashboard={dashboard} />);
  expect(html).toContain('版本未记录');
  expect(html).toContain('可使用');
  expect(html).toContain('本机预览只读');
  expect(html).not.toContain('>未安装<');
  const missing = renderToStaticMarkup(<DashboardComponentSection dashboard={{ ...dashboard, available: false }} />);
  expect(missing).toContain('未安装');
  expect(missing).not.toContain('版本未记录');
});
