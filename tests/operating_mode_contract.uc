import * as fs from "fs";

const root = replace(sourcepath(), /[^/]+$/, "../openwrt/files/usr/libexec/opl-netfleet/plugins/");
const model = loadfile(root + "models/lib/activation.uc")()({});
let finished = 0;
const output = loadfile(root + "events/lib/output.uc")()({ use: () => ({ finish: () => { finished++; } }) });
let state, writes, starts, stops, compilation_error, activation_error, restore_error, cleanup_error, compatibility_error, policy;
function check(value, message) { if (!value) die(message); }
function reset(mode) {
	state = { profile: mode == "netfleet" ? "file:OPL-NetFleet.json" : "subscription:original",
		enabled: mode != "openwrt", running: mode != "openwrt", present: mode == "netfleet",
		supervisor: { installed: true, enabled: mode == "netfleet", running: mode == "netfleet" },
		compatibility: { installed: false, enabled: false, running: false } };
	writes = 0; starts = 0; stops = 0;
	compilation_error = false; activation_error = false; restore_error = false; cleanup_error = false;
	compatibility_error = false;
	policy = { recovery_profile: { ref: "subscription:recovery" } };
}
const services = {
	"models.activation": model,
	"events.output": output,
	"platform.profile": {
		current_profile: () => state.profile, backend_enabled: () => state.enabled,
		set_backend_enabled: value => { writes++; state.enabled = value; return true; }
	},
	"mihomo.backend": {
		running: () => state.running,
		profile_exists: ref => type(ref) == "string",
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
	"activation.control": { enable_action: () => {
		writes++; starts++; state.profile = "file:OPL-NetFleet.json"; state.present = true; state.running = true;
		if (activation_error) output.fail("enable", "fixture_activation_failure", { stage: "switched" });
	} }
};
const factory = loadfile(root + "activation/lib/mode.uc")();
const mode = factory({ instance: "default", use: name => services[name] });
for (let from in ["openwrt", "mihomo", "netfleet"]) {
	for (let to in ["openwrt", "mihomo", "netfleet"]) {
		reset(from);
		const result = mode.set({ mode: to, expected_mode: from });
		check(result.ok && result.result.mode == to, `transition ${from} -> ${to}`);
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
reset("openwrt"); restore_error = true;
check(!mode.set({ mode: "mihomo", expected_mode: "openwrt" }).ok && mode.get().result.mode == "openwrt", "failed core startup cleans interception");
reset("mihomo"); cleanup_error = true;
check(!mode.set({ mode: "openwrt", expected_mode: "mihomo" }).ok && mode.get().result.mode == null, "cleanup failure cannot claim direct mode");
check(output.capture(() => 42).result == 42, "failure capture must restore state after errors");
for (let target in ["openwrt", "mihomo"]) {
	reset("mihomo"); state.compatibility = { installed: true, enabled: true, running: true };
	check(mode.get().result.mode == null, "optional engine prevents native-mode confirmation");
	check(mode.set({ mode: target, expected_mode: null }).ok && !state.compatibility.running && !state.compatibility.enabled,
		"native modes must stop optional engine persistently");
}
reset("netfleet"); state.compatibility = { installed: true, enabled: true, running: true }; compatibility_error = true;
check(!mode.set({ mode: "openwrt", expected_mode: "netfleet" }).ok && stops == 0 && state.supervisor.running,
	"failed optional drain preserves core and does not claim direct mode");
print("operating_mode_contract_ok\n");
