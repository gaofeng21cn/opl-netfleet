#!/usr/bin/ucode
import { readfile } from "fs";
import { use, release as release_services } from "./services.uc";

const choose_automatic = use("selection.algorithm").choose_automatic;
const provider_group_current_leaf = use("models.selector").provider_group_current_leaf;
const speed_url = 'https://speed.example/204';
const provider_group_leaf = (state, providers, source, group) => use("models.selector").provider_group_leaf(state, providers, source, group, speed_url);
const provider_round_summary = (entry, state, providers) => use("models.selector").provider_round_summary(entry, state, providers, speed_url);

const policy = {
	capabilities: {
		standard: { enabled: true, mode: "automatic" },
		"ai-compatible": { enabled: true, mode: "automatic", excluded_regions: ["hong_kong"] }
	},
	regions: {
		current: { mode: "automatic" },
		near: { mode: "automatic" },
		fast: { mode: "automatic" },
		hong_kong: { mode: "automatic" }
	},
	selection: { region_switch_margin_ms: 150 }
};

function candidate(id, provider, region, rtt, remaining, role, leaf_verified, capability) {
	return {
		capability: capability ?? "standard",
		candidate_id: id,
		leaf_verified: leaf_verified ?? true,
		provider_id: provider,
		region_id: region,
		role: role,
		group: `group-${region}-${provider}`,
		available: true,
		latency: { status: "ok", delay_ms: rtt },
		quota: remaining == null ? { state: "unknown" } :
			remaining == 0 ? { state: "exhausted" } : { state: "available", remaining_bytes: remaining }
	};
};

const proxy_state = {
	"control-node": { type: "Direct", alive: true },
	"alpha-korea": { alive: true, now: "shared-node", all: ["shared-node"] },
	"alpha-dead": { alive: true, now: "dead-node", all: ["dead-node"] },
	"alpha-control": { alive: true, now: "control-node", all: ["control-node"] },
	"alpha-direct-name": { alive: true, now: "DIRECT", all: ["DIRECT"] }
};
const provider_state = {
	"SOURCE-ALPHA": { proxies: [
		{ name: "shared-node", type: "Hysteria2", alive: true },
		{ name: "dead-node", type: "Vless", alive: false },
		{ name: "control-node", type: "direct", alive: true },
		{ name: "DIRECT", type: "Hysteria2", alive: true }
	] },
	"SOURCE-BETA": { proxies: [
		{ name: "shared-node", type: "Hysteria2", alive: false }
	] }
};
for (let name, group in proxy_state) group.extra = { [speed_url]: { alive: group.alive } };
for (let name, provider in provider_state) for (let node in provider.proxies) node.extra = { [speed_url]: { alive: node.alive } };
if (provider_group_leaf(proxy_state, provider_state, "SOURCE-ALPHA", "alpha-korea") != "shared-node" ||
	provider_group_leaf(proxy_state, provider_state, "SOURCE-BETA", "alpha-korea") != null ||
	provider_group_leaf(proxy_state, provider_state, "SOURCE-ALPHA", "alpha-dead") != null ||
	provider_group_leaf(proxy_state, provider_state, "SOURCE-ALPHA", "alpha-control") != null ||
	provider_group_leaf(proxy_state, provider_state, "SOURCE-ALPHA", "alpha-direct-name") != "DIRECT" ||
	provider_group_current_leaf(proxy_state, provider_state, "SOURCE-ALPHA", "alpha-dead") != "dead-node" ||
	provider_group_current_leaf(proxy_state, provider_state, "SOURCE-BETA", "alpha-dead") != null ||
	provider_group_current_leaf(proxy_state, provider_state, "SOURCE-ALPHA", "alpha-control") != null) {
	print("manifest_bound_provider_leaf_failed\n");
	exit(1);
}

provider_state['SOURCE-ALPHA'].proxies[0].alive = false;
proxy_state['alpha-korea'].alive = false;
if (provider_group_leaf(proxy_state, provider_state, 'SOURCE-ALPHA', 'alpha-korea') != 'shared-node') die('other_url_failure_vetoed_speed_success');
provider_state['SOURCE-ALPHA'].proxies[0].alive = true;
proxy_state['alpha-korea'].alive = true;
provider_state['SOURCE-ALPHA'].proxies[0].extra[speed_url].alive = false;
if (provider_group_leaf(proxy_state, provider_state, 'SOURCE-ALPHA', 'alpha-korea') != null) die('other_url_success_accepted_speed_failure');
delete provider_state['SOURCE-ALPHA'].proxies[0].extra[speed_url];
if (provider_group_leaf(proxy_state, provider_state, 'SOURCE-ALPHA', 'alpha-korea') != null) die('missing_speed_health_accepted');

