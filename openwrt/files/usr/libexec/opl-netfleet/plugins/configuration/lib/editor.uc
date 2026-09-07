import { popen } from "fs";

return function(context) {
// Bind the service functions before assigning closures that may reference them.
let profile_display_name, has_reference, source_group_names, provider_display_names, resources, projection, load_change, snapshot_file, prepare_snapshot, restore_snapshot, diagnostic, run_owner, cleanup_snapshot, rollback, fail_apply, get, validate, save, apply, command_config_get, command_config_validate, command_config_save, command_config_apply;

const project = context.use("configuration.model").project;
const apply_request = context.use("configuration.model").apply;
const changes = context.use("configuration.model").changes;
const ok = context.use("events.output").ok;
const fail = context.use("events.output").fail;
const resolve_profile = context.use("mihomo.backend").resolve_profile;
const profile_exists = context.use("mihomo.backend").profile_exists;
const prepare_provider_links = context.use("mihomo.backend").prepare_provider_links;
const remove_provider_links = context.use("mihomo.backend").remove_provider_links;
const ARTIFACT_PATH = context.use("mihomo.backend").ARTIFACT_PATH;
const MANIFEST_PATH = context.use("mihomo.backend").MANIFEST_PATH;
const resolve_policy_source = context.use("mihomo.policy-source").resolve;
const load_policy_source = context.use("mihomo.policy-source").load;
const is_active = context.use("models.activation").is_active;
const load_policy = context.use("platform.documents").load_policy;
const region_catalog = context.use("models.regions").catalog;
const discover_regions = context.use("models.regions").discover;
const backend_metadata = context.use("platform.runtime").metadata;
const read_yaml = context.use("platform.storage").read_yaml;
const read_json = context.use("platform.storage").read_json;
const write_json_atomic = context.use("platform.storage").write_json_atomic;
const sha256 = context.use("platform.storage").sha256;
const current_profile = context.use("platform.profile").current_profile;
const shell_quote = context.use("platform.process").shell_quote;
const subscription_display_name = context.use("platform.subscriptions").subscription_display_name;
const subscription_options = context.use("platform.subscriptions").subscription_options;
const POLICY_PATH = context.use("platform.paths").POLICY_PATH;
const load_provider_profiles = context.use("subscriptions.providers").load;

const WORK_DIR = "/tmp/opl-netfleet-config-apply";
const MAIN_PATH = "/usr/libexec/opl-netfleet/main.uc";

profile_display_name = function(profile) {
	const prefix = "subscription:";
	if (type(profile) == "string" && index(profile, prefix) == 0) {
		const section = substr(profile, length(prefix));
		const display = subscription_display_name(section);
		return display == section ? null : display;
	}
	return null;
};

has_reference = function(options, kind, ref) {
	for (let i = 0; i < length(options); i++) {
		if ((kind == null || options[i]?.kind == kind) && options[i]?.ref == ref) return true;
	}
	return false;
};

source_group_names = function(source) {
	const profile = load_policy_source(source);
	const groups = profile?.["proxy-groups"] ?? [];
	const result = [];
	for (let i = 0; i < length(groups); i++) {
		const name = groups[i]?.name;
		if (type(name) == "string" && length(trim(name)) > 0 && index(result, name) < 0) push(result, name);
	}
	return result;
};

provider_display_names = function(policy) {
	const result = {};
	const names = keys(policy?.providers ?? {});
	for (let i = 0; i < length(names); i++)
		result[names[i]] = subscription_display_name(policy.providers[names[i]].section);
	return result;
};

resources = function(policy) {
	const subscriptions = subscription_options();
	const recovery_options = [];
	const source_options = [];
	const provider_options = [];
	const region_options_by_id = {};
	const source_groups = {};
	const bundle = { kind: "bundle", ref: "bundle:base-v1" };
	if (resolve_policy_source(bundle) != null && sha256(resolve_policy_source(bundle)) != null) {
		push(source_options, { kind: "bundle", ref: bundle.ref, display_name: "NetFleet 内置基础策略" });
		source_groups[`bundle|${bundle.ref}`] = source_group_names(bundle);
	}
	for (let i = 0; i < length(subscriptions); i++) {
		const reference = subscriptions[i]?.ref;
		const prefix = "subscription:";
		const section = type(reference) == "string" && index(reference, prefix) == 0 ? substr(reference, length(prefix)) : null;
		push(recovery_options, subscriptions[i]);
		push(source_options, { kind: "profile", ref: reference, display_name: subscriptions[i].display_name });
		source_groups[`profile|${reference}`] = source_group_names({ kind: "profile", ref: reference });
		const path = resolve_profile(reference);
		const profile = path == null ? null : read_yaml(path);
		const found = type(profile) == "object" ? discover_regions(profile) : [];
		const region_ids = [];
		for (let j = 0; j < length(found); j++) {
			push(region_ids, found[j].id);
			region_options_by_id[found[j].id] = found[j];
		}
		if (section != null) push(provider_options, { id: section, section: section,
			display_name: subscriptions[i].display_name, region_ids: region_ids });
	}
	if (!has_reference(source_options, policy.policy_source.kind, policy.policy_source.ref) && resolve_policy_source(policy.policy_source) != null) {
		push(source_options, { kind: policy.policy_source.kind, ref: policy.policy_source.ref,
			display_name: policy.policy_source.kind == "bundle" ? "当前内置基础策略" :
				(profile_display_name(policy.policy_source.ref) ?? "当前基础配置") });
		source_groups[`${policy.policy_source.kind}|${policy.policy_source.ref}`] = source_group_names(policy.policy_source);
	}
	if (!has_reference(recovery_options, null, policy.recovery_profile.ref) && profile_exists(policy.recovery_profile.ref))
		push(recovery_options, { ref: policy.recovery_profile.ref,
			display_name: profile_display_name(policy.recovery_profile.ref) ?? "当前原生配置" });
	const region_options = [];
	const catalog = region_catalog();
	for (let i = 0; i < length(catalog); i++) {
		if (region_options_by_id[catalog[i].id] != null) push(region_options, region_options_by_id[catalog[i].id]);
	}
	return { backend: backend_metadata(), provider_names: provider_display_names(policy), policy_source_options: source_options,
		recovery_profile_options: recovery_options, provider_options: provider_options,
		region_options: region_options, policy_source_groups: source_groups };
};

projection = function(policy, inputs) {
	const result = project(policy, inputs);
	result.revision = sha256(POLICY_PATH);
	result.active = is_active(current_profile());
	const manifest = read_json(MANIFEST_PATH);
	result.pending_apply = manifest?.policy_sha256 != result.revision;
	return result;
};

load_change = function(policy, action, envelope_path) {
	const request = read_json(envelope_path)?.request;
	if (type(request) != "object") fail(action, "config_request_unreadable", null);
	const revision = sha256(POLICY_PATH);
	if (request.revision != revision) fail(action, "config_revision_conflict", { expected: revision, received: request.revision ?? null });
	const inputs = resources(policy);
	const merged = apply_request(policy, request, inputs);
	if (!merged.ok) fail(action, "config_invalid", { errors: merged.errors });
	return { resources: inputs, policy: merged.policy, changes: changes(policy, merged.policy, inputs) };
};

snapshot_file = function(path, name, required) {
	const exists = system(`test -f ${shell_quote(path)}`) == 0;
	if (!exists) return required ? null : { path: path, existed: false };
	const digest = sha256(path);
	const backup = `${WORK_DIR}/${name}`;
	if (digest == null || system(`cp -p ${shell_quote(path)} ${shell_quote(backup)}`) != 0 || sha256(backup) != digest) return null;
	return { path: path, backup: backup, digest: digest, existed: true };
};

prepare_snapshot = function() {
	if (system(`rm -rf ${shell_quote(WORK_DIR)}`) != 0 || system(`mkdir -p ${shell_quote(WORK_DIR)}`) != 0) return null;
	const files = [snapshot_file(POLICY_PATH, "policy.json", true), snapshot_file(ARTIFACT_PATH, "artifact.json", false), snapshot_file(MANIFEST_PATH, "manifest.json", false)];
	for (let i = 0; i < length(files); i++) if (files[i] == null) return null;
	return { files: files, active: is_active(current_profile()) };
};

restore_snapshot = function(snapshot) {
	let restored = true;
	for (let i = 0; i < length(snapshot?.files ?? []); i++) {
		const entry = snapshot.files[i];
		if (entry.existed != true) {
			if (system(`rm -f ${shell_quote(entry.path)}`) != 0) restored = false;
			continue;
		}
		const temporary = `${entry.path}.config-rollback`;
		if (system(`cp -p ${shell_quote(entry.backup)} ${shell_quote(temporary)}`) != 0 || sha256(temporary) != entry.digest ||
			system(`mv -f ${shell_quote(temporary)} ${shell_quote(entry.path)}`) != 0 || sha256(entry.path) != entry.digest) restored = false;
	}
	return restored;
};

diagnostic = function(path) {
	const process = popen(`head -n 16 ${shell_quote(path)} 2>/dev/null`);
	if (!process) return null;
	const lines = [];
	for (let i = 0; i < 16; i++) {
		const line = process.read("line");
		if (!line) break;
		push(lines, trim(line));
	}
	process.close();
	return length(lines) > 0 ? join("\n", lines) : null;
};

run_owner = function(action) {
	const output = `${WORK_DIR}/${action}.json`;
	const error_output = `${WORK_DIR}/${action}.stderr`;
	const exit_code = system(`ucode ${shell_quote(MAIN_PATH)} ${shell_quote(action)} luci >${shell_quote(output)} 2>${shell_quote(error_output)}`);
	const response = read_json(output);
	return { ok: exit_code == 0 && response?.ok == true, exit_code: exit_code, response: response,
		error: response?.error ?? (exit_code == 0 ? "owner_readback_failed" : `${action}_failed`),
		diagnostic: response == null ? { stderr: diagnostic(error_output), stdout: diagnostic(output) } : null };
};

cleanup_snapshot = function() {
	system(`rm -rf ${shell_quote(WORK_DIR)}`);
};

rollback = function(snapshot) {
	if (!restore_snapshot(snapshot)) return { ok: false, error: "snapshot_restore_failed" };
	const disabled = run_owner("disable");
	if (!disabled.ok) return { ok: false, error: "rollback_disable_failed", disable: disabled.response };
	if (snapshot.active != true) return { ok: true, state: "inactive_restored", disable: disabled.response };
	const providers = load_provider_profiles(load_policy());
	if (!providers.ok) return { ok: false, error: "rollback_provider_read_failed", detail: providers };
	if (!prepare_provider_links(providers.profiles)) {
		remove_provider_links(providers.profiles);
		return { ok: false, error: "rollback_provider_prepare_failed" };
	}
	const enabled = run_owner("enable");
	return enabled.ok ? { ok: true, state: "active_restored", enable: enabled.response } :
		{ ok: false, error: "rollback_enable_failed", enable: enabled.response };
};

fail_apply = function(snapshot, error, detail) {
	const restored = rollback(snapshot);
	cleanup_snapshot();
	if (!restored.ok) fail("config-apply", "config_apply_rollback_failed", { error: error, detail: detail, rollback: restored });
	fail("config-apply", error, { detail: detail, rollback: restored });
};

get = function(policy) {
	ok("config-get", projection(policy, resources(policy)));
};

validate = function(policy, envelope_path) {
	const change = load_change(policy, "config-validate", envelope_path);
	ok("config-validate", { valid: true, change_count: length(change.changes), changes: change.changes,
		current_revision: sha256(POLICY_PATH) });
};

save = function(policy, envelope_path) {
	if (is_active(current_profile())) fail("config-save", "active_requires_apply", null);
	const change = load_change(policy, "config-save", envelope_path);
	if (length(change.changes) == 0) {
		ok("config-save", { state: "unchanged", config: projection(policy, change.resources) });
		return;
	}
	if (!write_json_atomic(POLICY_PATH, change.policy)) fail("config-save", "policy_write_failed", null);
	const saved = load_policy();
	if (saved == null) fail("config-save", "policy_readback_failed", null);
	ok("config-save", { state: "saved", change_count: length(change.changes), changes: change.changes,
		config: projection(saved, resources(saved)) });
};

apply = function(policy, envelope_path) {
	const change = load_change(policy, "config-apply", envelope_path);
	const current = projection(policy, change.resources);
	if (length(change.changes) == 0 && current.active == true && current.pending_apply != true) {
		ok("config-apply", { state: "unchanged", config: current });
		return;
	}
	const snapshot = prepare_snapshot();
	if (snapshot == null) {
		cleanup_snapshot();
		fail("config-apply", "config_snapshot_failed", null);
	}
	if (snapshot.active == true) {
		const disabled = run_owner("disable");
		if (!disabled.ok) {
			cleanup_snapshot();
			fail("config-apply", "active_disable_failed", disabled.response);
		}
	}
	if (!write_json_atomic(POLICY_PATH, change.policy) || load_policy() == null) fail_apply(snapshot, "policy_write_failed", null);
	const compiled = run_owner("compile");
	if (!compiled.ok) fail_apply(snapshot, compiled.error, compiled);
	const enabled = run_owner("enable");
	if (!enabled.ok) fail_apply(snapshot, enabled.error, enabled);
	const applied = load_policy();
	const result = { state: "applied", previously_active: snapshot.active, change_count: length(change.changes),
		changes: change.changes, activation: enabled.response?.result ?? null,
		config: projection(applied, resources(applied)) };
	cleanup_snapshot();
	ok("config-apply", result);
};

command_config_get = function(argv) {
	const policy = load_policy();
	if (policy == null) fail(argv[0], "policy_unreadable", POLICY_PATH);
	return get(policy, argv[1]);
};

command_config_validate = function(argv) {
	const policy = load_policy();
	if (policy == null) fail(argv[0], "policy_unreadable", POLICY_PATH);
	return validate(policy, argv[1]);
};

command_config_save = function(argv) {
	const policy = load_policy();
	if (policy == null) fail(argv[0], "policy_unreadable", POLICY_PATH);
	return save(policy, argv[1]);
};

command_config_apply = function(argv) {
	const policy = load_policy();
	if (policy == null) fail(argv[0], "policy_unreadable", POLICY_PATH);
	return apply(policy, argv[1]);
};

return { get, validate, save, apply, command_config_get, command_config_validate, command_config_save, command_config_apply };
};
