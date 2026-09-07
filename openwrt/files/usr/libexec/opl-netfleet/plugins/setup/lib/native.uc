import * as fs from "fs";
import { cursor } from "uci";

return function(context) {
// Bind the service functions before assigning closures that may reference them.
let shell, capture, command_json, gateway, failure, unused_directory, upstreams, discovery, public_plan, get, save_file, restore_file, remove_work, initialize, subscription_call, rollback, apply, command_native_setup_get, command_native_setup_apply;

const private_file = context.use("platform.files").private_file;
const private_directory = context.use("platform.files").private_directory;
const write_private = context.use("platform.files").write_private;
const atomic_json = context.use("platform.files").atomic_json;
const KIND = context.use("platform.runtime").KIND;
const service_state = context.use("platform.service").service_state;
const set_service_state = context.use("platform.service").set_service_state;
const read_json = context.use("platform.storage").read_json;
const sha256 = context.use("platform.storage").sha256;
const sha256_text = context.use("platform.storage").sha256_text;
const shell_quote = context.use("platform.process").shell_quote;
const POLICY_PATH = context.use("platform.paths").POLICY_PATH;
const EVIDENCE_PATH = context.use("platform.paths").EVIDENCE_PATH;
const validate_request = context.use("setup.native-model").validate_request;
const upstream_candidates = context.use("setup.native-model").upstream_candidates;

const BASE = "/etc/opl-netfleet/native";
const STATE = "/var/run/opl-netfleet-core";
const CONFIG = "/etc/config/netfleet";
const MARKER = "/etc/opl-netfleet/backend.json";
const TEMPLATE = "/usr/share/opl-netfleet/netfleet.config";
const GATEWAY = "/usr/libexec/opl-netfleet/main.uc";
const MAIN = "/usr/libexec/opl-netfleet/main.uc";

shell = function(command) { return system(`(${command}) >/dev/null 2>&1`) == 0; };
capture = function(command) {
	const process = fs.popen(command + " 2>/dev/null");
	if (process == null) return null;
	const value = process.read("all");
	return process.close() == 0 ? value : null;
};
command_json = function(command) {
	try { return json(capture(command)); } catch (error) { return null; }
};
gateway = function() { return command_json(`ucode ${shell_quote(GATEWAY)} native-gateway-status`); };
failure = function(error, detail) { return { ok: false, error: error, result: detail ?? null }; };
unused_directory = function(path) {
	return fs.lstat(path) == null || (private_directory(path) && length(fs.lsdir(path) ?? []) == 0);
};
upstreams = function() {
	const network = command_json("ubus call network.interface dump");
	const result = [];
	for (let address in upstream_candidates(network?.interface)) {
		const family = index(address, ":") < 0 ? 4 : 6;
		const route = command_json(`ip -j -${family} route get ${shell_quote(address)}`)?.[0];
		if (route?.dev != null && route.dev != "lo" && route.type != "local") push(result, address);
	}
	return result;
};

discovery = function() {
	const missing = [];
	const current = gateway();
	const native_present = fs.lstat(CONFIG) != null || !unused_directory(BASE) || !unused_directory(STATE);
	if (KIND == "native-mihomo" || native_present) push(missing, "existing_native_configuration");
	if (fs.lstat(POLICY_PATH) != null || fs.lstat(EVIDENCE_PATH) != null) push(missing, "existing_netfleet_configuration");
	if (shell("/etc/init.d/nikki running") || shell("pidof mihomo")) push(missing, "existing_backend_owner");
	if (current?.ok != true) push(missing, "gateway_status_unavailable");
	else if (current.result?.registered == true || current.result?.clean != true) push(missing, "existing_native_owner");
	if (shell("/etc/init.d/opl-netfleet-core enabled")) push(missing, "native_service_already_enabled");
	if (fs.stat(TEMPLATE)?.type != "file" || !shell("test -x /etc/init.d/opl-netfleet-core"))
		push(missing, "native_gateway_unavailable");
	if (!shell("command -v mihomo && command -v curl && command -v yq && command -v ip && command -v nft && command -v utpl"))
		push(missing, "native_dependencies_unavailable");
	const resolvers = upstreams();
	if (length(resolvers) == 0) push(missing, "upstream_dns_unavailable");
	const supervisor = service_state();
	const revision = sha256_text(sprintf("%J", { kind: KIND, marker: sha256(MARKER),
		config: sha256(CONFIG), template: sha256(TEMPLATE), native_present: native_present,
		policy: sha256(POLICY_PATH), evidence: sha256(EVIDENCE_PATH), missing: missing,
		resolvers: resolvers, supervisor: supervisor }));
	return { ready: length(missing) == 0 && revision != null, revision: revision, backend: KIND,
		present: native_present || KIND == "native-mihomo", missing: missing, resolvers: resolvers, supervisor: supervisor };
};
public_plan = function(found) {
	return { ready: found.ready, revision: found.revision, backend: found.backend,
		present: found.present, missing: found.missing };
};
get = function() {
	try { return { ok: true, result: public_plan(discovery()) }; }
	catch (error) { return failure("setup_discovery_failed"); }
};

save_file = function(path, work, name) {
	const info = fs.lstat(path);
	if (info != null && info.type != "file") return null;
	const backup = `${work}/${name}`;
	if (info != null && (!shell(`cp -p ${shell_quote(path)} ${shell_quote(backup)}`) || sha256(backup) != sha256(path))) return null;
	return { path: path, present: info != null, backup: backup, digest: info == null ? null : sha256(path) };
};
restore_file = function(saved) {
	if (!saved.present) return fs.lstat(saved.path) == null || fs.unlink(saved.path);
	return shell(`cp -p ${shell_quote(saved.backup)} ${shell_quote(saved.path)}`) && sha256(saved.path) == saved.digest;
};
remove_work = function(work) {
	return type(work) == "string" && index(work, "/etc/opl-netfleet/.setup.") == 0 &&
		shell(`rm -rf ${shell_quote(work)}`);
};
initialize = function(found, source) {
	if (!write_private(CONFIG, fs.readfile(TEMPLATE))) return false;
	const random = fs.open("/dev/urandom", "r");
	if (random == null) return false;
	const bytes = random.read(32);
	random.close();
	const secret = type(bytes) == "string" ? hexenc(bytes) : "";
	if (!match(secret, /^[0-9a-f]{64}$/)) return false;
	const uci = cursor();
	uci.set("netfleet", "config", "enabled", "1");
	uci.set("netfleet", "config", "profile", `subscription:${source.id}`);
	uci.set("netfleet", "mixin", "api_secret", secret);
	uci.set("netfleet", "mixin", "outbound_interface", "wan");
	uci.set("netfleet", "mixin", "dns_nameserver", "1");
	const roles = ["default-nameserver", "proxy-server-nameserver", "direct-nameserver", "nameserver"];
	for (let i = 0; i < length(roles); i++) {
		const role = roles[i];
		const section = `netfleet_dns_${i}`;
		if (!uci.set("netfleet", section, "nameserver") || !uci.set("netfleet", section, "enabled", "1") ||
			!uci.set("netfleet", section, "type", role) || !uci.set("netfleet", section, "nameserver", found.resolvers)) return false;
	}
	return uci.commit("netfleet") && fs.chmod(CONFIG, 0600) && atomic_json(MARKER, { kind: "native-mihomo" });
};
subscription_call = function(expression, argument, output) {
	const command = expression == "set" ? "subscriptions-set" : "subscriptions-update-result";
	if (!shell(`ucode ${shell_quote(MAIN)} ${command} ${shell_quote(argument)} >${shell_quote(output)}`))
		return failure("subscription_owner_unavailable");
	return read_json(output) ?? failure("subscription_owner_unavailable");
};
rollback = function(snapshot, work) {
	shell("/etc/init.d/opl-netfleet-core stop");
	let current = null;
	for (let i = 0; i < 10; i++) {
		current = gateway();
		if (current?.result?.core_running == false && current?.result?.clean == true) break;
		if (i < 9) system("sleep 1");
	}
	if (current?.result?.core_running != false || current?.result?.clean != true)
		return { ok: false, error: "native_cleanup_unconfirmed", recovery_directory: work };
	let restored = shell("/etc/init.d/opl-netfleet-core disable");
	for (let saved in snapshot.files) restored = restore_file(saved) && restored;
	for (let path in [BASE, STATE]) {
		if (fs.lstat(path) != null && !shell(`rm -rf ${shell_quote(path)}`)) restored = false;
		if (snapshot.directories[path] && !fs.mkdir(path, 0700)) restored = false;
	}
	const supervisor = restored ? set_service_state(snapshot.supervisor) : { ok: false };
	return { ok: restored && supervisor.ok, files_restored: restored, supervisor_restored: supervisor.ok,
		recovery_directory: restored && supervisor.ok ? null : work };
};

// The existing main/RPC global mutation lock owns this complete transaction.
apply = function(envelope_path) {
	if (!shell('test "$(id -u)" = 0')) return failure("root_required");
	if (!private_file(envelope_path) || fs.stat(envelope_path).size > 32768) return failure("private_request_required");
	const found = discovery();
	if (!found.ready) return failure("setup_not_ready", public_plan(found));
	const validated = validate_request(read_json(envelope_path)?.request, found.revision);
	if (!validated.ok) return validated;
	const work = fs.mkdtemp("/etc/opl-netfleet/.setup.XXXXXX");
	if (work == null || !private_directory(work)) return failure("setup_snapshot_failed");
	const snapshot = { files: [], directories: {}, supervisor: found.supervisor };
	for (let path in [BASE, STATE]) snapshot.directories[path] = fs.lstat(path) != null;
	for (let path in [CONFIG, MARKER]) {
		const saved = save_file(path, work, `snapshot-${length(snapshot.files)}`);
		if (saved == null) { remove_work(work); return failure("setup_snapshot_failed"); }
		push(snapshot.files, saved);
	}
	if (!atomic_json(`${work}/snapshot.json`, snapshot)) { remove_work(work); return failure("setup_snapshot_failed"); }
	const fresh = discovery();
	if (!fresh.ready || fresh.revision != found.revision) { remove_work(work); return failure("setup_revision_conflict"); }
	let problem = null;
	try {
		if (!set_service_state({ ...snapshot.supervisor, running: false }).ok) die("supervisor_stop_failed");
		if (!initialize(found, validated.source)) die("setup_config_failed");
		const request = `${work}/subscription.json`;
		if (!atomic_json(request, { request: { revision: sha256(CONFIG), source: validated.source } })) die("setup_request_failed");
		const saved = subscription_call("set", request, `${work}/set.json`);
		if (!saved.ok) die(saved.error);
		const updated = subscription_call("update_result", validated.source.id, `${work}/update.json`);
		if (!updated.ok) die(updated.error);
		if (!shell("/etc/init.d/opl-netfleet-core start") || gateway()?.result?.ready != true) die("native_gateway_start_failed");
		const onboarding = command_json(`ucode ${shell_quote(MAIN)} onboarding-get`);
		if (onboarding?.ok != true || onboarding.result?.ready != true) die("native_onboarding_not_ready");
		if (!shell("/etc/init.d/opl-netfleet-core enable") || !set_service_state(snapshot.supervisor).ok)
			die("native_service_enable_failed");
		remove_work(work);
		return { ok: true, result: { state: "native_ready", backend: "native-mihomo", gateway_ready: true,
			onboarding_required: true } };
	} catch (error) { problem = error.message ?? "native_setup_failed"; }
	const restored = rollback(snapshot, work);
	if (restored.ok) remove_work(work);
	return failure(restored.ok ? problem : "setup_rollback_failed", { cause: problem, rollback: restored });
};

command_native_setup_get = function(argv) {
	return get();
};

command_native_setup_apply = function(argv) {
	return apply(argv[1]);
};

return { get, apply, command_native_setup_get, command_native_setup_apply };
};
