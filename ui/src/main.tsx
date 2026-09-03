import { useEffect, useMemo, useState } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { App } from './App';
import { LiveNetFleetClient } from './api/liveClient';
import { MockNetFleetClient } from './api/mockClient';
import { fixtureScenarios, type FixtureScenario } from './data/fixtures';
import type { DataSourceInfo, EventsSnapshot, NetFleetClient, StatusSnapshot } from './types';

function DevApp() {
  const client = useMemo(() => new MockNetFleetClient(), []);
  const liveClient = useMemo(() => new LiveNetFleetClient(), []);
  const [ready, setReady] = useState(false);
  const [liveAvailable, setLiveAvailable] = useState(false);
  const [liveSource, setLiveSource] = useState<DataSourceInfo | null>(null);
  const [scenario, setScenario] = useState<string>('healthy');
  const [privateFixture, setPrivateFixture] = useState<{ status: StatusSnapshot; events: EventsSnapshot } | null>(null);

  useEffect(() => {
    void Promise.all([
      fetch('/__netfleet_live/meta', { cache: 'no-store' }),
      fetch('/__netfleet_fixture', { cache: 'no-store' }),
    ]).then(async ([liveResponse, fixtureResponse]) => {
      const liveMeta = liveResponse.ok
        ? await liveResponse.json() as { available?: boolean; source?: DataSourceInfo }
        : {};
      const live = Boolean(liveMeta.available);
      if (liveMeta.source) setLiveSource(liveMeta.source);
      let fixture: { status: StatusSnapshot; events: EventsSnapshot } | null = null;
      if (fixtureResponse.ok && fixtureResponse.status !== 204) {
        fixture = await fixtureResponse.json() as { status: StatusSnapshot; events: EventsSnapshot };
        client.loadFixture(fixture.status, fixture.events);
        setPrivateFixture(fixture);
      }
      setLiveAvailable(live);
      setScenario(live ? 'live' : fixture ? 'private' : 'healthy');
      setReady(true);
    }).catch(() => setReady(true));
  }, [client]);

  const selectScenario = (value: string) => {
    if (value === 'private' && privateFixture) client.loadFixture(privateFixture.status, privateFixture.events);
    else if (value !== 'live') client.setScenario(value as FixtureScenario);
    setScenario(value);
  };

  if (!ready) return <div className="nf-loading"><span className="nf-spinner" />正在初始化本机数据源</div>;
  const activeClient: NetFleetClient = scenario === 'live' ? liveClient : client;
  return (
    <App
      client={activeClient}
      fallbackSource={scenario === 'live' ? liveSource || undefined : undefined}
      preview={{
        label: '开发数据源',
        scenario,
        scenarios: [
          ...(liveAvailable ? [{ id: 'live', label: `${liveSource?.target_label || '设备'} 实时（只读）` }] : []),
          ...(privateFixture ? [{ id: 'private', label: '私有真实投影' }] : []),
          ...Object.entries(fixtureScenarios).map(([id, item]) => ({ id, label: item.label })),
        ],
        onScenarioChange: selectScenario,
      }}
    />
  );
}

const root = document.getElementById('root');
if (!root) throw new Error('Missing #root');
const developmentRoot = root as HTMLElement & { __netfleetReactRoot?: Root };
const reactRoot = developmentRoot.__netfleetReactRoot || createRoot(developmentRoot);
developmentRoot.__netfleetReactRoot = reactRoot;
reactRoot.render(<DevApp />);
