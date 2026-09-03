import { describe, expect, it } from 'vitest';
import { fixtureScenarios } from '../data/fixtures';
import { LiveNetFleetClient } from './liveClient';

const source = {
  mode: 'live' as const,
  label: '设备实时只读',
  target_label: '示例设备',
  read_only: true,
  connected: true,
  fetched_at: 1_788_000_000,
  duration_ms: 42,
};

describe('LiveNetFleetClient', () => {
  it('reads one status and events snapshot from the local bridge', async () => {
    const payload = {
      status: fixtureScenarios.healthy.status,
      events: fixtureScenarios.healthy.events,
      source,
    };
    let requested: [RequestInfo | URL, RequestInit | undefined] | null = null;
    const fetcher: typeof fetch = async (input, init) => {
      requested = [input, init];
      return new Response(JSON.stringify(payload), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      });
    };

    await expect(new LiveNetFleetClient(fetcher).read()).resolves.toEqual(payload);
    expect(requested).toEqual(['/__netfleet_live/snapshot', { cache: 'no-store' }]);
  });

  it('preserves a usable status when the events read fails', async () => {
    const payload = {
      status: fixtureScenarios.healthy.status,
      errors: { events: '设备事件读取失败' },
      source,
    };
    const fetcher: typeof fetch = async () => new Response(JSON.stringify(payload), { status: 200 });

    await expect(new LiveNetFleetClient(fetcher).read()).resolves.toEqual(payload);
  });

  it('reads current connections from the separate uncached endpoint', async () => {
    const payload = {
      connections: [{ destination: 'example.com', destination_port: 443, network: 'tcp', rule: 'RuleSet', rule_payload: 'youtube-domain', chains: ['YouTube', '海外加速'] }],
      count: 1,
      truncated: false,
      read_at: 1_788_000_000,
    };
    let requested: [RequestInfo | URL, RequestInit | undefined] | null = null;
    const fetcher: typeof fetch = async (input, init) => {
      requested = [input, init];
      return new Response(JSON.stringify(payload), { status: 200, headers: { 'Content-Type': 'application/json' } });
    };

    await expect(new LiveNetFleetClient(fetcher).connections()).resolves.toEqual(payload);
    expect(requested).toEqual(['/__netfleet_live/connections', { cache: 'no-store' }]);
  });

  it('keeps failed live source when status and events are both missing', async () => {
    const payload = {
      errors: { status: '设备状态读取失败', events: '设备事件读取失败' },
      source: { ...source, connected: false, duration_ms: 1800 },
    };
    const fetcher: typeof fetch = async () => new Response(JSON.stringify(payload), {
      status: 502,
      headers: { 'Content-Type': 'application/json' },
    });

    await expect(new LiveNetFleetClient(fetcher).read()).resolves.toEqual(payload);
  });

  it('keeps live target from meta when the snapshot body is unusable', async () => {
    const fetcher: typeof fetch = async (input) => {
      if (String(input).includes('/__netfleet_live/meta')) {
        return new Response(JSON.stringify({
          available: true,
          source: { mode: 'live', label: '设备实时只读', target_label: '示例设备', read_only: true },
        }), { status: 200, headers: { 'Content-Type': 'application/json' } });
      }
      return new Response('{}', { status: 502 });
    };

    await expect(new LiveNetFleetClient(fetcher).read()).resolves.toMatchObject({
      errors: { status: '设备状态读取失败', events: '设备事件读取失败' },
      source: { mode: 'live', label: '设备实时只读', target_label: '示例设备', read_only: true, connected: false },
    });
  });

  it('rejects bridge failures and every mutation method', async () => {
    const fetcher: typeof fetch = async () => new Response('{}', { status: 502 });
    const client = new LiveNetFleetClient(fetcher);

    await expect(client.read()).rejects.toThrow('无法读取设备实时状态');
    await expect(client.enable()).rejects.toThrow('只读模式');
    await expect(client.selectAuto()).rejects.toThrow('只读模式');
    await expect(client.disable()).rejects.toThrow('只读模式');
  });
});
