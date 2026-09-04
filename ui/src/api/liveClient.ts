import type { ClientReadResult, ConnectionsSnapshot, DeviceConfigSnapshot, EventsSnapshot, NetFleetClient, StatusSnapshot } from '../types';

interface BridgeResponse extends ClientReadResult {
  status?: StatusSnapshot;
  events?: EventsSnapshot;
  config?: DeviceConfigSnapshot;
}

export class LiveNetFleetClient implements NetFleetClient {
  constructor(private readonly fetcher: typeof fetch = (input, init) => fetch(input, init)) {}

  async read(): Promise<ClientReadResult> {
    const started = Date.now();
    try {
      const response = await this.fetcher('/__netfleet_live/snapshot', { cache: 'no-store' });
      const snapshot = await response.json() as BridgeResponse;
      if (snapshot.source) return snapshot;
    } catch {
      // Complete snapshot failures fall back to meta source instead of dropping the live target.
    }
    const source = await this.metaSource();
    if (source) {
      return {
        errors: { status: '设备状态读取失败', events: '设备事件读取失败' },
        source: {
          ...source,
          connected: false,
          fetched_at: Math.floor(Date.now() / 1000),
          duration_ms: Date.now() - started,
        },
      };
    }
    throw new Error('无法读取设备实时状态');
  }

  private async metaSource() {
    try {
      const response = await this.fetcher('/__netfleet_live/meta', { cache: 'no-store' });
      if (!response.ok) return null;
      const payload = await response.json() as { source?: ClientReadResult['source'] };
      return payload.source || null;
    } catch {
      return null;
    }
  }

  async status() {
    const snapshot = await this.read();
    if (!snapshot.status) throw new Error(snapshot.errors?.status || '设备状态读取失败');
    return snapshot.status;
  }

  async events() {
    const snapshot = await this.read();
    if (!snapshot.events) throw new Error(snapshot.errors?.events || '设备事件读取失败');
    return snapshot.events;
  }

  async connections() {
    const response = await this.fetcher('/__netfleet_live/connections', { cache: 'no-store' });
    if (!response.ok) throw new Error('设备当前连接读取失败');
    return await response.json() as ConnectionsSnapshot;
  }

  async enable() {
    throw new Error('本机实时预览为只读模式');
  }

  async selectAuto() {
    throw new Error('本机实时预览为只读模式');
  }

  async refresh() {
    throw new Error('本机实时预览为只读模式');
  }

  async disable() {
    throw new Error('本机实时预览为只读模式');
  }
}