// A provider health check failed before the group's later successful URLTest.
const leaf_health = { alive:false, history:[{time:'2026-09-10T01:21:17.007Z',delay:0}] };
const group_health = { alive:true, history:[{time:'2026-09-10T01:21:26.72698878Z',delay:254}] };
provider_state['SOURCE-ALPHA'].proxies[0].extra[speed_url] = leaf_health;
proxy_state['alpha-korea'].extra[speed_url] = group_health;
const diagnose = use('models.selector').provider_group_measurement_reason;
if (provider_group_leaf(proxy_state,provider_state,'SOURCE-ALPHA','alpha-korea') != 'shared-node' ||
	diagnose(proxy_state,provider_state,'SOURCE-ALPHA','alpha-korea',speed_url) != null) die('newer_group_success_vetoed');
leaf_health.history[0].time = '2026-09-10T01:21:27Z';
if (provider_group_leaf(proxy_state,provider_state,'SOURCE-ALPHA','alpha-korea') != null ||
	diagnose(proxy_state,provider_state,'SOURCE-ALPHA','alpha-korea',speed_url) != 'leaf_latency_failed') die('newer_leaf_failure_ignored');
leaf_health.history[0].time = '2026-09-10T01:21:26.726988780Z';
if (provider_group_leaf(proxy_state,provider_state,'SOURCE-ALPHA','alpha-korea') != null) die('equal_timestamp_failure_ignored');
leaf_health.history[0].time = 'not-a-time';
if (provider_group_leaf(proxy_state,provider_state,'SOURCE-ALPHA','alpha-korea') != null) die('unknown_timestamp_failure_ignored');
leaf_health.history[0].time = '2026-09-10T01:21:17Z';
group_health.alive = false;
if (provider_group_leaf(proxy_state,provider_state,'SOURCE-ALPHA','alpha-korea') != null) die('failed_group_history_accepted');
group_health.alive = true;
delete provider_state['SOURCE-ALPHA'].proxies[0].extra[speed_url];
if (provider_group_leaf(proxy_state,provider_state,'SOURCE-ALPHA','alpha-korea') != null) die('missing_leaf_target_accepted');

const summary_entry = {
	providers: {
		alpha: { source_name: "SOURCE-ALPHA" },
		missing: { source_name: "SOURCE-MISSING" }
	},
	candidate_groups: [
		{ name: "alpha-korea", provider: "alpha", region: "korea" },
		{ name: "alpha-control", provider: "alpha", region: "control" },
		{ name: "alpha-direct-name", provider: "alpha", region: "named" }
	]
};
const summary_providers = {
	"SOURCE-ALPHA": { proxies: [
		{ name: "shared-node", type: "Hysteria2", alive: true, server: "203.0.113.9" },
		{ name: "dead-node", type: "Vless", alive: false, server: "203.0.113.10" },
		{ name: "control-node", type: "direct", alive: true },
		{ name: "DIRECT", type: "Hysteria2", alive: true }
	] }
};
for (let name, provider in summary_providers) for (let node in provider.proxies) node.extra = { [speed_url]: { alive: node.alive } };
function source_by_id(summary, provider_id) {
	const sources = summary?.sources ?? [];
	for (let i = 0; i < length(sources); i++) {
		if (sources[i]?.provider_id == provider_id) {
			return sources[i];
		}
	}
	return null;
};

