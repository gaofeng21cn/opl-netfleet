import * as fs from "fs";

// Compose real service factories against alternate capabilities, without an
// OpenWrt host, native modules, credentials, or filesystem mutation outside /tmp.
const root = fs.realpath(replace(sourcepath(), /[^/]+$/, "../openwrt/files/usr/libexec/opl-netfleet"));
const system = json(fs.readfile(`${root}/../../share/opl-netfleet/system.json`));
const workspace = fs.mkdtemp("/tmp/netfleet-portable.XXXXXX");
if (workspace == null) die("workspace unavailable");
const storage = {}, ports = {}, instances = {}, loading = {}, loaded = [];
const commands = [], results = [];
let assertions = 0, current_profile = "file:OPL-NetFleet.json", backend_enabled = true;
let healthy = true, pending_recovery = null, selection_ok = true, writes_ok = true;
function check(value, message) { if (!value) die(message); assertions++; };
function clone(value) { return json(sprintf("%J", value)); };
function use(name) {
	if (ports[name] != null) return ports[name];
	if (instances[name] != null) return instances[name];
	if (loading[name]) die(`dependency cycle: ${name}`);
	check(index(name, "models.") == 0 || index(name, "selection.") == 0 ||
		index(["compilation.compiler", "platform.documents", "scheduler.control"], name) >= 0,
		`unexpected platform dependency: ${name}`);
	loading[name] = true;
	const owner = system.bindings[name];
	const manifest = json(fs.readfile(`${root}/plugins/${owner}/manifest.json`));
	const service = manifest.services[name];
	for (let dependency, major in service.requires) {
		check(major == 1, `unsupported interface ${dependency}`);
		use(dependency);
	}
	const factory = loadfile(`${root}/plugins/${owner}/${service.module}`)();
	instances[name] = factory({ argv: ["select", "standard", "auto"], use: dependency => {
		check(service.requires[dependency] == 1, `undeclared ${dependency}`);
		return use(dependency);
	} });
	delete loading[name]; push(loaded, name);
	return instances[name];
};
const paths = { POLICY_PATH: `${workspace}/policy.json`, EVIDENCE_PATH: `${workspace}/evidence.json` };
ports["platform.paths"] = paths;
ports["platform.storage"] = {
	read_json: path => storage[path] == null ? null : clone(storage[path]),
	mkdir: path => path == workspace,
	write_json_atomic: (path, value) => {
		if (!writes_ok) return false;
		storage[path] = clone(value); return true;
	}
};
ports["platform.profile"] = { current_profile: () => current_profile, backend_enabled: () => backend_enabled };
ports["platform.credentials"] = { api_secret: () => "fixture-only" };
ports["platform.process"] = { run_owner: (action, detail) => { push(commands, {action, detail}); return true; } };
ports["events.operation"] = { begin: () => true, update: () => true };
ports["events.output"] = {
	ok: (action, result) => push(results, {action, result}),
	fail: (action, error) => die(`${action}:${error}`)
};
ports["events.record"] = { decision_event: action => ({action}), record_events: () => true };
ports["recovery.control"] = {
	guarded_mutation: (action, policy, work) => work(),
	restore_recovery_with_probes: () => ({ok: true, mode: "recovery"})
};
ports["recovery.state"] = { pending: () => pending_recovery };
ports["mihomo.backend"] = {
	running: () => true,
	lan_runtime_state: () => ({transparent_proxy_ready: healthy, dns_ready: healthy})
};

