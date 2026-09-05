import * as fs from "fs";
import { cursor } from "uci";
import { read_json, read_yaml, sha256, sha256_text, shell_quote, POLICY_PATH, EVIDENCE_PATH } from "../adapters/uci.uc";
import { KIND } from "../adapters/runtime.uc";
import { stop as stop_previous } from "../adapters/backend.uc";
import { resolve as resolve_policy_source } from "../adapters/policy_source.uc";
import { private_file, private_directory, write_private, atomic_json } from "../adapters/native.uc";
import { service_state, set_service_state } from "../adapters/service.uc";
import { validate as validate_policy } from "../core/policy.uc";
import { migrate_object, migrate_sections, profile_path, relative_path, public_plan } from "../core/backend_migration.uc";

const OLD = "/etc/nikki";
const BASE = "/etc/opl-netfleet/native";
const MARKER = "/etc/opl-netfleet/backend.json";
const MAIN = "/usr/libexec/opl-netfleet/main.uc";
const GATEWAY = "/usr/libexec/opl-netfleet/application/native_gateway.uc";
const CONFIG = "/etc/config/netfleet";

function shell(command) { return system(`(${command}) >/dev/null 2>&1`) == 0; };
function capture(command) {
	const p = fs.popen(command + " 2>/dev/null");
	if (p == null) return null;
	const value = p.read("all");
	return p.close() == 0 ? value : null;
};
function parsed_command(command) {
	try { return json(capture(command)); } catch (error) { return null; }
};
function directory(path) {
	if (fs.lstat(path) != null) return private_directory(path);
	return shell(`umask 077; mkdir -p -m 0700 ${shell_quote(path)}`) && private_directory(path);
};
function parent(path) { const parts = split(path, "/"); pop(parts); return join("/", parts); };
function fail(error, detail) { return { ok: false, error: error, result: detail ?? null }; };
function add_missing(found, reason) {
	if (index(found.missing, reason) < 0) push(found.missing, reason);
};

function add_resource(found, source, destination, optional) {
	if (fs.lstat(source) == null) {
		if (!optional) add_missing(found, "source_resource_unavailable");
		return;
	}
	const canonical = trim(capture(`readlink -f ${shell_quote(source)}`) ?? "");
	if (index(canonical, `${OLD}/`) != 0 || index(destination, `${BASE}/`) != 0 ||
		!relative_path(substr(destination, length(BASE) + 1))) {
		add_missing(found, "source_resource_outside_owner");
		return;
	}
	const info = fs.stat(canonical);
	if (info?.type == "directory") {
		for (let name in fs.lsdir(canonical) ?? []) {
			if (name == "." || name == "..") continue;
			add_resource(found, `${canonical}/${name}`, `${destination}/${name}`, false);
		}
		return;
	}
	if (info?.type != "file") { add_missing(found, "unsupported_resource_type"); return; }
	const digest = sha256(canonical);
	if (digest == null) { add_missing(found, "resource_digest_unavailable"); return; }
	const existing = found.resources[destination];
	if (existing != null && existing.digest != digest) { add_missing(found, "resource_destination_conflict"); return; }
	found.resources[destination] = { source: canonical, digest: digest };
};

function resource_paths(found, value) {
	if (type(value) == "array") { for (let item in value) resource_paths(found, item); return; }
	if (type(value) != "object") return;
	for (let key, item in value) {
		if (type(item) == "string" && index(["path", "file_path", "ui_path", "external-ui", "api_tls_cert", "api_tls_key"], key) >= 0) {
			if (index(item, `${OLD}/`) == 0) add_resource(found, item, migrate_object(item), value.type == "http");
			else if (relative_path(item)) add_resource(found, `${OLD}/run/${item}`, `${BASE}/run/${item}`, value.type == "http");
			else if (substr(item, 0, 1) == "/" && fs.stat(item)?.type != "file" && fs.stat(item)?.type != "directory")
				add_missing(found, "source_resource_unavailable");
		}
		if (type(item) == "object" || type(item) == "array") resource_paths(found, item);
	}
};