const unavailable = provider_round_summary(summary_entry, proxy_state, null);
const missing_source = provider_round_summary(summary_entry, proxy_state, {});
const empty_source = provider_round_summary(summary_entry, proxy_state, { "SOURCE-ALPHA": { proxies: [] } });
const dead_source = provider_round_summary(summary_entry, proxy_state, {
	"SOURCE-ALPHA": { proxies: [{ name: "dead-node", type: "Vless", alive: false }] }
});
const mixed = provider_round_summary(summary_entry, proxy_state, summary_providers);
const encoded = sprintf("%J", mixed);
const mixed_alpha = source_by_id(mixed, "alpha");
const mixed_missing = source_by_id(mixed, "missing");
if (unavailable?.reason != "provider_state_unavailable" ||
	source_by_id(missing_source, "alpha")?.reason != "source_not_loaded" ||
	source_by_id(missing_source, "missing")?.reason != "source_not_loaded" ||
	source_by_id(empty_source, "alpha")?.reason != "zero_nodes" ||
	source_by_id(empty_source, "alpha")?.node_count != 0 ||
	source_by_id(dead_source, "alpha")?.reason != "zero_alive_nodes" ||
	source_by_id(dead_source, "alpha")?.node_count != 1 ||
	source_by_id(dead_source, "alpha")?.alive_count != 0 ||
	mixed_alpha?.reason != "ready" || mixed_alpha?.node_count != 3 ||
	mixed_alpha?.alive_count != 2 || mixed_missing?.reason != "source_not_loaded" ||
	mixed?.groups?.[0]?.reason != "ready" || mixed?.groups?.[1]?.reason != "control_fallback" ||
	mixed?.groups?.[2]?.reason != "ready" ||
	index(encoded, "shared-node") >= 0 || index(encoded, "dead-node") >= 0 ||
	index(encoded, "control-node") >= 0 || index(encoded, "203.0.113") >= 0 ||
	index(encoded, "SOURCE-ALPHA") >= 0 || index(encoded, "Bearer") >= 0) {
	print("provider_round_summary_leaked_or_miscounted\n");
	exit(1);
}

let result = choose_automatic([
	candidate("near-node", "p1", "near", 100, 10, "primary"),
	candidate("current-node", "p2", "current", 200, 10, "primary")
], policy, "standard", "current");
if (!result.ok || result.region_id != "current") {
	print("margin_hold_failed\n");
	exit(1);
}

result = choose_automatic([
	candidate("fast-node", "p1", "fast", 40, 10, "primary"),
	candidate("current-node", "p2", "current", 200, 10, "primary")
], policy, "standard", "current");
if (!result.ok || result.region_id != "fast") {
	print("margin_switch_failed\n");
	exit(1);
}

result = choose_automatic([
	candidate("near-node", "p1", "near", 49, 10, "primary"),
	candidate("current-node", "p2", "current", 93, 10, "primary")
], policy, "standard", "current");
if (!result.ok || result.region_id != "current" || result.changed_region != false) {
	print("remeasure_did_not_keep_healthy_region\n"); exit(1);
}

const capability_margin = json(sprintf("%J", policy));
capability_margin.capabilities.standard.region_switch_margin_ms = 200;
result = choose_automatic([
	candidate("fast-node", "p1", "fast", 40, 10, "primary"),
	candidate("current-node", "p2", "current", 200, 10, "primary")
], capability_margin, "standard", "current");
if (!result.ok || result.region_id != "current") {
	print("capability_margin_override_failed\n");
	exit(1);
}

const omitted_margin = json(sprintf("%J", policy));
omitted_margin.selection = {};
result = choose_automatic([
	candidate("fast-node", "p1", "fast", 40, 10, "primary"),
	candidate("current-node", "p2", "current", 189, 10, "primary")
], omitted_margin, "standard", "current");
if (!result.ok || result.region_id != "current") {
	print("default_margin_keep_failed\n");
	exit(1);
}
result = choose_automatic([
	candidate("fast-node", "p1", "fast", 40, 10, "primary"),
	candidate("current-node", "p2", "current", 200, 10, "primary")
], omitted_margin, "standard", "current");
if (!result.ok || result.region_id != "fast") {
	print("default_margin_switch_failed\n");
	exit(1);
}

result = choose_automatic([
	candidate("exhausted", "p1", "fast", 1, 0, "primary"),
	candidate("usable", "p2", "current", 100, 1, "primary")
], policy, "standard", "current");
if (!result.ok || result.candidate_id != "usable") {
	print("quota_filter_failed\n");
	exit(1);
}

result = choose_automatic([
	candidate("low-quota", "p1", "current", 100, 1, "primary"),
	candidate("high-quota", "p2", "current", 100, 100, "primary")
], policy, "standard", "current");
if (!result.ok || result.candidate_id != "high-quota") {
	print("quota_tie_break_failed\n");
	exit(1);
}

