import { renderToStaticMarkup } from 'react-dom/server';
import { expect, it } from 'vitest';
import { StatusStrip } from './StatusStrip';
import type { StatusSnapshot } from '../types';

it('distinguishes configured interception, readiness, missing evidence and stopped backend', () => {
  const runtime: StatusSnapshot['runtime'] = { backend_enabled: true, mihomo_running: true, controller_available: true,
    lan_runtime: { lan_proxy_enabled: false, dns_hijack_enabled: true, transparent_proxy_ready: true, dns_ready: false } };
  const render = () => renderToStaticMarkup(<StatusStrip snapshot={{ runtime } as StatusSnapshot} />);
  expect(render()).toContain('LAN 透明代理</dt><dd>未启用');
  expect(render()).toContain('DNS 接管</dt><dd>已启用 · 异常');
  runtime.lan_runtime!.lan_proxy_enabled = true;
  expect(render()).toContain('LAN 透明代理</dt><dd>已启用 · 正常');
  delete runtime.lan_runtime!.lan_proxy_enabled;
  expect(render()).toContain('LAN 透明代理</dt><dd>状态未确认');
  runtime.backend_enabled = false; runtime.mihomo_running = false;
  expect(render()).toContain('DNS 接管</dt><dd>未启用');
  expect(render()).toContain('控制接口</dt><dd>未运行');
});
