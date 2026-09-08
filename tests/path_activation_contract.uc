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
check(length(calls) == 3 && calls[0].group == "candidate" && calls[1].group == "preferred" &&
 calls[2].group == "inner" && calls[1].timeout == 15000 && calls[1].expected == 404 && calls[2].expected == 200, "probe only the chosen chain in dependency order with health timeout");
business_failed = true; stale = true; probe_count = 0;
const failed = paths.wait_for_preferred_runtime("fixture", entry, "candidate", policy, {}, false);
check(failed.error == "selected_business_path_probe_failed" && failed.probe == "path" && failed.method == "HEAD" && failed.expected_status == 404 && stale && length(calls) == 5,
 "business failure must stop before outer probe and remain distinct from latency success");
print("path activation contracts passed\n");