result = choose_automatic([
	candidate("COMPATIBLE", "p1", "fast", 1, 100, "primary", false),
	candidate("real-node", "p2", "current", 100, 1, "primary")
], policy, "standard", "current");
if (!result.ok || result.candidate_id != "real-node") {
	print("placeholder_candidate_filter_failed\n");
	exit(1);
}

result = choose_automatic([
	candidate("DIRECT", "p1", "fast", 1, 100, "primary", true),
	candidate("slower-node", "p2", "current", 200, 1, "primary")
], policy, "standard", null);
if (!result.ok || result.candidate_id != "DIRECT") {
	print("verified_leaf_name_was_treated_as_identity\n");
	exit(1);
}

result = choose_automatic([
	candidate("dead-primary", "p1", "fast", 1, 0, "primary"),
	candidate("reserve-node", "p2", "current", 120, null, "reserve")
], policy, "standard", "current");
if (!result.ok || result.candidate_id != "reserve-node" || result.layer != "reserve") {
	print("reserve_fallback_failed\n");
	exit(1);
}

result = choose_automatic([
	candidate("ai-hk", "p1", "hong_kong", 20, 10, "primary", true, "ai-compatible"),
	candidate("ai-near", "p2", "near", 80, 10, "primary", true, "ai-compatible")
], policy, "ai-compatible", null, "hong_kong");
if (!result.ok || result.region_id != "near" || result.reason != "fastest_eligible") {
	print("ai_excluded_preferred_region_failed\n");
	exit(1);
}

result = choose_automatic([
	candidate("ai-near", "p1", "near", 100, 10, "primary", true, "ai-compatible"),
	candidate("ai-fast", "p2", "fast", 20, 10, "primary", true, "ai-compatible")
], policy, "ai-compatible", null, "near");
if (!result.ok || result.region_id != "near" || result.reason != "followed_capability_region") {
	print("ai_followed_standard_region_failed\n");
	exit(1);
}

// Follow the same eligible node, and choose the fastest permitted alternative when excluded.
const parent = { provider_id: "p1", candidate_id: "common", region_id: "near", delay_ms: 47 };
result = choose_automatic([
 candidate("common", "p1", "near", 47, 10, "primary", true, "ai-compatible"),
 candidate("alternative", "p2", "fast", 51, 10, "primary", true, "ai-compatible")
], policy, "ai-compatible", null, "near", parent);
if (!result.ok || result.candidate_id != "common" || result.delay_ms != parent.delay_ms)
 die("follower must share eligible node and delay");
const excluded_parent = { provider_id: "p0", candidate_id: "excluded", region_id: "blocked" };
result = choose_automatic([
 candidate("allowed-fast", "p1", "near", 47, 10, "primary", true, "ai-compatible"),
 candidate("allowed-slow", "p2", "fast", 51, 10, "primary", true, "ai-compatible")
], policy, "ai-compatible", null, "blocked", excluded_parent);
if (!result.ok || result.candidate_id != "allowed-fast") die("excluded parent must choose fastest allowed node");

print("selection_contract_ok\n");

