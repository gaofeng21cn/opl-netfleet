import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, it } from 'vitest';
import { fixtureScenarios } from '../data/fixtures';
import { sourcePreparation } from './presentation';
import { CapabilityPanel } from '../components/CapabilityPanel';
import { DesktopOverview, overviewAttention } from './DesktopOverview';
import type { DesktopSnapshot } from './types';

const snapshot = (): DesktopSnapshot => ({
  runtime: { platform: 'macos', running: false, configured: true, mode: 'direct', requestedMode: 'direct', networkMode: 'explicit', ports: { mixed: 7890, controller: 9090, dns: 1053 }, controllerReady: false, clean: true, pid: null, version: null, lastError: null },
  policy: null, subscriptions: {}, status: structuredClone(fixtureScenarios.healthy.status), events: null, config: null, configError: null, network: { clean: true }, error: null,
});
const render = (value: DesktopSnapshot) => renderToStaticMarkup(<DesktopOverview snapshot={value} disabled={false} canSelect={false} onNavigate={() => {}} onSelect={() => {}} />);

describe('桌面概览的状态证据', () => {
  it('主动停止不报故障，意外停止和未恢复网络仍需处理', () => {
    const value = snapshot();
    expect(overviewAttention(value)).toEqual([]);
    value.runtime.requestedMode = 'netfleet';
    expect(overviewAttention(value)).toContain('代理意外停止，请重新启动或查看诊断。');
    value.network.recoveryRequired = true;
    expect(overviewAttention(value)).toContain('网络恢复尚未确认，请查看诊断。');
  });
  it('停止时不展示旧测量，也不把手动设置称为自动选优', () => {
    const value = snapshot();
    value.status!.capabilities = [{ ...value.status!.capabilities[0], enabled: true, user_mode: 'direct' }];
    const html = render(value);
    expect(html).toContain('手动直连');
    expect(html).toContain('未接管');
    expect(html).not.toContain(' ms');
    expect(html).not.toContain('自动选优');
    value.status!.capabilities[0].user_mode = 'native_profile';
    expect(render(value)).toContain('启用后显示当前路径');
    expect(render(value)).not.toContain('native_profile');
  });
  it('出口详情与概览一致，不把停止前的健康状态当作现状', () => {
    const status = snapshot().status!;
    status.active = false;
    status.runtime.mihomo_running = false;
    status.capabilities[0].alive = true;
    status.capabilities[0].user_mode = 'native_profile';
    const html = renderToStaticMarkup(<CapabilityPanel snapshot={status} capability={status.capabilities[0]} />);
    expect(html).toContain('已停止');
    expect(html).toContain('未测量');
    expect(html).not.toContain('native_profile');
    expect(html).not.toContain('is-healthy');
  });
  it('直连回退不伪造地区或机场，原生运行不称为停止', () => {
    const value = snapshot();
    value.runtime.running = true;
    value.runtime.mode = 'netfleet';
    value.status!.active = true;
    value.status!.capabilities = [{ ...value.status!.capabilities[0], enabled: true, data_path: 'direct_fallback' }];
    expect(render(value)).toContain('直连退路');
    expect(render(value)).toContain('不经过机场');
    value.runtime.mode = 'mihomo';
    expect(render(value)).toContain('未接管');
    expect(render(value)).not.toContain('未运行');
  });
});

// Display evidence must follow the owner even when desktop download metadata is absent.
describe('来源与业务归属证据', () => {
  it('已有 owner 缓存优先于缺失的桌面下载记录', () => {
    const value = snapshot();
    value.subscriptions.source = { name: '来源', enabled: true, hasUrl: true };
    value.status!.subscriptions = [{ section: 'source', cache_present: true }] as NonNullable<typeof value.status>['subscriptions'];
    expect(sourcePreparation(value, 'source')).toBe('已有订阅缓存');
    value.status!.subscriptions = [];
    expect(sourcePreparation(value, 'source')).toBe('下载记录未提供');
    value.subscriptions.source.imported = true;
    value.subscriptions.source.hasUrl = false;
    expect(sourcePreparation(value, 'source')).toContain('本地导入');
  });
  it('默认直连业务不会被归为默认走出口', () => {
    const value = snapshot().status!;
    const capability = value.capabilities[0];
    capability.business_routes = [{ name: 'Netflix', default_route: 'capability' }, { name: '国内媒体', default_route: 'direct' }];
    const html = renderToStaticMarkup(<CapabilityPanel snapshot={value} capability={capability} />);
    expect(html).toContain('<strong>默认走此出口</strong><span>Netflix</span>');
    expect(html).toContain('<strong>默认直连</strong><span>国内媒体</span>');
  });
});
