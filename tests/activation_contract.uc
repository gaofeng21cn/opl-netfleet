#!/usr/bin/ucode
import * as fs from "fs";
import { use, release as release_services } from "./services.uc";

function test_activation_model() {
	const recovery_owner = use("models.activation").recovery_owner;
	const recovery_profile = use("models.activation").recovery_profile;
	const passthrough_outcome = use("models.activation").passthrough_outcome;
	const preferred_runtime_ready = use("models.activation").preferred_runtime_ready;
	const expected_runtime_groups = use("models.activation").expected_runtime_groups;
	const expected_runtime_residue_groups = use("models.activation").expected_runtime_residue_groups;

	const digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
	const manifest = {
		kind: "opl-netfleet-manifest", schema_version: 2, state: "staged", provider_mode: "file-provider",
		recovery_profile: { ref: "subscription:recovery", sha256: digest }, artifact_sha256: digest
	};
	if (recovery_profile(manifest, digest, "file:OPL-NetFleet.json", digest) != "subscription:recovery" ||
		recovery_profile(manifest, digest, "subscription:recovery", digest) != "subscription:recovery" ||
		recovery_profile(manifest, "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "file:OPL-NetFleet.json", digest) != null ||
		recovery_profile(manifest, digest, "file:OPL-NetFleet.json", "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff") != null) {
		die("recovery_manifest_identity_failed");
	}
	const self_referencing = json(sprintf("%J", manifest));
	self_referencing.recovery_profile.ref = "file:OPL-NetFleet.json";
	if (recovery_profile(self_referencing, digest, "file:OPL-NetFleet.json", digest) != null) {
		die("recovery_manifest_self_reference_accepted");
	}

	if (!recovery_owner("file:OPL-NetFleet.json", "subscription:base", false) ||
		!recovery_owner("subscription:base", "file:OPL-NetFleet.json", false) ||
		!recovery_owner("file:opl-netfleet/mvp.json", "subscription:base", false) ||
		!recovery_owner("subscription:base", "subscription:base", true) ||
		recovery_owner("subscription:user-choice", "subscription:base", false)) {
		die("recovery_owner_scope_failed");
	}

	const preferred_runtime = {
		user_mode: "automatic", data_path: "preferred",
		selected_group: "常规出口 · JP 日本 · Alpha", leaf: "Alpha Japan 01", alive: true
	};
	if (!preferred_runtime_ready(preferred_runtime, preferred_runtime.selected_group) ||
		preferred_runtime_ready({ user_mode: "unknown", data_path: "preferred", selected_group: preferred_runtime.selected_group, leaf: preferred_runtime.leaf, alive: true }, preferred_runtime.selected_group) ||
		preferred_runtime_ready({ user_mode: "automatic", data_path: "unknown", selected_group: preferred_runtime.selected_group, leaf: preferred_runtime.leaf, alive: true }, preferred_runtime.selected_group) ||
		preferred_runtime_ready({ user_mode: "automatic", data_path: "preferred", selected_group: "旧地区", leaf: preferred_runtime.leaf, alive: true }, preferred_runtime.selected_group) ||
		preferred_runtime_ready({ user_mode: "automatic", data_path: "preferred", selected_group: preferred_runtime.selected_group, leaf: null, alive: true }, preferred_runtime.selected_group) ||
		preferred_runtime_ready({ user_mode: "automatic", data_path: "preferred", selected_group: preferred_runtime.selected_group, leaf: preferred_runtime.leaf, alive: false }, preferred_runtime.selected_group)) {
		die("preferred_runtime_readback_contract_failed");
	}

	const runtime_groups = expected_runtime_groups({
		generated_groups: {
			standard: {
				name: "常规出口", automatic_name: "常规出口 · 自动选优",
				selector_name: "常规出口 · 当前优选",
				user_members: ["常规出口 · 自动选优", "常规出口 · 🇭🇰 香港", "DIRECT"],
				direct_name: "DIRECT", direct_guard_name: "NetFleet · 直连护栏",
				region_groups: [{ name: "常规出口 · 🇭🇰 香港", primary_name: "常规出口 · 🇭🇰 香港 · 主用" }],
				providers: { alpha: { group: "常规出口 · Alpha 机场" } },
				candidate_groups: [{ name: "常规出口 · 🇭🇰 香港 · Alpha 机场", group: "常规出口 · Alpha 机场" }]
			}
		}
	});
	if (index(runtime_groups, "DIRECT") >= 0 ||
		index(runtime_groups, "NetFleet · 直连护栏") < 0 ||
		index(runtime_groups, "常规出口 · 自动选优") < 0 ||
		index(runtime_groups, "常规出口 · 🇭🇰 香港 · Alpha 机场") < 0) {
		die("runtime_owner_groups_failed");
	}
	const residue_groups = expected_runtime_residue_groups({
		generated_groups: { standard: { name: "原生入口", automatic_name: "自动选优", direct_guard_name: "直连护栏" } }
	}, ["原生入口"]);
	if (index(residue_groups, "原生入口") >= 0 ||
		index(residue_groups, "自动选优") < 0 || index(residue_groups, "直连护栏") < 0) {
		die("native_entry_group_must_not_be_runtime_residue");
	}

	let result = passthrough_outcome({ ok: true }, true, false);
	if (!result.ok || !result.safe || !result.persistent || result.business_ok != false) die("direct_probe_failure_must_not_block_safe_passthrough");
	result = passthrough_outcome({ ok: true }, true, null);
	if (!result.ok || result.business_ok != null) die("unavailable_business_probe_must_remain_unknown");
	result = passthrough_outcome({ ok: true }, false, true);
	if (result.ok || !result.safe || result.persistent || result.business_ok != true) die("missing_persistence_must_block_completion");
	result = passthrough_outcome({ ok: false }, true, true);
	if (result.ok || result.safe || !result.persistent) die("unverified_cleanup_must_not_claim_passthrough");
	result = passthrough_outcome({ ok: true }, true, "unavailable");
	if (!result.ok || result.business_ok != null) die("non_boolean_business_probe_must_remain_unknown");
	print("activation_contract_ok\n");
}

function test_operating_mode() {
	const root = replace(sourcepath(), /[^/]+$/, "../plugins/");
	const model = loadfile(root + "models/lib/activation.uc")()({});
	const operation_directory = fs.mkdtemp("/tmp/netfleet-mode-progress.XXXXXX");
	const operation_context = { use: name => name == "platform.paths" ? { OPERATION_DIR: operation_directory } :
		{ process_identity: () => ({ pid: 100, started: "fixture", alive: true }) } };
	const operation_factory = loadfile(root + "events/lib/operation.uc")();
	const operation = operation_factory(operation_context);
	let phases = [], finished = 0;
	const output = loadfile(root + "events/lib/output.uc")()({ use: () => ({ finish: () => { finished++; } }) });
	let state, writes, starts, stops, compilation_error, activation_error, restore_error, cleanup_error, compatibility_error, policy, enable_failures;
	function check(value, message) { if (!value) die(message); }
	function reset(mode) {
		state = { profile: mode == "netfleet" ? "file:OPL-NetFleet.json" : "subscription:original",
			enabled: mode != "openwrt", running: mode != "openwrt", present: mode == "netfleet",
			supervisor: { installed: true, enabled: mode == "netfleet", running: mode == "netfleet" },
			compatibility: { installed: false, enabled: false, running: false } };
		writes = 0; starts = 0; stops = 0; phases = [];
		enable_failures = [];
		compilation_error = false; activation_error = false; restore_error = false; cleanup_error = false; compatibility_error = false;
		policy = { recovery_profile: { ref: "subscription:recovery" } };
	}
	const services = {
		"models.activation": model,
		"events.output": output,
		"events.operation": { ...operation, update: (phase, details) => { push(phases, phase); return operation.update(phase, details); } },
		"events.record": { record_enable_failure: (...args) => { push(enable_failures, args); return true; } },
		"platform.profile": {
			current_profile: () => state.profile, backend_enabled: () => state.enabled,
			set_backend_enabled: value => { writes++; state.enabled = value; return true; }
		},
		"mihomo.backend": {
			running: () => state.running, profile_exists: ref => type(ref) == "string",
			cleanup_state: () => ({ ok: !state.running && !cleanup_error }),
			stop: () => { writes++; stops++; state.running = false; state.present = false; return { ok: !cleanup_error }; }
		},
		"mihomo.controller": { proxies: () => ({ proxies: {} }) },
		"mihomo.readback": { state_has_netfleet: () => state.present },
		"platform.storage": { read_json: () => ({}) },
		"platform.credentials": { api_secret: () => "fixture" },
		"platform.documents": { load_policy: () => policy, load_evidence: () => ({}) },
		"platform.service": {
			service_state: name => ({ ...(name == "opl-netfleet-compat" ? state.compatibility : state.supervisor) }),
			set_service_state: (desired, name) => {
				writes++;
				if (name == "opl-netfleet-compat") {
					if (compatibility_error) return { ok: false };
					state.compatibility = { installed: true, ...desired };
				} else state.supervisor = { installed: true, ...desired };
				return { ok: true };
			}
		},
		"recovery.state": { clear: () => { writes++; return true; } },
		"recovery.control": { restore_profile_with_probes: (ref, policy) => {
			writes++; starts++; state.profile = ref; state.present = false; state.running = !restore_error;
			return { runtime_ok: !restore_error, business_ok: false };
		} },
		"compilation.control": { compile_result: () => ({ ok: !compilation_error, error: "fixture_compile_failure" }) },
		"activation.control": { enable_action: (policy, evidence, quiet, progress) => {
			writes++; starts++; state.profile = "file:OPL-NetFleet.json"; state.present = true; state.running = true;
			progress("probing");
			progress("resetting_candidates", { subject: "standard", total: 2, completed: 0 });
			if (activation_error) output.fail("enable", "fixture_activation_failure", { stage: "switched" });
			progress("activating_exit", { completed: 2 });
		} }
	};
	try {
		const factory = loadfile(root + "activation/lib/mode.uc")();
		const mode = factory({ instance: "default", use: name => services[name] });
		for (let from in ["openwrt", "mihomo", "netfleet"]) {
			for (let to in ["openwrt", "mihomo", "netfleet"]) {
				reset(from);
				const result = mode.set({ mode: to, expected_mode: from });
				check(result.ok && result.result.mode == to, `transition ${from} -> ${to}`);
				check(operation.get("mode").state == "succeeded" && operation.get("mode").requested_mode == to &&
					operation.get("mode").actual_mode == to, "terminal operation must retain the requested and confirmed modes");
				if (from == to) check(starts == 0 && stops == 0 && result.result.unchanged, "idempotent mode must not restart core");
				if (to != "netfleet") check(!state.supervisor.enabled && !state.supervisor.running, "native mode must persist scheduler shutdown");
			}
		}
		reset("mihomo");
		check(!mode.set({ mode: "openwrt", expected_mode: "netfleet" }).ok && writes == 0, "stale mode must not mutate");
		check(!mode.set({ mode: "openwrt", expected_mode: "mihomo", extra: true }).ok && writes == 0, "unknown field must not mutate");
		const scoped = factory({ instance: "other", use: name => services[name] });
		check(!scoped.set({ mode: "openwrt", expected_mode: "mihomo" }).ok && writes == 0, "named instance cannot control host mode");
		reset("mihomo"); state.supervisor.enabled = true;
		check(mode.get().result.mode == null, "enabled scheduler is not persistent native mode");
		check(mode.set({ mode: "mihomo", expected_mode: null }).ok && starts == 0 && !state.supervisor.enabled, "repair persistence without restarting healthy native core");
		reset("netfleet"); state.supervisor.running = false;
		check(mode.set({ mode: "netfleet", expected_mode: null }).ok && starts == 0, "restore scheduler without restarting enhanced core");
		reset("netfleet"); policy = null;
		check(mode.set({ mode: "openwrt", expected_mode: "netfleet" }).ok, "policy loss must not block direct cleanup");
		reset("openwrt"); policy = null;
		check(mode.set({ mode: "mihomo", expected_mode: "openwrt" }).ok, "native profile remains usable without enhancement policy");
		reset("mihomo"); compilation_error = true;
		check(!mode.set({ mode: "netfleet", expected_mode: "mihomo" }).ok && mode.get().result.mode == "mihomo" && stops == 0,
			"compile failure preserves recovered native runtime");
		reset("mihomo"); activation_error = true;
		const failed = mode.set({ mode: "netfleet", expected_mode: "mihomo" });
		check(!failed.ok && failed.error == "fixture_activation_failure" && failed.result.mode == "mihomo" && finished == 0,
			"nested CLI failure returns to mode owner for native recovery without exiting or printing");
		check(length(enable_failures) == 1 && enable_failures[0][0] == "fixture_activation_failure" &&
			enable_failures[0][1].stage == "switched" && enable_failures[0][3].ok == true &&
			enable_failures[0][3].mode == "native", "failed mode activation records its stage after confirmed native recovery");
		const persisted_failure = operation_factory(operation_context).get("mode");
		check(persisted_failure.state == "failed" && persisted_failure.recovery == "native" &&
			persisted_failure.actual_mode == "mihomo" && persisted_failure.requested_mode == "netfleet" &&
			persisted_failure.subject == "standard" && persisted_failure.completed == 0 && persisted_failure.total == 2,
			"a fresh reader retains failed exit, partial count and confirmed native recovery");
		check(index(phases, "compiling") >= 0 && index(phases, "resetting_candidates") >= 0 &&
			index(phases, "rolling_back") > index(phases, "resetting_candidates"), "nested activation and recovery publish real phases under one operation");
		reset("openwrt"); restore_error = true;
		check(!mode.set({ mode: "mihomo", expected_mode: "openwrt" }).ok && mode.get().result.mode == "openwrt", "failed core startup cleans interception");
		reset("mihomo"); cleanup_error = true;
		check(!mode.set({ mode: "openwrt", expected_mode: "mihomo" }).ok && mode.get().result.mode == null, "cleanup failure cannot claim direct mode");
		check(operation.get("mode").recovery == "failed" && operation.get("mode").actual_mode == null,
			"unconfirmed cleanup must remain a failed recovery in persistent progress");
		check(output.capture(() => 42).result == 42, "failure capture must restore state after errors");
		operation.begin("mode", "resetting_candidates", { requested_mode: "netfleet" });
		operation.finish(false, "candidate_group_reset_failed", { mode: "mihomo", recovery: "native", detail: { cause: {
			group: "candidate", http_status: 404, transport_code: 0, attempts: 1, secret: "private", output: "private-response"
		} } });
		const reset_failure = operation_factory(operation_context).get("mode");
		check(reset_failure.failure_detail.http_status == 404 && reset_failure.failure_detail.attempts == 1 &&
			reset_failure.failure_detail.secret == null && reset_failure.failure_detail.output == null,
			"candidate failure keeps useful controller evidence without private command or response fields");
		for (let target in ["openwrt", "mihomo"]) {
			reset("mihomo"); state.compatibility = { installed: true, enabled: true, running: true };
			check(mode.get().result.mode == null, "optional engine prevents native-mode confirmation");
			check(mode.set({ mode: target, expected_mode: null }).ok && !state.compatibility.running && !state.compatibility.enabled,
				"native modes must stop optional engine persistently");
		}
		reset("netfleet"); state.compatibility = { installed: true, enabled: true, running: true }; compatibility_error = true;
		check(!mode.set({ mode: "openwrt", expected_mode: "netfleet" }).ok && stops == 0 && state.supervisor.running,
			"failed optional drain preserves core and does not claim direct mode");
		check(operation.get("mode").state == "failed" && operation.get("mode").recovery == "unchanged" &&
			operation.get("mode").actual_mode == "netfleet", "rejected drain reports the mode that remains confirmed");
	} catch (error) {
		fs.unlink(operation_directory + "/opl-netfleet-operation-mode.json");
		fs.rmdir(operation_directory);
		die(error.message);
	}
	fs.unlink(operation_directory + "/opl-netfleet-operation-mode.json");
	fs.rmdir(operation_directory);
	print("operating_mode_contract_ok\n");
}

function test_path_activation() {
	const plugins_root = fs.realpath(replace(sourcepath(), /[^/]+$/, "../plugins"));
	const factory = loadfile(`${plugins_root}/mihomo/lib/paths.uc`)();
	const calls = [];
	const warm_measures = [];
	let path_failed = false, guard_failed_on_preferred = false, stale = true, preferred_path_ok = false, preferred_guard_ok = false;
	const services = {
		"mihomo.controller": {
			proxies: () => ({ proxies: {} }), proxy_providers: () => ({ providers: {} }),
			unfix: group => true, select: () => true, protected_probes: () => ({ ok: true }),
			test_group_path: (secret, group, checks) => {
				push(calls, { group, url: checks.latency.url, timeout: checks.latency.timeout_ms, expected: checks.latency.expected_status });
				if (group == "preferred" && checks.latency.url == "https://business.test/path") {
					if (path_failed) return false;
					preferred_path_ok = true;
					return true;
				}
				if (group == "preferred" && checks.latency.url == "https://business.test/guard") {
					if (guard_failed_on_preferred) return false;
					preferred_guard_ok = true;
					return true;
				}
				if (group == "auto" && checks.latency.url == "https://business.test/guard") {
					if (preferred_path_ok && preferred_guard_ok) stale = false;
					return true;
				}
				return true;
			}
		},
		"mihomo.latency": { measure: (secret, group, checks) => { push(warm_measures, { group, url: checks.latency.url, expected: checks.latency.expected_status }); return { status: "ok", results: {} }; } },
		"mihomo.probes": { protected_probes_after_restart: () => ({ ok: true }) },
		"models.activation": { preferred_runtime_ready: r => r.data_path == "preferred" },
		"models.ordering": { sorted_keys: keys }, "models.policy": { automation: () => ({ startup_grace_seconds: 1 }) },
		"models.selector": { provider_group_leaf: () => "leaf" },
		"models.status": { resolve_runtime: () => ({ leaf: "leaf", data_path: stale ? "direct_fallback" : "preferred" }) },
		"platform.credentials": { api_secret: () => "fixture" }
	};
	const paths = factory({ use: name => services[name] });
	const entry = {
		name: "visible", selector_name: "preferred", automatic_name: "auto",
		providers: { alpha: { group: "alpha-group" } },
		fail_open_stages: [{ kind: "provider_tier", role: "primary", group: "primary-tier" }]
	};
	const policy = {
		checks: { latency: { url: "https://speed.test/204", timeout_ms: 2000 } },
		fail_open: {
			healthcheck: { path_probe_id: "path", guard_probe_id: "guard", timeout_ms: 15000 },
			probes: [{ id: "path", url: "https://business.test/path", expected_status: 200, head_expected_status: 404 },
				{ id: "guard", url: "https://business.test/guard", expected_status: 200 }]
		}
	};
	function check(value, reason) { if (!value) die(reason); }
	const ready = paths.wait_for_preferred_runtime("fixture", entry, "candidate", policy, {}, false);
	check(ready.preferred && !stale, "business URL health must revive the bound path");
	check(length(calls) == 5 && calls[0].group == "preferred" && calls[0].url == "https://business.test/path" && calls[0].expected == 404 &&
		calls[1].group == "preferred" && calls[1].url == "https://business.test/guard" && calls[1].expected == 200 &&
		calls[2].group == "auto" && calls[2].url == "https://business.test/guard" && calls[2].expected == 200 &&
		calls[3].group == "alpha-group" && calls[3].url == "https://business.test/guard" && calls[3].expected == 200 &&
		calls[4].group == "primary-tier" && calls[4].url == "https://business.test/guard" && calls[4].expected == 200 &&
		calls[0].timeout == 15000 && warm_measures[0].url == "https://business.test/guard",
		"distinct guard probe must refresh preferred selector and standby pools with guard URL before auto fallback");
	path_failed = true; guard_failed_on_preferred = false; stale = true; preferred_path_ok = false; preferred_guard_ok = false;
	const failed_path = paths.wait_for_preferred_runtime("fixture", entry, "candidate", policy, {}, false);
	check(failed_path.error == "selected_business_path_probe_failed" && failed_path.probe == "path" && failed_path.group == "preferred" &&
		failed_path.method == "HEAD" && failed_path.expected_status == 404 && stale && length(calls) == 6,
		"path probe failure must stop before guard probe and remain distinct from latency success");
	path_failed = false; guard_failed_on_preferred = true; stale = true; preferred_path_ok = false; preferred_guard_ok = false;
	const failed_guard = paths.wait_for_preferred_runtime("fixture", entry, "candidate", policy, {}, false);
	check(failed_guard.error == "selected_business_path_probe_failed" && failed_guard.probe == "guard" && failed_guard.group == "preferred" &&
		failed_guard.method == "HEAD" && failed_guard.expected_status == 200 && stale && length(calls) == 8,
		"preferred guard probe failure must stop before testing automatic fallback");
	guard_failed_on_preferred = false; stale = false; preferred_path_ok = false; preferred_guard_ok = false;
	const shared_policy = json(sprintf("%J", policy));
	shared_policy.fail_open.healthcheck.guard_probe_id = "path";
	const before_shared = length(calls);
	const shared_ready = paths.wait_for_preferred_runtime("fixture", entry, "candidate", shared_policy, {}, false);
	check(shared_ready.preferred && length(calls) - before_shared == 4 &&
		calls[before_shared].group == "preferred" && calls[before_shared + 1].group == "auto" &&
		calls[before_shared + 2].group == "alpha-group" && calls[before_shared + 3].group == "primary-tier",
		"shared path/guard probe must not re-probe preferred selector twice");
	splice(calls, 0, length(calls));
	print("path activation contracts passed\n");

	const policy_factory = loadfile(`${plugins_root}/mihomo/lib/interception-policy.uc`)()();
	const starting = {
		backend: 'native-mihomo', ready: true, compatibility_ownership_guard: true,
		router_proxy: true, lan_proxy: true, custom_lan_access: true, listener_identity_ready: false
	};
	check(policy_factory.admission({ rules: [] }, starting) == 'engine_starting', 'unready engine must not masquerade as a LAN policy conflict');
	starting.listener_identity_ready = true;
	check(policy_factory.admission({ rules: [] }, starting) == 'lan_access_not_equivalent', 'real policy conflicts remain rejected');
	starting.custom_lan_access = false;
	check(policy_factory.admission({ rules: [] }, starting) == null, 'ready equivalent gateway admitted');

	let measures = 0, selected_leaf = 'leaf';
	services['mihomo.latency'].measure = (secret, group, checks) => {
		if (checks.latency.url == policy.checks.latency.url) measures++;
		return { status: 'ok' };
	};
	services['mihomo.controller'].proxies = () => ({ proxies: { preferred: { all: ['candidate'] }, visible: { all: ['automatic'] } } });
	services['models.selector'].provider_group_leaf = () => selected_leaf;
	services['models.activation'].preferred_runtime_ready = r => r.data_path == 'preferred';
	path_failed = false; guard_failed_on_preferred = false; stale = false;
	const activation_paths = factory({ use: name => services[name] });
	const automatic_entry = { ...entry, automatic_name: 'automatic' };
	const activated = activation_paths.activate_preferred_choice('fixture', automatic_entry, 'candidate', policy, false, false, { group: 'candidate', candidate_id: 'leaf' });
	check(activated.ok && measures == 0, 'activation must consume measured evidence without a second speed probe');
	selected_leaf = 'changed-leaf';
	const changed = activation_paths.activate_preferred_choice('fixture', automatic_entry, 'candidate', policy, false, false, { group: 'candidate', candidate_id: 'leaf' });
	check(!changed.ok && changed.error == 'selected_leaf_unavailable' && measures == 0, 'changed leaf cannot inherit prior speed evidence');

	const saved_entry = { ...entry, candidate_groups: [{ name: 'old label', provider: 'airport', region: 'test' }] };
	let selection_state = { preferred: { now: 'old label', all: ['old label'] }, visible: { now: 'automatic', all: ['automatic'] } };
	const restored_choices = [];
	services['mihomo.controller'].proxies = () => ({ proxies: selection_state });
	services['mihomo.controller'].select = (secret, group, choice) => { push(restored_choices, { group, choice }); return true; };
	const restoration_paths = factory({ use: name => services[name] });
	const saved = restoration_paths.capture_runtime_selections({ generated_groups: { standard: saved_entry } });
	check(saved.ok && saved.selections.standard.preferred_identity.provider == 'airport', 'capture stable provider and region identity before a rename');
	selection_state = { preferred: { all: ['new label'] }, visible: { all: ['automatic'] } };
	const renamed_entry = { ...entry, candidate_groups: [{ name: 'new label', provider: 'airport', region: 'test' }] };
	check(restoration_paths.restore_runtime_selections('fixture', { generated_groups: { standard: renamed_entry } }, saved.selections, policy) &&
		restored_choices[0].choice == 'new label' && saved.selections.standard.preferred == 'old label', 'restore renamed candidate by stable identity and preserve rollback snapshot');
	check(!restoration_paths.restore_runtime_selections('fixture', { generated_groups: { standard: { ...entry, candidate_groups: [] } } }, saved.selections, policy), 'missing candidate identity cannot select a different provider');

	const cold_calls = [];
	let recovery_probes = { ok: true }, unfixed = false;
	services['mihomo.controller'].test_group_path = (secret, group, checks) => {
		push(cold_calls, [group, checks.latency.url]);
		return group != 'preferred';
	};
	services['mihomo.controller'].unfix = () => { unfixed = true; return true; };
	services['mihomo.controller'].protected_probes = () => die('cold restoration must use the bounded startup probe');
	services['mihomo.probes'].protected_probes_after_restart = () => recovery_probes;
	const cold_paths = factory({ use: name => services[name] });
	const cold_manifest = { generated_groups: { standard: { ...renamed_entry, automatic_name: 'automatic' } } };
	check(cold_paths.restore_runtime_selections('fixture', cold_manifest, saved.selections, policy, {}, true) && !unfixed,
		'cold restoration accepts a healthy standby without resetting the saved selection');
	check(cold_calls[0][0] == 'preferred' && cold_calls[0][1] == 'https://business.test/path' &&
		cold_calls[1][0] == 'preferred' && cold_calls[1][1] == 'https://business.test/guard' &&
		cold_calls[2][0] == 'automatic' && cold_calls[2][1] == 'https://business.test/guard',
		'a failed preferred HEAD does not block warming the automatic guard');
	const warm_count = length(cold_calls);
	selection_state.visible.all = ['manual-region'];
	const manual = { standard: { ...saved.selections.standard, visible: 'manual-region' } };
	check(cold_paths.restore_runtime_selections('fixture', cold_manifest, manual, policy, {}, true) &&
		length(cold_calls) == warm_count && restored_choices[length(restored_choices) - 1].choice == 'manual-region',
		'cold restoration keeps the original manual route');
	recovery_probes = { ok: false, error: 'protected_probe_failed' };
	const failure = {};
	check(!cold_paths.restore_runtime_selections('fixture', cold_manifest, manual, policy, failure, true) &&
		failure.error == 'protected_probe_failed', 'failed startup protection still requires lifecycle cleanup');

	for (let mode in ['off', 'strict', 'always', null]) {
		const profile = { rules: ['PROCESS-NAME,haproxy,REJECT', 'MATCH,DIRECT'] };
		if (mode != null) profile['find-process-mode'] = mode;
		check(policy_factory.admission(profile, starting) == (mode == 'off' ? null : 'source_or_unsupported_routing_rule'),
			'only explicitly disabled process lookup preserves relay routing');
	}
	check(policy_factory.admission({ 'find-process-mode': 'off', rules: ['PROCESS-NAME,,REJECT'] }, starting) != null,
		'empty process matcher remains unproven');
}

try {
	test_activation_model();
	test_operating_mode();
	test_path_activation();
} catch (error) {
	release_services();
	die(error.message);
}
release_services();
