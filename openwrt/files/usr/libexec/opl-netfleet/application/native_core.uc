import * as fs from "fs";
import { read_json, sha256, shell_quote } from "../adapters/uci.uc";
import { BASE, CACHE, CORE, SERVICE, COMMAND, LOCK, private_file, private_directory,
	write_private, atomic_json, core_service, owned_service } from "../adapters/native.uc";
import { prepare } from "../core/native_core.uc";
import { get_state as sources_state } from "./native_sources.uc";
import { ok, fail } from "../output.uc";

const STAGE = `${BASE}/core.json`;
const CONFIG = `${CORE}/config.json`;
const SOCKET = `${CORE}/controller.sock`;

function api(path) {
	const process = fs.popen(`curl -q --silent --fail --noproxy '*' --proxy '' --max-time 2 ` +
		`--unix-socket ${shell_quote(SOCKET)} ${shell_quote(`http://localhost${path}`)} 2>/dev/null`);
	if (process == null) return null;
	let result = null;
	try { result = json(process); } catch (error) {}
	return process.close() == 0 ? result : null;
};

function service_call(action, payload) {
	return system(`ubus call service ${action} ${shell_quote(sprintf("%J", payload))} >/dev/null 2>&1`) == 0;
};

function load_stage() {
	if (!private_directory(BASE) || !private_file(STAGE)) return null;
	const stage = read_json(STAGE);
	return stage?.schema_version == 1 && type(stage.profile) == "object" && type(stage.sources) == "object" ? stage : null;
};

function prepared(input) {
	const sources = sources_state();
	if (!sources.ok) return sources;
	const by_id = {};
	for (let source in sources.result.sources) by_id[source.id] = source;
	return prepare(input, by_id);
};

function matches(stage) {
	const checked = prepared(stage?.profile);
	return checked.ok && sprintf("%J", checked.stage) == sprintf("%J", stage);
};

function status() {
	const owner = core_service();
	if (!owner.ok) return { ok: false, error: "procd_unavailable" };
	if (owner.service != null && !owned_service(owner.service)) return { ok: false, error: "core_owner_conflict" };
	const stage = load_stage();
	const instance = owner.service?.instances?.core;
	const command = instance?.pid ? fs.readfile(`/proc/${instance.pid}/cmdline`) : null;
	const running = instance?.running == true && command != null &&
		join("\u0000", COMMAND) + "\u0000" == command;
	const version = running ? api("/version") : null;
	const effective = version != null ? api("/configs") : null;
	const ready = running && type(version?.version) == "string" && stage != null &&
		private_file(CONFIG) && fs.readfile(CONFIG) == sprintf("%J", stage.profile) &&
		effective?.["mixed-port"] == stage.profile["mixed-port"] && effective?.["allow-lan"] == false;
	return { ok: true, result: {
		prepared: stage != null, registered: owner.service != null, running: running,
		controller_ready: ready, transparent_proxy: false,
		mixed_port: stage?.profile?.["mixed-port"] ?? null,
		config_sha256: private_file(CONFIG) ? sha256(CONFIG) : null,
		state: ready ? "running" : owner.service != null ? "not_ready" : "stopped"
	} };
};

function stop() {
	const owner = core_service();
	if (!owner.ok) return { ok: false, error: "procd_unavailable" };
	if (owner.service == null) return status();
	if (!owned_service(owner.service)) return { ok: false, error: "core_owner_conflict" };
	const pid = owner.service.instances.core.pid;
	if (!service_call("delete", { name: SERVICE })) return { ok: false, error: "core_stop_failed" };
	for (let i = 0; i < 7; i++) {
		const current = core_service();
		if (current.ok && current.service == null && (!pid || fs.stat(`/proc/${pid}`) == null)) {
			if (private_directory(CORE)) fs.unlink(SOCKET);
			return status();
		}
		system("sleep 1");
	}
	return { ok: false, error: "core_stop_unconfirmed" };
};

function validate_profile(profile) {
	const candidate = `${CORE}/candidate.json`;
	if (!write_private(candidate, sprintf("%J", profile))) return false;
	const valid = system(`SAFE_PATHS=${shell_quote(CACHE)} /usr/bin/mihomo -t -d ${shell_quote(CORE)} ` +
		`-f ${shell_quote(candidate)} >/dev/null 2>&1`) == 0;
	fs.unlink(candidate);
	return valid;
};

function execute(action, argument) {
	if (action == "native-core-status") return status();
	if (action == "native-core-stop") return stop();
	const owner = core_service();
	if (!owner.ok) return { ok: false, error: "procd_unavailable" };
	if (owner.service != null) {
		const current = status();
		return action == "native-core-start" && current.ok && current.result.controller_ready ? current :
			{ ok: false, error: "native_core_registered" };
	}
	if (fs.lstat("/etc/init.d/nikki") != null || fs.lstat("/etc/config/nikki") != null ||
		system("pidof mihomo >/dev/null 2>&1") == 0) return { ok: false, error: "existing_backend_owner" };
	if (!private_directory(BASE) || (fs.lstat(CORE) != null && !private_directory(CORE)))
		return { ok: false, error: "unsafe_native_directory" };
	if (fs.lstat(CORE) == null && !fs.mkdir(CORE, 0700)) return { ok: false, error: "core_directory_failed" };
	if (action == "native-core-stage") {
		if (!private_file(argument) || fs.stat(argument).size > 8388608)
			return { ok: false, error: "private_compiled_file_required" };
		const candidate = prepared(read_json(argument));
		if (!candidate.ok) return candidate;
		if (!validate_profile(candidate.stage.profile)) return { ok: false, error: "invalid_core_profile" };
		if (!atomic_json(STAGE, candidate.stage)) return { ok: false, error: "core_stage_failed" };
		return status();
	}
	const stage = load_stage();
	if (stage == null || !matches(stage)) return { ok: false, error: "core_stage_stale" };
	if (!validate_profile(stage.profile)) return { ok: false, error: "invalid_core_profile" };
	if (!atomic_json(CONFIG, stage.profile)) return { ok: false, error: "core_config_failed" };
	fs.unlink(SOCKET);
	if (!service_call("add", { name: SERVICE, instances: { core: {
		command: COMMAND, env: { SAFE_PATHS: CACHE }, term_timeout: 5, stdout: false, stderr: false
	} } })) return { ok: false, error: "core_start_failed" };
	for (let i = 0; i < 10; i++) {
		const current = status();
		if (current.ok && current.result.controller_ready) return current;
		system("sleep 1");
	}
	const cleanup = stop();
	return { ok: false, error: cleanup.ok ? "core_start_not_ready" : "core_start_cleanup_failed" };
};

export function run(action, argument) {
	if (system("test \"$(id -u)\" = 0") != 0) fail(action, "root_required");
	let lock = null;
	if (action != "native-core-status") {
		lock = fs.open(LOCK, "a", 0600);
		if (lock == null || lock.lock("xn") != true) {
			if (lock != null) lock.close();
			fail(action, "mutation_busy");
		}
	}
	let result;
	try { result = execute(action, argument); }
	catch (error) { result = { ok: false, error: "native_core_operation_failed" }; }
	if (lock != null) lock.close();
	if (!result.ok) fail(action, result.error);
	ok(action, result.result);
};
