import * as fs from "fs";
import { cursor } from "uci";
import { read_json, sha256, sha256_text, shell_quote, api_secret, current_profile, POLICY_PATH } from "../adapters/uci.uc";
import { KIND } from "../adapters/runtime.uc";
import { private_file, private_directory, atomic_json, write_private } from "../adapters/native.uc";
import { resolve_profile, stop, running } from "../adapters/backend.uc";
import { service_state, set_service_state } from "../adapters/service.uc";
import { proxies, select } from "../adapters/mihomo.uc";
import { project, public_settings, validate_request, runtime_profile, error_code } from "../core/network.uc";

const BASE = "/etc/opl-netfleet/native";
const CONFIG = "/etc/config/netfleet";
const MIXIN = `${BASE}/mixin.json`;
const GATEWAY = "/usr/libexec/opl-netfleet/application/native_gateway.uc";
const SERVICE = "/etc/init.d/opl-netfleet-core";
const MAIN = "/usr/libexec/opl-netfleet/main.uc";

function shell(command) { return system(`(${command}) >/dev/null 2>&1`) == 0; };
function command_json(command) {
	const process = fs.popen(`${command} 2>/dev/null`);
	if (process == null) return null;
	let result = null;
	try { result = json(process.read("all")); } catch (error) {}
	return process.close() == 0 ? result : null;
};
function failure(error, detail) { return { ok: false, error: error, result: detail ?? null }; };
function gateway() { return command_json(`ucode ${shell_quote(GATEWAY)} status`)?.result; };
function revision() {
	const path = resolve_profile(current_profile());
	return sha256_text(sprintf("%J", { config: sha256(CONFIG), mixin: fs.lstat(MIXIN) == null ? null : sha256(MIXIN),
		profile: path == null ? null : sha256(path), backend: KIND }));
};
function port(value) {
	const text = `${value ?? ""}`;
	const part = split(text, ":");
	return int(part[length(part) - 1] ?? 0);
};
function discover() {
	if (KIND != "native-mihomo") return { available: false, backend: KIND, reason: "native_backend_required", revision: null, settings: null };
	if (!private_file(CONFIG) || !private_directory(BASE) || (fs.lstat(MIXIN) != null && !private_file(MIXIN)))
		return { available: false, backend: KIND, reason: "private_network_configuration_required", revision: null, settings: null };
	const uci = cursor();
	if (length(keys(uci.changes("netfleet") ?? {})) > 0)
		return { available: false, backend: KIND, reason: "uncommitted_network_configuration", revision: null, settings: null };
	const before = revision();
	const rendered = command_json(`ucode ${shell_quote(GATEWAY)} preview`);
	if (rendered?.ok != true || type(rendered.result?.profile) != "object")
		return { available: false, backend: KIND, reason: "network_profile_unavailable", revision: null, settings: null };
	const sections = [];
	uci.foreach("netfleet", null, (section) => { push(sections, section); });
	const profile = rendered.result.profile;
	const settings = project(profile, sections);
	const interfaces = [];
	for (let entry in command_json("ubus call network.interface dump")?.interface ?? [])
		if (type(entry.interface) == "string") push(interfaces, { name: entry.interface, up: entry.up == true, device: entry.l3_device ?? entry.device ?? null });
	const reserved = [port(profile["external-controller"]), port(profile["external-controller-tls"]), port(profile.dns?.listen), port(profile["tproxy-port"]), port(profile["redir-port"])];
	for (let listener in profile.listeners ?? []) if (listener.port != null) push(reserved, int(listener.port));
	const after = revision();
	if (before == null || before != after) return { available: false, backend: KIND, reason: "network_revision_conflict", revision: null, settings: null };
	return { available: true, backend: KIND, revision: after, running: running(), settings: settings, profile: profile, sections: sections,
		resources: { interfaces: interfaces, reserved_ports: filter(reserved, (value) => value > 0),
			preserved_dns_policy_count: length(keys(profile.dns?.["nameserver-policy"] ?? {})) - length(settings.dns.policies),
			preserved_proxy_policy_count: length(keys(profile.dns?.["proxy-server-nameserver-policy"] ?? {})) - length(settings.dns.proxy_policies) } };
};
function public_state(found) {
	return found.available ? { available: true, backend: found.backend, revision: found.revision, running: found.running,
		settings: public_settings(found.settings), resources: found.resources } : found;
};
export function get() {
	try { return { ok: true, result: public_state(discover()) }; }
	catch (error) { return failure("network_read_failed"); }
};
function request(path, found) {
	if (!found.available) return failure(found.reason);
	if (!private_file(path) || fs.stat(path).size > 131072) return failure("private_request_required");
	return validate_request(read_json(path)?.request, found.revision, found.settings, found.resources);
};
function remove_work(path) {
	return type(path) == "string" && match(path, /^\/etc\/opl-netfleet\/\.network\.[A-Za-z0-9]+$/) &&
		private_directory(path) && shell(`rm -rf ${shell_quote(path)}`);
};
function candidate(found, settings, work) {
	const value = runtime_profile(found.profile, settings);
	if (!atomic_json(`${work}/candidate.json`, value)) return failure("network_candidate_write_failed");
	const status = system(`timeout -s KILL 45 /usr/bin/mihomo -t -d ${shell_quote(`${BASE}/run`)} -f ${shell_quote(`${work}/candidate.json`)} >/dev/null 2>&1`);
	if (status == 0) return { ok: true };
	return failure(index([124, 137, 143], status) >= 0 ? "network_validation_timeout" : "network_runtime_profile_invalid");
};
export function validate(path) {
	let work = null;
	let result = null;
	try {
		const found = discover();
		const change = request(path, found);
		if (!change.ok) return change;
		work = fs.mkdtemp("/etc/opl-netfleet/.network.XXXXXX");
		if (work == null || !private_directory(work)) return failure("network_workspace_failed");
		const valid = candidate(found, change.settings, work);
		result = valid.ok ? { ok: true, result: { valid: true, revision: found.revision, restart_required: found.running } } : valid;
	} catch (error) { result = failure(error_code(error, "network_validation_failed")); }
	if (work != null) remove_work(work);
	return result;
};
function set_value(uci, section, field, value) {
	if (type(value) == "array" && length(value) == 0) { uci.delete("netfleet", section, field); return; }
	if (!uci.set("netfleet", section, field, type(value) == "bool" ? (value ? "1" : "0") : type(value) == "int" ? `${value}` : value))
		die("network_config_write_failed");
};
function stage(found, settings, work) {
	if (!shell(`cp -p ${shell_quote(CONFIG)} ${shell_quote(`${work}/netfleet`)}`)) return false;
	const uci = cursor(work);
	const profile = runtime_profile(found.profile, settings);
	const extra = fs.lstat(MIXIN) == null ? {} : read_json(MIXIN);
	if (type(extra) != "object") return false;
	if (extra.dns == null) extra.dns = {};
	for (let field in ["nameserver", "default-nameserver", "proxy-server-nameserver", "direct-nameserver", "nameserver-policy", "proxy-server-nameserver-policy"]) {
		if (profile.dns[field] == null) delete extra.dns[field];
		else extra.dns[field] = profile.dns[field];
	}
	// Retain fallback resolvers when switching the represented resolver lists to the private overlay.
	if (profile.dns.fallback != null) extra.dns.fallback = profile.dns.fallback;
	set_value(uci, "mixin", "dns_nameserver", false);
	set_value(uci, "mixin", "dns_nameserver_policy", true);
	set_value(uci, "mixin", "dns_proxy_server_nameserver_policy", true);
	for (let section in found.sections) {
		if (index(["nameserver_policy", "proxy_server_nameserver_policy", "authentication"], section[".type"]) >= 0)
			set_value(uci, section[".name"], "enabled", false);
	}
	for (let field in ["mixed_port", "http_port", "socks_port"]) set_value(uci, "mixin", field, settings.listeners[field]);
	// An empty explicit list disables inherited authentication without exposing secrets in reads.
	set_value(uci, "mixin", "authentication", true);
	const credentials = settings.listeners.authentication_enabled ? settings.listeners.credentials : [];
	for (let i = 0; i < length(credentials); i++) {
		const id = `netfleet_management_auth_${i}`;
		if (uci.get("netfleet", id) != null && uci.get("netfleet", id) != "authentication") return false;
		if (!uci.set("netfleet", id, "authentication")) return false;
		set_value(uci, id, "enabled", true);
		set_value(uci, id, "username", credentials[i].username);
		set_value(uci, id, "password", credentials[i].password);
		if (!uci.reorder("netfleet", id, i)) return false;
	}
	set_value(uci, "proxy", "lan_proxy", settings.lan.enabled);
	set_value(uci, "proxy", "router_proxy", settings.router.enabled);
	set_value(uci, "proxy", "lan_inbound_interface", settings.lan.interfaces);
	const retained = map(settings.lan.rules, (rule) => rule.id);
	for (let section in found.sections)
		if (section[".type"] == "lan_access_control" && index(retained, section[".name"]) < 0)
			if (!uci.delete("netfleet", section[".name"])) return false;
	for (let i = 0; i < length(settings.lan.rules); i++) {
		const rule = settings.lan.rules[i];
		const existing = uci.get("netfleet", rule.id);
		if (existing != null && existing != "lan_access_control") return false;
		if (existing == null && !uci.set("netfleet", rule.id, "lan_access_control")) return false;
		for (let field in ["enabled", "proxy", "dns"]) set_value(uci, rule.id, field, rule[field]);
		set_value(uci, rule.id, "ip", rule.ipv4);
		set_value(uci, rule.id, "ip6", rule.ipv6);
		set_value(uci, rule.id, "mac", rule.mac);
		if (!uci.reorder("netfleet", rule.id, i)) return false;
	}
	return uci.commit("netfleet") && fs.chmod(`${work}/netfleet`, 0600) && atomic_json(`${work}/mixin.json`, extra);
};
function save_file(path, work, name) {
	if (fs.lstat(path) == null) return { path: path, present: false };
	if (!private_file(path)) return null;
	const digest = sha256(path);
	const backup = `${work}/${name}`;
	return shell(`cp -p ${shell_quote(path)} ${shell_quote(backup)}`) && sha256(backup) == digest ?
		{ path: path, present: true, backup: backup, digest: digest } : null;
};
function install_file(source, destination) {
	const temporary = `${destination}.network-tmp`;
	if (fs.lstat(temporary) != null) return false;
	if (!write_private(temporary, fs.readfile(source)) || sha256(temporary) != sha256(source) || !fs.rename(temporary, destination)) {
		fs.unlink(temporary); return false;
	}
	return sha256(destination) == sha256(source);
};
function restore_files(snapshot) {
	let restored = true;
	for (let entry in snapshot.files) {
		if (entry.present) restored = install_file(entry.backup, entry.path) && sha256(entry.path) == entry.digest && restored;
		else if (fs.lstat(entry.path) != null) restored = fs.unlink(entry.path) && restored;
	}
	return restored;
};
function selections() {
	const values = proxies(api_secret(), 2)?.proxies;
	if (type(values) != "object") return null;
	const result = {};
	for (let name, value in values) if (value.type == "Selector" && type(value.now) == "string") result[name] = value.now;
	return result;
};
function resume(snapshot) {
	if (snapshot.running) {
		if (!shell(`${SERVICE} start`)) return false;
		let ready = false;
		for (let attempt = 0; attempt < 15; attempt++) {
			if (gateway()?.ready == true) { ready = true; break; }
			system("sleep 1");
		}
		if (!ready) return false;
		const secret = api_secret();
		const current = proxies(secret, 2)?.proxies ?? {};
		for (let name, choice in snapshot.selections)
			if (index(current[name]?.all ?? [], choice) < 0 || !select(secret, name, choice)) return false;
		const readback = selections();
		for (let name, choice in snapshot.selections) if (readback?.[name] != choice) return false;
		if (fs.lstat(POLICY_PATH) != null) {
			const probe = command_json(`ucode ${shell_quote(MAIN)} probe`);
			if (probe?.ok != true || probe.result?.ok != true) return false;
		}
	} else if (gateway()?.clean != true) return false;
	return set_service_state(snapshot.supervisor).ok;
};
function rollback(snapshot) {
	if (!stop().ok) return { ok: false, error: "network_cleanup_failed" };
	if (!restore_files(snapshot)) return { ok: false, error: "network_restore_failed" };
	return resume(snapshot) ? { ok: true, state: "restored" } : { ok: false, error: "network_runtime_restore_failed" };
};