function discovery() {
	const found = { ready: false, backend: KIND, missing: [], resources: {}, profiles: {},
		sections: [], subscription_count: 0, profile_count: 0, private_mixin: false, dashboard: false };
	if (KIND == "native-mihomo") { add_missing(found, "already_native"); return found; }
	if (!shell("test -x /etc/init.d/opl-netfleet-core") || fs.stat(GATEWAY)?.type != "file")
		add_missing(found, "native_gateway_unavailable");
	if (fs.lstat(CONFIG) != null || (fs.lstat(BASE) != null &&
		(!private_directory(BASE) || length(fs.lsdir(BASE) ?? []) > 0))) add_missing(found, "existing_native_configuration");
	if (!shell("/etc/init.d/nikki running") || !shell("pidof mihomo")) add_missing(found, "source_backend_not_running");
	if (shell("/etc/init.d/opl-netfleet-core running")) add_missing(found, "existing_native_owner");
	if (shell("/etc/init.d/opl-netfleet-core enabled")) add_missing(found, "native_service_already_enabled");
	if (gateway()?.result?.registered == true) add_missing(found, "existing_native_owner");
	const policy = read_json(POLICY_PATH);
	found.policy_valid = validate_policy(policy).ok;
	if (!found.policy_valid) { add_missing(found, "policy_unavailable"); return found; }
	if (policy.main.enabled != true) add_missing(found, "policy_disabled");
	found.policy = policy;
	const uci = cursor();
	const sections = [];
	uci.foreach("nikki", null, (section) => push(sections, section));
	const migrated = migrate_sections(sections, policy.recovery_profile.ref);
	if (!migrated.ok) { add_missing(found, migrated.error); return found; }
	found.sections = migrated.sections;
	if (`${uci.get("nikki", "config", "enabled") ?? "0"}` != "1") add_missing(found, "source_backend_disabled");
	if (`${uci.get("nikki", "config", "core_only") ?? "0"}` == "1") add_missing(found, "core_only_not_supported");
	const references = [policy.recovery_profile.ref];
	if (policy.policy_source.kind == "profile" && index(references, policy.policy_source.ref) < 0) push(references, policy.policy_source.ref);
	for (let name, provider in policy.providers ?? {}) {
		const reference = `subscription:${provider.section}`;
		if (provider.enabled == true && index(references, reference) < 0) push(references, reference);
	}
	for (let section in sections) {
		if (section[".type"] == "subscription") {
			const reference = `subscription:${section[".name"]}`;
			if (index(references, reference) < 0 && fs.stat(profile_path(reference, OLD))?.type == "file") push(references, reference);
			found.subscription_count++;
		}
		resource_paths(found, section);
	}
	for (let reference in references) {
		const source = profile_path(reference, OLD);
		const target = profile_path(reference, BASE);
		const profile = source == null ? null : read_yaml(source, true);
		if (type(profile) != "object") { add_missing(found, "profile_or_subscription_unavailable"); continue; }
		resource_paths(found, profile);
		found.profiles[target] = { value: migrate_object(profile), source: source, digest: sha256(source) };
		found.profile_count++;
	}
	if (policy.policy_source.kind == "bundle") {
		const source = resolve_policy_source(policy.policy_source);
		const value = source == null ? null : read_json(source);
		if (value == null) add_missing(found, "policy_source_unavailable");
		else {
			resource_paths(found, value);
			found.bundle_digest = sha256(source);
		}
	}
	if (`${uci.get("nikki", "mixin", "mixin_file_content") ?? "0"}` == "1") {
		const value = read_yaml(`${OLD}/mixin.yaml`, true);
		if (type(value) != "object") add_missing(found, "private_mixin_unavailable");
		else {
			resource_paths(found, value);
			found.mixin = migrate_object(value);
			found.mixin_digest = sha256(`${OLD}/mixin.yaml`);
			found.private_mixin = true;
		}
	}
	for (let name in ["Country.mmdb", "country.mmdb", "GeoIP.dat", "geoip.dat", "GeoSite.dat", "geosite.dat", "ASN.mmdb"]) {
		add_resource(found, `${OLD}/run/${name}`, `${BASE}/run/${name}`, true);
	}
	const ui = uci.get("nikki", "mixin", "ui_path");
	const ui_source = relative_path(ui) ? `${OLD}/run/${ui}` : ui;
	found.dashboard = type(ui_source) == "string" && fs.stat(`${ui_source}/index.html`)?.type == "file";
	found.nikki_running = shell("/etc/init.d/nikki running");
	found.nikki_enabled = shell("/etc/init.d/nikki enabled");
	found.supervisor = service_state();
	found.revision = sha256_text(sprintf("%J", { uci: sha256("/etc/config/nikki"), policy: sha256(POLICY_PATH),
		implementation: sha256(MAIN), gateway: sha256(GATEWAY), init: sha256("/etc/init.d/opl-netfleet-core"),
		profiles: map(keys(found.profiles), (key) => [found.profiles[key].source, found.profiles[key].digest]), resources: found.resources,
		mixin: found.mixin_digest, bundle: found.bundle_digest, supervisor: found.supervisor,
		nikki_running: found.nikki_running, nikki_enabled: found.nikki_enabled }));
	if (found.revision == null) add_missing(found, "revision_unavailable");
	found.ready = length(found.missing) == 0;
	return found;
};

