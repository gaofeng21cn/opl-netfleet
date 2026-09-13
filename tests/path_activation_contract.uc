import * as fs from "fs";
const root = fs.realpath(replace(sourcepath(), /[^/]+$/, "../openwrt/files/usr/libexec/opl-netfleet"));
const factory = loadfile(`${root}/plugins/mihomo/lib/paths.uc`)();
const calls = [];
let business_failed = false, stale = true, probe_count = 0;
const services = {
 "mihomo.controller": {
  proxies: () => ({ proxies: {} }), proxy_providers: () => ({ providers: {} }),
  unfix: group => true, select: () => true, protected_probes: () => ({ ok: true }),
  test_group_path: (secret, group, checks) => {
   push(calls, { group, url: checks.latency.url, timeout: checks.latency.timeout_ms, expected: checks.latency.expected_status });
   if (checks.latency.url == "https://business.test/path") {
    if (business_failed) return false;
    probe_count++;
   }
   if (checks.latency.url == "https://business.test/guard" && probe_count == 1) stale = false;
   return true;
  }
 },
 "mihomo.latency": { measure: () => ({ status: "ok", results: {} }) },
 "mihomo.probes": { protected_probes_after_restart: () => ({ ok: true }) },
 "models.activation": { preferred_runtime_ready: r => r.data_path == "preferred" },
 "models.ordering": { sorted_keys: keys }, "models.policy": { automation: () => ({ startup_grace_seconds: 1 }) },
 "models.selector": { provider_group_leaf: () => "leaf" },
 "models.status": { resolve_runtime: () => ({ leaf: "leaf", data_path: stale ? "direct_fallback" : "preferred" }) },
 "platform.credentials": { api_secret: () => "fixture" }
};
const paths = factory({ use: name => services[name] });
const entry = { name: "visible", selector_name: "preferred", proxy_path_name: "inner" };
const policy = { checks: { latency: { url: "https://speed.test/204", timeout_ms: 2000 } },
 fail_open: { healthcheck: { path_probe_id: "path", guard_probe_id: "guard", timeout_ms: 15000 },
 probes: [{ id: "path", url: "https://business.test/path", expected_status: 200, head_expected_status: 404 },
 { id: "guard", url: "https://business.test/guard", expected_status: 200 }] } };
function check(value, reason) { if (!value) die(reason); }
const ready = paths.wait_for_preferred_runtime("fixture", entry, "candidate", policy, {}, false);
check(ready.preferred && !stale, "business URL health must revive the bound path");
check(length(calls) == 2 && calls[0].group == "preferred" &&
 calls[1].group == "inner" && calls[0].timeout == 15000 && calls[0].expected == 404 && calls[1].expected == 200, "probe only the chosen chain in dependency order with health timeout");
business_failed = true; stale = true; probe_count = 0;
const failed = paths.wait_for_preferred_runtime("fixture", entry, "candidate", policy, {}, false);
check(failed.error == "selected_business_path_probe_failed" && failed.probe == "path" && failed.method == "HEAD" && failed.expected_status == 404 && stale && length(calls) == 3,
 "business failure must stop before outer probe and remain distinct from latency success");
print("path activation contracts passed\n");

const policy_factory = loadfile(`${root}/plugins/mihomo/lib/interception-policy.uc`)()();
const starting = { backend: 'native-mihomo', ready: true, compatibility_ownership_guard: true,
 router_proxy: true, lan_proxy: true, custom_lan_access: true, listener_identity_ready: false };
check(policy_factory.admission({rules: []}, starting) == 'engine_starting', 'unready engine must not masquerade as a LAN policy conflict');
starting.listener_identity_ready = true;
check(policy_factory.admission({rules: []}, starting) == 'lan_access_not_equivalent', 'real policy conflicts remain rejected');
starting.custom_lan_access = false;
check(policy_factory.admission({rules: []}, starting) == null, 'ready equivalent gateway admitted');

let measures = 0, selected_leaf = 'leaf';
services['mihomo.latency'].measure = () => { measures++; return {status:'ok'}; };
services['mihomo.controller'].proxies = () => ({proxies: {preferred: {all:['candidate']}, visible: {all:['automatic']}}});
services['models.selector'].provider_group_leaf = () => selected_leaf;
services['models.activation'].preferred_runtime_ready = r => r.data_path == 'preferred';
business_failed = false; stale = false;
const activation_paths = factory({use: name => services[name]});
const automatic_entry = {...entry, automatic_name: 'automatic'};
const activated = activation_paths.activate_preferred_choice('fixture', automatic_entry, 'candidate', policy, false, false, {group:'candidate', candidate_id:'leaf'});
check(activated.ok && measures == 0, 'activation must consume measured evidence without a second speed probe');
selected_leaf = 'changed-leaf';
const changed = activation_paths.activate_preferred_choice('fixture', automatic_entry, 'candidate', policy, false, false, {group:'candidate', candidate_id:'leaf'});
check(!changed.ok && changed.error == 'selected_leaf_unavailable' && measures == 0, 'changed leaf cannot inherit prior speed evidence');

for(let mode in ['off','strict','always',null]) {
 const profile={rules:['PROCESS-NAME,haproxy,REJECT','MATCH,DIRECT']};
 if(mode!=null)profile['find-process-mode']=mode;
 check(policy_factory.admission(profile,starting)==(mode=='off'?null:'source_or_unsupported_routing_rule'),
       'only explicitly disabled process lookup preserves relay routing');
}
check(policy_factory.admission({'find-process-mode':'off',rules:['PROCESS-NAME,,REJECT']},starting)!=null,
      'empty process matcher remains unproven');