try {
	const policy = json(fs.readfile(`${root}/../../../etc/opl-netfleet/policy.example.json`));
	policy.main.enabled = true;
	policy.policy_source = {kind: "profile", ref: "file:base.json"};
	policy.bindings = { Outbound: {capability: "standard", kind: "entry"} };
	policy.providers = { alpha: {section: "alpha", enabled: true, role: "primary"} };
	policy.regions = { near: {mode: "automatic"}, far: {mode: "automatic"} };
	policy.provider_regions = { alpha: [{region: "near", filter: "near"}, {region: "far", filter: "far"}] };
	policy.capabilities = { standard: {enabled: true, mode: "automatic"} };
	policy.evidence.path = paths.EVIDENCE_PATH;
	storage[paths.POLICY_PATH] = policy;
	const documents = use("platform.documents");
	check(documents.load_policy()?.main.enabled == true, "policy accepts alternate storage location");
	storage[paths.POLICY_PATH].evidence.path = "/unexpected/evidence.json";
	check(documents.load_policy() == null, "mismatched store rejected before execution");
	storage[paths.POLICY_PATH].evidence.path = paths.EVIDENCE_PATH;

	const provider = { path: `${workspace}/alpha.json`, runtime_path: `${workspace}/alpha.json`,
		profile: {proxies: [{name: "near-node"}, {name: "far-node"}]} };
	const digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
	const compiled = use("compilation.compiler").compile({
		"proxy-groups": [{name: "Outbound", type: "select", proxies: ["DIRECT"]}],
		rules: ["MATCH,Outbound"]
	}, policy, digest, digest, digest, {alpha: provider});
	check(compiled.ok && length(compiled.manifest.generated_groups.standard.candidate_groups) == 2,
		"shared compiler builds both regions with alternate provider paths");
	const manifest = compiled.manifest, entry = manifest.generated_groups.standard;
	manifest.artifact_sha256 = digest;
	let selected = null;
	const candidates = entry.candidate_groups;
	const near = filter(candidates, group => group.region == "near")[0];
	const state = {proxies: {}}, delays = {};
	for (let group in candidates) {
		const node = `${group.region}-node`;
		state.proxies[group.name] = {type: "URLTest", alive: true, now: node, all: [node], extra: { [policy.checks.latency.url]: { alive: true } }};
		delays[group.name] = {status: "ok", delay_ms: group.region == "near" ? 40 : 240};
	}
	state.proxies[entry.name] = {type: "Selector", now: entry.automatic_name};
	state.proxies[entry.selector_name] = {type: "Selector", now: null};
	const provider_state = { [entry.providers.alpha.source_name]: {
		proxies: [{name: "near-node", type: "Shadowsocks", alive: true}, {name: "far-node", type: "Shadowsocks", alive: true}]
	} };
	for (let node in provider_state[entry.providers.alpha.source_name].proxies) node.extra = { [policy.checks.latency.url]: { alive: true } };
	provider_state[entry.providers.alpha.source_name].proxies[0].alive = false;
	state.proxies[near.name].alive = false;
	ports["mihomo.artifacts"] = {load_manifest: () => manifest};
	ports["mihomo.controller"] = {
		protected_probes: () => ({ok: true}), proxies: () => state,
		proxy_providers: () => ({providers: provider_state}), controller_ready: () => true,
		select: () => true
	};
	let delay_calls = 0;
	ports["mihomo.latency"] = {measure: () => { delay_calls++; return {results: delays, target: policy.checks.latency.url}; }, measure_providers: () => true,
		complete_from_fresh_history: round => round};
	ports["mihomo.paths"] = {
		selection_group: value => value.selector_name,
		reset_candidate_groups: () => true, candidate_provider_leaves_ready: () => true,
		candidate_group_names: value => map(value.candidate_groups, group => group.name),
		activate_preferred_choice: (secret, value, group) => {
			selected = group;
			return {ok: selection_ok, leaf: state.proxies[group].now, data_path: "preferred"};
		},
		restore_runtime_selections: () => true
	};
	ports["subscriptions.facts"] = {provider_quotas: () => ({alpha: {state: "available"}})};
	const selection = use("selection.control");
	selection.command_select(["select", "standard", "auto"]);
	check(selected == near.name && results[-1]?.result.state == "selected", "real selection control chooses fastest eligible region");
	check(documents.load_evidence() != null, "selection persists valid evidence through alternate storage");
	provider_state[entry.providers.alpha.source_name].proxies[0].alive = true;
	provider_state[entry.providers.alpha.source_name].proxies[0].extra[policy.checks.latency.url].alive = false;
	state.proxies[near.name].alive = true;
	selection.command_select(["select", "standard", "auto"]);
	check(selected != near.name, "other URL success cannot authorize a failed speed test");
	const rejected_entry = filter(documents.load_evidence().capabilities.standard.entries, item => item.candidate == near.name)[0];
	check(rejected_entry.ok == false && rejected_entry.reason == 'leaf_latency_failed' && rejected_entry.measurement_reason == 'leaf_latency_failed', "excluded candidate remains visible with reason");
	provider_state[entry.providers.alpha.source_name].proxies[0].extra[policy.checks.latency.url].alive = true;
	const round = use("selection.round");
	const diagnosed = round.automatic_candidates(manifest, {alpha: {state: "exhausted"}}, state,
		provider_state, "standard", {target: policy.checks.latency.url, results: delays});
	check(diagnosed[0].available && diagnosed[0].reason == "quota_exhausted" && diagnosed[0].measurement_reason == null,
		"successful measurement and exhausted quota remain separate facts");
	const diagnose = use("models.selector").provider_group_measurement_reason;
	const source = entry.providers.alpha.source_name, url = policy.checks.latency.url;
	check(diagnose(state.proxies, {}, source, near.name, url) == "provider_nodes_unavailable", "missing provider inventory is explicit");
	const saved_health = provider_state[source].proxies[0].extra;
	provider_state[source].proxies[0].extra = {};
	check(diagnose(state.proxies, provider_state, source, near.name, url) == "leaf_latency_unrecorded", "missing URL health is not a failed connection");
	provider_state[source].proxies[0].extra = saved_health;
	push(provider_state[source].proxies, clone(provider_state[source].proxies[0]));
	check(diagnose(state.proxies, provider_state, source, near.name, url) == "leaf_identity_ambiguous", "duplicate identity is distinct from network health");
	pop(provider_state[source].proxies);
	const child = clone(entry);
	policy.capabilities.secondary = {enabled: true, mode: "automatic"};
	child.candidate_groups = clone(entry.candidate_groups);
	manifest.generated_groups.secondary = child;
	for (let i = 0; i < length(child.candidate_groups); i++) {
		const original = entry.candidate_groups[i].name, name = child.candidate_groups[i].name;
		state.proxies[name] = clone(state.proxies[original]);
		delays[name] = delays[original];
	}
	const shared = {entries: {}, prepared: true};
	delay_calls = 0;
	round.automatic_round(policy, manifest, entry, "standard", "fixture", false, state, true, null, shared);
	const same = round.automatic_round(policy, manifest, child, "secondary", "fixture", false, state, true, null, shared);
	check(same.ok && delay_calls == 1, "equivalent exit candidates reuse one physical measurement round");
	child.candidate_groups[0].filter = "different-scope";
	round.automatic_round(policy, manifest, child, "secondary", "fixture", false, state, true, null, shared);
	check(delay_calls == 2, "different candidate scopes cannot reuse measurements");
	delete policy.capabilities.secondary;
	delete manifest.generated_groups.secondary;
	selection_ok = false;
	let rejected = false;
	try { selection.command_select(["select", "standard", "auto"]); }
	catch (error) { rejected = index(error.message, "automatic_selection_failed") >= 0; }
	check(rejected, "failed runtime change is not reported as a successful selection");
	writes_ok = false;
	check(documents.write_evidence(documents.load_evidence()) == false, "storage failure propagated");
	writes_ok = true;

	const scheduler = use("scheduler.control");
	let tick = scheduler.tick(null);
	check(commands[-1]?.action == "maintain" && tick.state.was_runtime_ready, "scheduler dispatches selection through platform capability");
	const now = int(time());
	scheduler.tick({...tick.state, next_refresh_at: now - 1});
	check(commands[-1]?.action == "refresh", "scheduled refresh uses the same command provider");
	healthy = false;
	scheduler.tick({...tick.state, unhealthy_since: now - 600});
	check(commands[-1]?.action == "recover", "unhealthy runtime dispatches recovery");
	current_profile = policy.recovery_profile.ref;
	pending_recovery = {retry_at: now - 1};
	scheduler.tick(tick.state);
	check(commands[-1]?.action == "resume", "recovery retry delegates to the owner");
	storage[paths.POLICY_PATH].main.enabled = false;
	const before = length(commands);
	tick = scheduler.tick(tick.state);
	check(length(commands) == before && tick.state.next_selection_at == null, "disabled policy clears schedule without dispatch");
	check(index(loaded, "selection.round") >= 0 && index(loaded, "selection.algorithm") >= 0,
		"selection uses the shipped round and algorithm");
} catch (error) { fs.rmdir(workspace); die(error.message); }
fs.rmdir(workspace);
printf("portable services: %d assertions passed\n", assertions);