function safe_discovery() {
	try { return discovery(); }
	catch (error) { return { ready: false, missing: ["migration_input_unreadable"], backend: KIND }; }
};

export function get() { return { ok: true, result: public_plan(safe_discovery()) }; };

function owner(action, work) {
	const path = `${work}/${action}.json`;
	const ok = shell(`ucode ${shell_quote(MAIN)} ${shell_quote(action)} cli >${shell_quote(path)}`);
	const response = read_json(path);
	return { ok: ok && response?.ok == true, response: response };
};
function gateway() { return parsed_command(`ucode ${shell_quote(GATEWAY)} status`); };
function save_file(path, work, name) {
	const info = fs.lstat(path);
	if (info != null && info.type != "file") return null;
	const target = `${work}/${name}`;
	if (info != null && (!shell(`cp -p ${shell_quote(path)} ${shell_quote(target)}`) || sha256(target) != sha256(path))) return null;
	return { path: path, backup: target, present: info != null, digest: info == null ? null : sha256(path) };
};
function restore_file(saved) {
	if (!saved.present) return fs.lstat(saved.path) == null || fs.unlink(saved.path);
	return shell(`cp -p ${shell_quote(saved.backup)} ${shell_quote(saved.path)}`) && sha256(saved.path) == saved.digest;
};
function remove_work(work) {
	return type(work) == "string" && index(work, "/etc/opl-netfleet/.migration.") == 0 &&
		shell(`rm -rf ${shell_quote(work)}`);
};
function stage(found, work) {
	const native = `${work}/native`;
	if (!directory(native)) return false;
	for (let target, resource in found.resources) {
		const path = `${native}${substr(target, length(BASE))}`;
		if (!directory(parent(path)) || !shell(`cp ${shell_quote(resource.source)} ${shell_quote(path)}`) ||
			!fs.chmod(path, 0600) || sha256(path) != resource.digest) return false;
	}
	for (let target, profile in found.profiles) {
		const path = `${native}${substr(target, length(BASE))}`;
		if (!directory(parent(path)) || !atomic_json(path, profile.value)) return false;
	}
	if (found.mixin != null && !atomic_json(`${native}/mixin.json`, found.mixin)) return false;
	if (!write_private(`${work}/netfleet`, "\n")) return false;
	const uci = cursor(work);
	for (let section in found.sections) {
		if (!uci.set("netfleet", section.name, section.type)) return false;
		for (let key, value in section.options) if (!uci.set("netfleet", section.name, key, value)) return false;
	}
	return uci.commit("netfleet") && fs.chmod(`${work}/netfleet`, 0600);
};

function rollback(snapshot, work, installed) {
	shell("/etc/init.d/opl-netfleet-core stop");
	let native = null;
	for (let attempt = 0; attempt < 10; attempt++) {
		native = gateway();
		if (native?.result?.core_running == false && native?.result?.clean == true) break;
		if (attempt < 9) system("sleep 1");
	}
	if (native?.result?.core_running != false || native?.result?.clean != true)
		return { ok: false, error: "native_cleanup_unconfirmed", recovery_directory: work };
	let restored = shell("/etc/init.d/opl-netfleet-core disable");
	for (let entry in snapshot.files) restored = restore_file(entry) && restored;
	if (installed && !shell(`rm -rf ${shell_quote(BASE)}`)) restored = false;
	if (snapshot.native_directory_existed && !directory(BASE)) restored = false;
	if (!restored) return { ok: false, error: "snapshot_restore_failed", recovery_directory: work };
	const boot = snapshot.nikki_enabled ? "enable" : "disable";
	let startup = shell(`/etc/init.d/nikki ${boot}`);
	// Recovery must use the accepted cache, not request a new remote revision.
	const reference = split(snapshot.profile ?? "", ":");
	if (snapshot.nikki_running && reference[0] == "subscription" && match(reference[1] ?? "", /^[A-Za-z0-9_]+$/)) {
		startup = shell(`uci set ${shell_quote(`nikki.${reference[1]}.prefer=local`)}`) && shell("uci commit nikki") && startup;
	}
	startup = startup && (snapshot.nikki_running ? shell("/etc/init.d/nikki restart") : shell("/etc/init.d/nikki stop"));
	startup = restore_file(snapshot.files[0]) && startup;
	const current = owner("status", work);
	const probe = snapshot.nikki_running ? owner("probe", work) : { ok: true };
	const supervisor = set_service_state(snapshot.supervisor);
	return { ok: startup && current.ok && probe.ok && supervisor.ok &&
		current.response?.result?.profile == snapshot.profile,
		owner_restored: startup && current.ok && current.response?.result?.profile == snapshot.profile,
		business_ok: probe.ok, supervisor_restored: supervisor.ok };
};