{
const factory = loadstring(readfile(replace(sourcepath(), /[^/]+$/, "../openwrt/files/usr/libexec/opl-netfleet/plugins/selection/lib/control.uc")))();
let writes=0, restored=0, failed=false, out=null;
const policy={main:{enabled:true},capabilities:{standard:{enabled:true}}};
const entry={name:"Exit",mode:"automatic",region_groups:[{name:"Singapore",region:"sg"}],candidate_groups:[{}]};
const manifest={generated_groups:{standard:entry}};
const services={
 "events.output":{fail:(action,error,detail)=>die(error),ok:(action,result)=>{out=result;}},
 "events.operation":{begin:()=>{},update:()=>{}},
 "events.record":{decision_event:()=>({}),record_events:()=>true},
 "mihomo.artifacts":{load_manifest:()=>manifest},
 "mihomo.controller":{protected_probes:()=>({ok:true}),proxies:()=>({proxies:{Exit:{now:"Automatic"}}}),select:()=>{restored++;return true;}},
 "mihomo.paths":{activate_manual_choice:()=>{writes++;return failed?{ok:false,error:"protected_probe_failed"}:{ok:true,leaf:"node",data_path:"manual_region"};},refresh_data_fallback:()=>true},
 "models.activation":{is_active:()=>true},
 "selection.algorithm":use("selection.algorithm"),
 "platform.profile":{current_profile:()=>"active"},
 "platform.credentials":{api_secret:()=>"fixture"},
};
function run(region) { return factory({argv:["select","standard",region,"luci","region"],use:name=>services[name]??{}}).select_action(policy,{}); }
run("sg"); if(writes!=1 || out.selected!="Singapore")die("manual region not activated");
for(let region in ["auto","DIRECT","Singapore","missing"]) { let denied=false;try{run(region);}catch(e){denied=true;} if(!denied||writes!=1)die("unauthorized write"); }
failed=true;try{run("sg");}catch(e){} if(restored!=1)die("failed activation not restored");
policy.capabilities.standard.enabled=false;try{run("sg");}catch(e){}if(writes!=2)die("disabled capability written");
policy.capabilities.standard.enabled=true;
let kept_current=false;
services["models.selection-view"]={public_candidates:items=>items};
services["models.ordering"]={automatic_capability_order:()=>["standard"],automatic_provider_sources:()=>[]};
services["mihomo.latency"]={measure_providers:()=>true};
services["mihomo.paths"].selection_group=()=>"Selector";
services["mihomo.paths"].reset_candidate_groups=()=>true;
services["selection.round"]={automatic_round:(p,m,e,n,s,b,st,pm,pr,shared)=>{kept_current=b;return {ok:false,error:"no_candidates"};}};
factory({argv:[],use:name=>services[name]??{}}).automatic_select_action(policy,"standard",{},"manual","luci");
if(kept_current!=true)die("manual remeasure bypassed region stickiness");

}
{
const factory = loadfile(replace(sourcepath(), /[^/]+$/, "../openwrt/files/usr/libexec/opl-netfleet/plugins/selection/lib/round.uc"))() ;
let samples = 0, healthy = true;
const state = {proxies: {shared: {all: ["common"], now: "common"}}};
const services = {
 "mihomo.controller": {proxies: () => state, proxy_providers: () => ({providers: {}})},
 "mihomo.latency": {measure: () => { samples++; return {target: speed_url, results: healthy ? {shared: {status: "ok", delay_ms: 47}} : {}}; }, complete_from_fresh_history: round => round},
 "mihomo.paths": {selection_group: entry => entry.name, reset_candidate_groups: () => true,
  candidate_provider_leaves_ready: () => true, candidate_group_names: entry => map(entry.candidate_groups, g => g.name)},
 "models.selector": {provider_group_leaf: () => "common", provider_group_measurement_reason: () => null, provider_round_summary: () => ({})},
 "selection.algorithm": use("selection.algorithm"), "models.status": {resolve_runtime: () => ({region_id: "fast"})},
 "subscriptions.facts": {provider_quotas: () => ({})}
};
const round = factory({use: name => services[name]}).automatic_round;
const entry = {name: "first", providers: {p1: {source_name: "source"}}, candidate_groups: [{name: "shared", provider: "p1", region: "near", role: "primary", filter: "near"}]};
const manifest = {generated_groups: {standard: entry, "ai-compatible": {...entry, name: "second"}}};
const local_policy = {...policy, checks: {latency: {url: speed_url}}};
const shared = {entries: {}, prepared: true};
const first = round(local_policy, manifest, entry, "standard", "fixture", true, state, true, null, shared);
const second = round(local_policy, manifest, manifest.generated_groups["ai-compatible"], "ai-compatible", "fixture", true, state, true, "near", shared, first.decision);
if (samples != 1 || !second.ok || first.decision.candidate_id != second.decision.candidate_id || first.decision.delay_ms != second.decision.delay_ms)
 die("two exits must share a single measured URLTest owner and delay");
healthy = false;
const failed_shared = {entries: {}, prepared: true};
round(local_policy, manifest, entry, "standard", "fixture", true, state, false, null, failed_shared);
const failed = round(local_policy, manifest, manifest.generated_groups["ai-compatible"], "ai-compatible", "fixture", true, state, false, null, failed_shared);
if (samples != 2 || failed.ok) die("same failed measurement must not be retried under another exit name");
}
release_services();
