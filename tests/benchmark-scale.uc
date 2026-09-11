/* SPDX-License-Identifier: Apache-2.0 */
import { use, release } from './services.uc';
const summary = use('models.selector').provider_round_summary;
const choose = use('selection.algorithm').choose_automatic;
function milliseconds() { const t = clock(); return t[0]*1000 + t[1]/1000000; }
const url = 'https://benchmark.invalid/204';
const results = [];
for (let size in [100, 1000, 5000]) {
 const providers = {}, state = {}, entry = { providers: {}, candidate_groups: [] }, candidates = [];
 const policy = { capabilities: { standard: { enabled: true, mode: 'automatic' } }, regions: {}, selection: { region_switch_margin_ms: 150 } };
 for (let p = 0; p < 3; p++) {
  const id = `p${p}`, source = `source${p}`, nodes = [];
  entry.providers[id] = { source_name: source };
  for (let n = 0; n < size; n++) push(nodes, { name: `${id}-node${n}`, type: 'Hysteria2', alive: true, extra: { [url]: { alive: true } } });
  providers[source] = { proxies: nodes };
  for (let r = 0; r < 20; r++) {
   const region = `r${r}`, name = `${id}-${region}`, node = nodes[size-1-r];
   state[name] = { all: [node.name], now: node.name, alive: true, extra: { [url]: { alive: true } } };
   policy.regions[region] = { mode: 'automatic' };
   push(entry.candidate_groups, { name, provider: id, region });
   push(candidates, { capability: "standard", candidate_id: node.name, provider_id: id, region_id: region, role: 'primary',
    group: name, leaf_verified: true, available: true, latency: { status: 'ok', delay_ms: 50+r+p }, quota: { state: 'available', remaining_bytes: 1000000 } });
  }
 }
 const timings = [];
 for (let round = 0; round < 10; round++) {
  const started = milliseconds(), observed = summary(entry, state, providers, url);
  const selected = choose(candidates, policy, 'standard', null);
  if (!selected.ok || selected.region_id != 'r0' || length(observed.groups) != 60 ||
   length(filter(observed.sources, s => s.node_count != size || s.alive_count != size)) ||
   length(filter(observed.groups, g => g.reason != 'ready'))) die('scale_result_changed');
  push(timings, milliseconds()-started);
 }
 sort(timings, (a,b) => a-b);
 push(results, { total_nodes: size*3, providers: 3, regions: 20, candidates: 60, rounds: 10,
  p50_ms: timings[4], p95_ms: timings[9] });
}
release();
printf('%J\n', { schema: 'opl-netfleet-selection-scale.v1', ok: true, results });
