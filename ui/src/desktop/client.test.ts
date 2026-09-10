import { describe, expect, it } from 'vitest';
import { DesktopNetFleetClient } from './client';

describe('desktop client trust and action boundaries', () => {
  it('fails closed without a session instead of loading preview data', async () => {
    let requests = 0;
    const client = new DesktopNetFleetClient(null, async () => { requests++; return new Response(); });
    await expect(client.readSnapshot()).rejects.toThrow('本机会话已失效');
    await expect(client.enable()).rejects.toThrow('本机会话已失效');
    expect(requests).toBe(0);
  });
  it('carries authorization only to the local action and recognizes nested helper rejection', async () => {
    const client = new DesktopNetFleetClient('test-session', async (url, init) => {
      expect(url).toBe('/api/action');
      expect(init?.headers).toMatchObject({ Authorization: 'Bearer test-session' });
      expect(JSON.parse(String(init?.body))).toEqual({ action: 'network-install', authorize: true });
      return Response.json({ ok: true, result: { ok: false, status: 'not-authorized' } });
    });
    await expect(client.action('network-install', { authorize: true })).rejects.toThrow('系统授权未完成');
  });
  it('preserves an unconfigured state without inventing a business snapshot', async () => {
    const snapshot = { runtime: { platform: 'macos', configured: false, running: false }, subscriptions: {}, network: {}, status: null, events: null };
    const client = new DesktopNetFleetClient('test-session', async () => Response.json({ ok: true, result: snapshot }));
    expect(await client.readSnapshot()).toEqual(snapshot);
    await expect(client.status()).rejects.toThrow('尚未编译');
  });
  it('rejects malformed business data before components display it', async () => {
    const client = new DesktopNetFleetClient('test-session', async () => Response.json({ ok: true, result: {
      runtime: { platform: 'macos', configured: true, running: true }, subscriptions: {}, network: {},
      status: { capabilities: {}, providers: [], regions: [] }, events: { events: [] },
    } }));
    await expect(client.readSnapshot()).rejects.toThrow('本机状态格式无效');
  });
});
