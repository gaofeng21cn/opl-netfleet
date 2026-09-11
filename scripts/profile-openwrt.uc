/* SPDX-License-Identifier: Apache-2.0 */
import * as fs from 'fs';
import { create } from '/usr/libexec/opl-netfleet/kernel/host.uc';
import { create as adapter } from '/usr/libexec/opl-netfleet/adapters/openwrt.uc';
// Profile the actual read-only status caller. Never print status or command contents.
const rounds = int(ARGV[0] ?? 5);
if (rounds < 1 || rounds > 30) exit(2);
function ms() { return +split(fs.readfile('/proc/uptime'), ' ')[0] * 1000; }
function instrument(instance, method, name, times) {
 const original = instance[method];
 instance[method] = function(...args) {
  const started = ms(), result = original(...args);
  times[name] = (times[name] ?? 0) + ms() - started;
  return result;
 };
}
const samples = [];
let counts, build;
for (let iteration = 0; iteration < rounds; iteration++) {
 const started = ms();
 const host = create('/usr/libexec/opl-netfleet', { adapter: adapter() });
 const times = { host: ms() - started };
 for (let service, methods in {
  'mihomo.backend': ['running', 'lan_runtime_state'],
  'mihomo.controller': ['proxies', 'proxy_providers'],
  'platform.service': ['service_state'],
  'subscriptions.facts': ['provider_quotas', 'provider_display_names', 'subscription_refresh_projection'],
  'models.status': ['build']
 }) for (let method in methods) instrument(host.use(service), method, service + '.' + method, times);
 let observed;
 host.use('events.output').ok = (action, result) => { observed = result; };
 host.use('status.control').command_status(['status']);
 times.total = ms() - started;
 host.release();
 if (observed == null) die('status_profile_unavailable');
 counts = { providers: length(observed.providers ?? []), regions: length(observed.regions ?? []), capabilities: length(observed.capabilities ?? []) };
 build = observed.build;
 push(samples, times);
}
const metrics = {};
for (let key in keys(samples[0])) {
 const values = sort(map(samples, s => s[key] ?? 0), (a,b) => a-b);
 metrics[key] = { p50_ms: values[int((rounds-1)*0.5)], p95_ms: values[int((rounds-1)*0.95)], max_ms: values[rounds-1] };
}
printf('%J\n', { schema: 'opl-netfleet-status-profile.v1', rounds, build, counts, metrics,
 note: 'Nested phase timings overlap; total includes host loading. No health results are cached.' });