// The outer RPC mutation lock also excludes the periodic selector and subscription writer.
export function apply(path) {
	let work = null;
	let snapshot = null;
	let changed = false;
	let problem = null;
	try {
		const found = discover();
		const change = request(path, found);
		if (!change.ok) return change;
		if (sprintf("%J", found.settings) == sprintf("%J", change.settings))
			return { ok: true, result: { state: "unchanged", network: public_state(found) } };
		work = fs.mkdtemp("/etc/opl-netfleet/.network.XXXXXX");
		if (work == null || !private_directory(work)) return failure("network_workspace_failed");
		const checked = candidate(found, change.settings, work);
		if (!checked.ok) die(checked.error);
		if (!stage(found, change.settings, work)) die("network_stage_failed");
		snapshot = { files: [], running: found.running, supervisor: service_state(), selections: found.running ? selections() : {} };
		if (snapshot.running && snapshot.selections == null) die("network_controller_unavailable");
		for (let entry in [[CONFIG, "original-config"], [MIXIN, "original-mixin"]]) {
			const saved = save_file(entry[0], work, entry[1]);
			if (saved == null) die("network_snapshot_failed");
			push(snapshot.files, saved);
		}
		if (!atomic_json(`${work}/snapshot.json`, snapshot)) die("network_snapshot_failed");
		if (revision() != found.revision) die("network_revision_conflict");
		changed = true;
		if (!set_service_state({ ...snapshot.supervisor, running: false }).ok) die("network_supervisor_pause_failed");
		if (!stop().ok) die("network_stop_failed");
		if (!install_file(`${work}/netfleet`, CONFIG) || !install_file(`${work}/mixin.json`, MIXIN)) die("network_install_failed");
		if (!resume(snapshot)) die("network_runtime_verification_failed");
		const current = discover();
		if (!current.available) die("network_readback_failed");
		remove_work(work);
		work = null;
		return { ok: true, result: { state: "applied", restarted: snapshot.running, network: public_state(current) } };
	} catch (error) { problem = error_code(error, "network_apply_failed"); }
	const restored = changed ? rollback(snapshot) : { ok: true };
	if (restored.ok && work != null) remove_work(work);
	return failure(restored.ok ? problem : "network_rollback_failed", { cause: problem, rollback: restored,
		recovery_directory: restored.ok ? null : work });
};
