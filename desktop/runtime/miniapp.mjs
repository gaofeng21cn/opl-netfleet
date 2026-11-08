// Deliberately small projection over the existing desktop owners.
export function miniappStatus({ runtime, network, state, now = new Date() }) {
  return {
    schema: 'opl-netfleet-miniapp-status.v1', platform: 'macos',
    mode: runtime.running ? (state.profile === 'file:OPL-NetFleet.json' ? 'netfleet' : 'mihomo')
      : network.clean !== false && !network.recoveryRequired ? 'direct' : 'unconfirmed',
    network_mode: ['explicit', 'system', 'tun'].includes(state.network?.mode) ? state.network.mode : 'unknown',
    running: runtime.running === true, configured: state.configured === true,
    recovery_required: network.recoveryRequired === true, read_at: now.toISOString(),
  };
}

export async function serveMiniappStatus(request, response, readStatus) {
  if (request.url !== '/miniapp/status') return false;
  const allowed = request.method === 'GET';
  let status = allowed ? 200 : 405, value;
  try { value = allowed ? await readStatus() : { error: 'method_not_allowed' }; }
  catch { status = 503; value = { error: 'owner_unavailable' }; }
  const body = JSON.stringify(value);
  response.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store',
    'Content-Length': Buffer.byteLength(body), 'X-Content-Type-Options': 'nosniff' });
  response.end(body);
  return true;
}