// The caller holds opl-netfleet-deploy.lock throughout this transaction.
// Child main.uc actions share that owner and must not acquire a second lock.
export function apply(envelope_path) {
	if (!shell('test "$(id -u)" = 0')) return fail("root_required");
	if (!private_file(envelope_path)) return fail("private_request_required");
	const request = read_json(envelope_path)?.request;
	if (request?.confirmed != true || request?.backend != "native-mihomo") return fail("explicit_confirmation_required");
	const found = safe_discovery();
	if (!found.ready) return fail("migration_not_ready", public_plan(found));
	if (request.revision != found.revision) return fail("migration_revision_conflict", public_plan(found));
	const baseline = parsed_command(`ucode ${shell_quote(MAIN)} probe`);
	if (baseline?.ok != true) return fail("source_business_probe_failed");
	const work = trim(capture("mktemp -d /etc/opl-netfleet/.migration.XXXXXX") ?? "");
	if (!private_directory(work)) return fail("snapshot_directory_failed");
	const snapshot = { files: [], profile: cursor().get("nikki", "config", "profile"),
		nikki_running: found.nikki_running, nikki_enabled: found.nikki_enabled,
		supervisor: found.supervisor, native_directory_existed: fs.lstat(BASE) != null };
	for (let path in ["/etc/config/nikki", CONFIG, MARKER, POLICY_PATH, EVIDENCE_PATH, "/var/lib/opl-netfleet/events.json"]) {
		const saved = save_file(path, work, `snapshot-${length(snapshot.files)}`);
		if (saved == null) { remove_work(work); return fail("snapshot_failed"); }
		push(snapshot.files, saved);
	}
	if (!atomic_json(`${work}/snapshot.json`, snapshot) || !stage(found, work)) {
		remove_work(work);
		return fail("migration_stage_failed");
	}
	const fresh = safe_discovery();
	if (!fresh.ready || fresh.revision != found.revision) { remove_work(work); return fail("migration_revision_conflict"); }
	let installed = false;
	let changed = false;
	let problem = null;
	try {
		const paused = set_service_state({ ...snapshot.supervisor, running: false });
		changed = true;
		if (!paused.ok) die("supervisor_stop_failed");
		if (!stop_previous().ok) die("source_cleanup_failed");
		if (!shell("/etc/init.d/nikki disable") || !shell("uci set nikki.config.enabled='0'") || !shell("uci commit nikki"))
			die("source_disable_failed");
		if (snapshot.native_directory_existed && !fs.rmdir(BASE)) die("native_directory_changed");
		if (!fs.rename(`${work}/native`, BASE)) die("native_install_failed");
		installed = true;
		if (!fs.rename(`${work}/netfleet`, CONFIG) || !atomic_json(MARKER, { kind: "native-mihomo" })) die("backend_selection_failed");
		if (!shell("/etc/init.d/opl-netfleet-core restart") || gateway()?.result?.ready != true) die("native_recovery_start_failed");
		if (!owner("compile", work).ok) die("native_compile_failed");
		if (!owner("enable", work).ok) die("native_enable_failed");
		const status = owner("status", work);
		if (!status.ok || status.response?.result?.active != true ||
			status.response?.result?.runtime?.netfleet_present != true || gateway()?.result?.ready != true)
			die("native_owner_readback_failed");
		if (!owner("probe", work).ok) die("native_business_probe_failed");
		if (!shell("/etc/init.d/opl-netfleet-core enable") || !set_service_state({ enabled: true, running: true }).ok)
			die("native_service_enable_failed");
		remove_work(work);
		return { ok: true, result: { state: "active", backend: "native-mihomo", previous_backend_stopped: true,
			gateway_ready: true, business_ok: true, capabilities: public_plan(found).capabilities } };
	} catch (error) { problem = error.message ?? "migration_failed"; }
	const restored = changed ? rollback(snapshot, work, installed) : { ok: true };
	if (restored.ok) remove_work(work);
	return fail(restored.ok ? problem : "migration_rollback_failed", { cause: problem, rollback: restored });
};
