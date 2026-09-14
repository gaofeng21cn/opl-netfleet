// A bounded display projection, never configuration or authority for a write.
const LIMIT = 128 * 1024;
const scalar = value => value === null || typeof value === 'string' || typeof value === 'boolean' ||
  typeof value === 'number' && Number.isFinite(value);
const pick = (value, keys) => Object.fromEntries(keys.filter(key => scalar(value?.[key]) ||
  Array.isArray(value?.[key]) && value[key].every(item => typeof item === 'string'))
  .map(key => [key, value[key]]));
const record = (value, keys) => Object.fromEntries(Object.entries(value || {}).slice(0, 256)
  .map(([key, item]) => [key, pick(item, keys)]));

export function displayState(state) {
  if (!state || !Array.isArray(state.config?.rules) || !Array.isArray(state.config?.devices)) return null;
  const strings = value => Array.isArray(value) && value.every(item => typeof item === 'string');
  if (!state.config.rules.every(rule => rule && typeof rule.id === 'string' && typeof rule.name === 'string' &&
      typeof rule.domain === 'string' && strings(rule.devices)) ||
      !state.config.devices.every(device => device && typeof device.id === 'string' && typeof device.name === 'string' && strings(device.addresses))) return null;
  return {
    ...pick(state, ['installed', 'requested', 'intercepting', 'reason', 'managed', 'management_reason']),
    config: {
      rules: state.config.rules.slice(0, 256).map(rule => pick(rule, ['id', 'name', 'domain', 'match', 'port', 'strategy', 'enabled', 'devices'])),
      devices: state.config.devices.slice(0, 256).map(device => ({ ...pick(device, ['id', 'name']),
        addresses: state.device_addresses?.[device.id] || device.addresses })),
    },
    trust: Object.fromEntries(Object.entries(state.trust || {}).slice(0, 256)
      .map(([id, trust]) => [id, { ...pick(trust, ['verified']), runtimes: pick(trust?.runtimes, ['system', 'codex_app', 'codex_cli', 'images']) }])),
    rules: record(state.rules, ['at', 'upstream_protocol', 'http_status', 'reason']),
    recovery: pick(state.recovery, ['latched', 'reason']),
    rule_recovery: record(state.rule_recovery, ['intercepting', 'latched', 'reason']),
  };
}

export function displayCache(key, storage = () => window.localStorage) {
  return {
    read() {
      try {
        const raw = storage().getItem(key);
        if (!raw || raw.length > LIMIT) return null;
        const entry = JSON.parse(raw);
        if (entry.schema !== 1 || !Number.isFinite(entry.at) || entry.at <= 0 || entry.at > Date.now()) return null;
        const state = displayState(entry.state);
        if (!state) return null;
        return { at: entry.at, state, tab: ['rules', 'devices', 'diagnostics'].includes(entry.tab) ? entry.tab : 'rules' };
      } catch (_) { return null; }
    },
    write(state, at, tab) {
      try {
        const value = displayState(state);
        if (!value) return;
        const raw = JSON.stringify({ schema: 1, at, tab, state: value });
        if (raw.length <= LIMIT) storage().setItem(key, raw);
      } catch (_) { /* Storage policy must not prevent live management. */ }
    },
  };
}
