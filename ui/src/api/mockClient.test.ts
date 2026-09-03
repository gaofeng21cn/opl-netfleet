import { describe, expect, it } from 'vitest';
import { MockNetFleetClient } from './mockClient';

describe('MockNetFleetClient events', () => {
  it('records the selected route for preview actions', async () => {
    const client = new MockNetFleetClient();

    await client.selectAuto('standard');

    const latest = (await client.events()).events.at(-1);
    expect(latest).toMatchObject({
      action: 'select',
      capability: 'standard',
      region_id: 'japan',
      provider_id: 'alpha',
      leaf: 'JP-Tokyo-02',
      delay_ms: 78,
    });
  });

  it('keeps the native recovery result distinct from a selected route', async () => {
    const client = new MockNetFleetClient();

    await client.disable();

    const latest = (await client.events()).events.at(-1);
    expect(latest).toMatchObject({ action: 'disable', reason: 'native_restored' });
    expect(latest?.provider_id).toBeUndefined();
  });
});
