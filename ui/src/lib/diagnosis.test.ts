import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { diagnose, targetHost } from './diagnosis';
import { fixtureScenarios } from '../data/fixtures';
import type { ConnectionsSnapshot } from '../types';

const code = readFileSync(new URL('../../../openwrt/luci-app-netfleet/htdocs/luci-static/resources/netfleet/product.js', import.meta.url), 'utf8');
const native = new Function('baseclass', code)({ extend: (value: unknown) => value });
const status = structuredClone(fixtureScenarios.healthy.status);
const connections: ConnectionsSnapshot = { count: 4, truncated: true, read_at: 100,
  connections: ['example.com', 'api.example.com', 'notexample.com', 'example.com.evil.test'].map(destination => ({
    destination, network: 'tcp', destination_port: 443, rule: 'DomainSuffix', rule_payload: 'example.com', chains: ['业务出口', '节点 A'],
  })) };

describe.each([['React', { diagnose, targetHost }], ['LuCI', native]] as const)('%s 网站诊断', (_name, surface) => {
  it('域名只匹配自身与子域名，不伪造规则、成功或吞吐', () => {
    const result = surface.diagnose(status, connections, 'https://EXAMPLE.com/path?q=private');
    expect(result.host).toBe('example.com');
    expect(result.matches.map((item: { destination: string }) => item.destination)).toEqual(['example.com', 'api.example.com']);
    expect(result.matches[0].chains).toEqual(['业务出口', '节点 A']);
    expect(result.truncated).toBe(true);
    expect(result.readAt).toBe(100);
    expect(result.message).toContain('不代表请求成功或速度达标');
  });
  it('支持 IPv4、IPv6、IDN 和域名尾点，拒绝账户地址和非法协议', () => {
    expect(surface.targetHost('EXAMPLE.com.')).toBe('example.com');
    expect(surface.targetHost('https://例子.测试/')).toBe('xn--fsqu00a.xn--0zwm56d');
    expect(surface.targetHost('2001:db8::1')).toBe('2001:db8::1');
    expect(surface.targetHost('https://[2001:db8::1]:443/')).toBe('2001:db8::1');
    expect(surface.targetHost('192.0.2.1')).toBe('192.0.2.1');
    for (const input of ['https://user:secret@example.com', 'javascript:alert(1)', 'file:///tmp/a', '', 'bad host']) expect(surface.targetHost(input)).toBeNull();
    const snapshot = { ...connections, connections: [{ destination: '192.0.2.1', chains: [] }, { destination: 'sub.192.0.2.1', chains: [] }] };
    expect(surface.diagnose(status, snapshot, '192.0.2.1').matches).toHaveLength(1);
  });
  it('空快照、读取失败、陈旧状态与真实核心故障分开', () => {
    expect(surface.diagnose(status, connections, 'other.test').message).toContain('不代表网站不可达');
    expect(surface.diagnose(status, connections, 'example.com', 'offline').message).toContain('读取失败');
    const stale = surface.diagnose(status, connections, 'example.com', null, true);
    expect(stale.checks.every((item: { value: string }) => item.value === '需要重新读取')).toBe(true);
    expect(stale.message).toContain('不能作为当前网络结论');
    const stopped = { ...status, runtime: { mihomo_running: false, controller_available: false } };
    expect(surface.diagnose(stopped, connections, 'example.com').next).toContain('核心未运行');
    expect(surface.diagnose(stopped, connections, '').checks[2].value).toBe('未取得状态');
  });
});

it('两种界面投影完全一致且不修改源数据', () => {
  const before = JSON.stringify({ status, connections });
  expect(native.diagnose(status, connections, 'example.com')).toEqual(diagnose(status, connections, 'example.com'));
  expect(JSON.stringify({ status, connections })).toBe(before);
});
