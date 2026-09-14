import * as fs from 'fs';
const factory = loadfile(replace(sourcepath(), /[^/]+$/, '../openwrt/files/usr/libexec/opl-netfleet/plugins/status/lib/events.uc'))();
let logs = 0, manifests = 0, output;
const services = {
 'events.model': { validate: () => ({ok:true}) },
 'events.output': { ok: (name, result) => { output = result; } },
 'events.store': { read_events: () => ({ events: [{ action:'select' }] }), core_netfleet_lines: () => { logs++; return ['temporary log']; } },
 'mihomo.backend': { MANIFEST_PATH: 'manifest' },
 'models.activation': { expected_runtime_groups: () => [] },
 'platform.documents': { load_policy: () => ({}) },
 'platform.storage': { read_json: () => { manifests++; return {}; } },
 'subscriptions.facts': { provider_display_names: () => ({}) }
};
const api = factory({use: name => services[name]});
api.command_events(['events']);
assert(logs == 0 && manifests == 0 && length(output.core_lines) == 0 && length(output.events) == 1, 'normal event read must not inspect logs or runtime manifest');
api.command_events(['events', 'logs']);
assert(logs == 1 && manifests == 1 && output.core_lines[0] == 'temporary log' && output.core_lines_persistent == false, 'explicit diagnostic read retains temporary core logs');
