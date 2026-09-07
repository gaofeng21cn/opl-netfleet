import { afterEach, describe, expect, it, vi } from 'vitest';
import type { Plugin } from 'vite';

const calls = vi.hoisted(() => [] as Array<{ method: string; finish(error: Error | null, stdout?: string): void }>);
vi.mock('node:child_process', () => ({ execFile: Object.assign(() => {}, {
  [Symbol.for('nodejs.util.promisify.custom')]: (_file: string, args: string[]) => new Promise((resolve, reject) => {
    calls.push({ method: args[args.length - 1].split(' ').at(-1)!, finish: (error, stdout) => error ? reject(error) : resolve({ stdout, stderr: '' }) });
  }),
}) }));

import configuration from '../../vite.config';
afterEach(() => { calls.length = 0; vi.unstubAllEnvs(); });

async function setup() {
  vi.stubEnv('NETFLEET_UI_TARGET', 'test-router');
  const config = typeof configuration === 'function' ? await configuration({ command: 'serve', mode: 'test' }) : await configuration;
  const plugin = (config.plugins as Plugin[]).find(item => item.name === 'netfleet-live-readonly-bridge')!;
  const routes = new Map<string, (request: unknown, response: unknown) => Promise<void>>();
  (plugin.configureServer as Function)({ middlewares: { use: (path: string, handler: (request: unknown, response: unknown) => Promise<void>) => routes.set(path, handler) } });
  let body = '';
  const response = { statusCode: 200, setHeader() {}, end(value: string) { body = value; } };
  return { read: () => routes.get('/__netfleet_live/snapshot')!({ method: 'GET' }, response), response, body: () => JSON.parse(body) };
}

describe('真实预览读取调度', () => {
  it('三个只读操作同时开始，每项失败独立保留', async () => {
    const endpoint = await setup();
    const done = endpoint.read();
    expect(calls.map(call => call.method)).toEqual(['status', 'events', 'config_get']);
    calls[0].finish(null, JSON.stringify({ ok: true, result: { active: true } }));
    calls[1].finish(new Error('unavailable'));
    calls[2].finish(null, JSON.stringify({ ok: true, result: { revision: 'test' } }));
    await done;
    expect(endpoint.body()).toMatchObject({ status: { active: true }, config: { revision: 'test' }, errors: { events: '设备事件读取失败' }, source: { connected: true } });
  });
  it('只有旧事件可读时不标记状态已连接', async () => {
    const endpoint = await setup();
    const done = endpoint.read();
    calls[0].finish(new Error('offline'));
    calls[1].finish(null, JSON.stringify({ ok: true, result: { events: [] } }));
    calls[2].finish(new Error('offline'));
    await done;
    expect(endpoint.body().source.connected).toBe(false);
    expect(endpoint.body().errors.status).toBe('设备状态读取失败');
  });
});
