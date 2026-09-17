import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, it } from 'vitest';
import { CoreSection } from './CoreSection';
import type { DesktopSnapshot } from './types';

const snapshot = (patch: Partial<DesktopSnapshot['core']> = {}): DesktopSnapshot => ({
  runtime: { platform: 'macos', running: true, configured: true, mode: 'netfleet', requestedMode: 'netfleet', networkMode: 'tun', ports: { mixed: 17890, controller: 17891, dns: 17892 }, controllerReady: true, clean: false, pid: 42, version: '1.19.30', lastError: null },
  policy: null, subscriptions: {}, status: null, events: null, config: null, configError: null, network: { clean: false }, error: null,
  core: {
    profile: 'file:OPL-NetFleet.json', mode: 'tun', running: true, overlay: true,
    rows: [
      { id: 'dns.enable', group: 'DNS', label: 'DNS 接管', source: 'platform', configured: '开启', declared: null, running: null },
      { id: 'log-level', group: '核心', label: '核心日志级别', source: 'platform', configured: 'warning', declared: 'info', running: 'warning' },
      { id: 'tun.device', group: 'TUN 会话', label: '虚拟网卡', source: 'platform', configured: 'utun198', declared: null, running: 'utun198' },
    ],
    components: [{ id: 'mihomo', label: 'Mihomo 核心', version: '1.19.30', source: 'runtime' },
      { id: 'ucode', label: 'UCode', version: '64cf18aa55c67e73b9acd0262a44d50b41774ed8', source: 'package' }],
    identity: { version: '0.2.0', release: '8', channel: 'local', source_commit: '3b093178b38d92b0ec12c89b37c66c721e97f753', source_tree: null, working_tree_dirty: false },
    ...patch,
  },
  dashboard: { available: true, version: 'v3.27.0', reason: null },
});
const render = (value: DesktopSnapshot) => renderToStaticMarkup(<CoreSection snapshot={value} />);

describe('本机核心与网络只读投影', () => {
  it('显示平台接管值与 Profile 声明值的差异，不把核心回读当成平台值', () => {
    const html = render(snapshot());
    expect(html).toContain('平台接管');
    expect(html).toContain('warning');
    expect(html).toContain('Profile 声明：info');
    expect(html).not.toContain('保存');
    expect(html).not.toContain('nf-button-primary');
  });

  it('没有特权会话时不展示 TUN 会话参数，也不猜测实际值', () => {
    const value = snapshot({ overlay: false, mode: 'tun', rows: [
      { id: 'dns.enable', group: 'DNS', label: 'DNS 接管', source: 'platform', configured: '开启', declared: null, running: null },
    ] });
    const html = render(value);
    expect(html).not.toContain('虚拟网卡');
    expect(html).toContain('TUN 接入方式已选择但当前没有特权会话');
  });

  it('构建身份与随包组件给出可辨认的身份，未记录时明确说明', () => {
    const html = render(snapshot());
    expect(html).toContain('0.2.0 · 修订 8');
    expect(html).toContain('local');
    expect(html).toContain('3b093178');
    expect(html).toContain('64cf18aa');
    expect(html).toContain('随包版本');
    expect(render(snapshot({ identity: null }))).toContain('源码运行没有构建记录');
  });
});
