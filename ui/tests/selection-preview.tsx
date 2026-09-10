import { useState } from 'react';
import { createRoot } from 'react-dom/client';
import { fixtureScenarios } from '../src/data/fixtures';
import { RegionTable } from '../src/views/Tables';
import { RegionSelectionDialog } from '../src/components/RegionSelectionDialog';
import { CapabilityPanel } from '../src/components/CapabilityPanel';
import '../src/styles.css';
import '../src/desktop/desktop.css';

// Local interaction regression fixture. No RPC, network actions, or device state.
function SelectionPreview() {
  const [snapshot, setSnapshot] = useState(() => structuredClone(fixtureScenarios.healthy.status));
  const [selection, setSelection] = useState<{ capability?: string; region?: string } | null>(null);
  const [calls, setCalls] = useState<string[]>([]);
  const [expire, setExpire] = useState(false);
  const open = (value: { capability?: string; region?: string }) => {
    setSelection(value);
    if (expire) setTimeout(() => setSnapshot(previous => ({ ...previous, capabilities: previous.capabilities.map(cap => ({ ...cap, can_select_region: false, selectable_regions: [] })) })), 1000);
  };
  return <div className="nf-app nf-desktop"><main style={{ padding: 24 }}>
    <h1>地区交互测试 · 脱敏测试数据</h1><p>仅验证 UI，不连接设备，不改变网络。</p>
    <label><input type="checkbox" checked={expire} onChange={event => setExpire(event.target.checked)} />打开确认框后撤销授权</label>
    <p role="status">提交记录：{calls.length ? calls.join('；') : '无'}</p>
    <RegionTable snapshot={snapshot} full onChooseRegion={region => open({ region })} />
    <CapabilityPanel snapshot={snapshot} capability={snapshot.capabilities[0]} onChooseRegion={() => open({ capability: snapshot.capabilities[0].id })} />
    {selection && <RegionSelectionDialog snapshot={snapshot} initialCapability={selection.capability} initialRegion={selection.region} onCancel={() => setSelection(null)} onConfirm={(capability, region) => { setCalls(previous => [...previous, `${capability}/${region}`]); setSelection(null); }} />}
  </main></div>;
}
createRoot(document.getElementById('root')!).render(<SelectionPreview />);
