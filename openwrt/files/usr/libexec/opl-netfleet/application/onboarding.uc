import { read_yaml, read_json, write_json_atomic, sha256, sha256_text, device_name, current_profile, backend_enabled, set_backend_enabled, api_secret, set_profile, shell_quote, subscription_display_name, subscription_options, POLICY_PATH, EVIDENCE_PATH } from "../adapters/uci.uc";
import { popen } from "fs";
import { resolve_profile, restart, remove_artifact, remove_provider_links, running, ARTIFACT_PATH, MANIFEST_PATH, PROFILE_ENTRY_PATH, COMPILED_PROFILE } from "../adapters/backend.uc";
import { controller_ready, test_runtime } from "../adapters/mihomo.uc";
import { service_state, set_service_state } from "../adapters/service.uc";
import { validate as validate_policy } from "../core/policy.uc";
import { is_active } from "../core/activation.uc";
import { discover } from "../core/onboarding.uc";
import { load as load_provider_profiles } from "./providers.uc";
import { ok, fail } from "../output.uc";

const WORK_DIR = "/tmp/opl-netfleet-onboarding";
const MAIN_PATH = "/usr/libexec/opl-netfleet/main.uc";

function load_policy() {
	const policy = read_json(POLICY_PATH);
	return validate_policy(policy).ok ? policy : null;
};

function profile_display_name(reference) {
	const prefix = "subscription:";
	if (type(reference) == "string" && index(reference, prefix) == 0) {
		const section = substr(reference, length(prefix));
		const display = subscription_display_name(section);
		if (display != section) return display;
	}
	return "当前原生配置";
};

function discovery() {
	const profile_ref = current_profile();
	const profile_path = resolve_profile(profile_ref);
	const profile_digest = profile_path == null ? null : sha256(profile_path);
	const profile = profile_digest == null ? null : read_yaml(profile_path);
	const subscriptions = [];
	const options = subscription_options();
	for (let i = 0; i < length(options); i++) {
		const reference = options[i]?.ref;
		const section = type(reference) == "string" && index(reference, "subscription:") == 0 ?
			substr(reference, length("subscription:")) : null;
		const path = resolve_profile(reference);
		const digest = path == null ? null : sha256(path);
		push(subscriptions, {
			section: section,
			display_name: options[i]?.display_name ?? section,
			digest: digest,
			profile: digest == null ? null : read_yaml(path)
		});
	}
	const secret = api_secret();
	const generated_artifacts_present = system(`test -e ${shell_quote(ARTIFACT_PATH)} -o -e ${shell_quote(MANIFEST_PATH)} -o -e ${shell_quote(PROFILE_ENTRY_PATH)}`) == 0;
	const result = discover({
		target: device_name(), current_profile: profile_ref,
		current_profile_display_name: profile_display_name(profile_ref),
		current_profile_digest: profile_digest, current_profile_object: profile,
		subscriptions: subscriptions, backend_enabled: backend_enabled(),
		mihomo_running: running(), runtime_valid: test_runtime(),
		controller_ready: type(secret) == "string" && length(secret) > 0 && controller_ready(secret, 2),
		generated_artifacts_present: generated_artifacts_present
	});
	if (system(`test -e ${shell_quote(POLICY_PATH)}`) == 0) {
		result.ready = false;
		push(result.blockers, { code: "existing_policy_unreadable", detail: null });
	}
	if (result.ready) {
		const validation = validate_policy(result.policy);
		if (!validation.ok) {
			result.ready = false;
			push(result.blockers, { code: "generated_policy_invalid", detail: validation.errors });
		}
	}
	result.revision = result.ready ? sha256_text(sprintf("%J", result.revision_input)) : null;
	if (result.ready && result.revision == null) {
		result.ready = false;
		push(result.blockers, { code: "revision_unavailable", detail: null });
	}
	return result;
};

function projection(value) {
	return { required: true, ready: value.ready == true, revision: value.revision ?? null,
		blockers: value.blockers ?? [], warnings: value.warnings ?? [], preview: value.preview };
};

function diagnostic(path) {
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

function run_owner(action) {
	const output = `${WORK_DIR}/${action}.json`;
	const error_output = `${WORK_DIR}/${action}.stderr`;
	const exit_code = system(`ucode ${shell_quote(MAIN_PATH)} ${shell_quote(action)} luci >${shell_quote(output)} 2>${shell_quote(error_output)}`);
	const response = read_json(output);
	return { ok: exit_code == 0 && response?.ok == true, response: response,
		error: response?.error ?? `${action}_failed`, exit_code: exit_code,
		diagnostic: response == null ? { stderr: diagnostic(error_output), stdout: diagnostic(output) } : null };
};

function cleanup(found, snapshot) {
	let disabled = { ok: true, response: null };
	if (system(`test -e ${shell_quote(MANIFEST_PATH)}`) == 0 || is_active(current_profile())) disabled = run_owner("disable");
	const provider_result = load_provider_profiles(found?.policy);
	if (provider_result.ok) remove_provider_links(provider_result.profiles);
	let native_ok = current_profile() == snapshot.profile && backend_enabled() == true && running() && test_runtime();
	if (!native_ok && set_profile(snapshot.profile) && set_backend_enabled(true) && restart())
		native_ok = current_profile() == snapshot.profile && backend_enabled() == true && running() && test_runtime();
	const artifact_removed = remove_artifact();
	const policy_removed = system(`rm -f ${shell_quote(POLICY_PATH)}`) == 0;
	let evidence_restored = true;
	if (snapshot.evidence_existed == true)
		evidence_restored = system(`cp -p ${shell_quote(snapshot.evidence_backup)} ${shell_quote(EVIDENCE_PATH)}`) == 0 && sha256(EVIDENCE_PATH) == snapshot.evidence_digest;
	else evidence_restored = system(`rm -f ${shell_quote(EVIDENCE_PATH)}`) == 0;
	const service = set_service_state(snapshot.service);
	return { ok: disabled.ok && native_ok && artifact_removed && policy_removed && evidence_restored && service.ok,
		disable: disabled.response, native_profile_restored: native_ok, artifact_removed: artifact_removed,
		policy_removed: policy_removed, evidence_restored: evidence_restored, service: service.readback };
};

function fail_apply(found, snapshot, error, detail) {
	const rollback = cleanup(found, snapshot);
	system(`rm -rf ${shell_quote(WORK_DIR)}`);
	if (!rollback.ok) fail("onboarding-apply", "onboarding_rollback_failed", { error: error, detail: detail, rollback: rollback });
	fail("onboarding-apply", error, { detail: detail, rollback: rollback });
};

export function get(configured_policy) {
	if (configured_policy != null) {
		ok("onboarding-get", { required: false, ready: false, revision: null, blockers: [], warnings: [], preview: null });
		return;
	}
	ok("onboarding-get", projection(discovery()));
};

export function apply(envelope_path) {
	if (load_policy() != null || system(`test -e ${shell_quote(POLICY_PATH)}`) == 0) fail("onboarding-apply", "already_configured", null);
	const envelope = read_json(envelope_path);
	const request = envelope?.request;
	if (type(request) != "object") fail("onboarding-apply", "onboarding_request_unreadable", null);
	if (request.confirmed != true) fail("onboarding-apply", "explicit_confirmation_required", null);
	const found = discovery();
	if (!found.ready) fail("onboarding-apply", "onboarding_not_ready", projection(found));
	if (request.revision != found.revision) fail("onboarding-apply", "onboarding_revision_conflict", { expected: found.revision, received: request.revision ?? null });
	if (system(`rm -rf ${shell_quote(WORK_DIR)}`) != 0 || system(`mkdir -p ${shell_quote(WORK_DIR)}`) != 0)
		fail("onboarding-apply", "onboarding_snapshot_failed", null);
	const evidence_existed = system(`test -f ${shell_quote(EVIDENCE_PATH)}`) == 0;
	const evidence_backup = `${WORK_DIR}/evidence.json`;
	const evidence_digest = evidence_existed ? sha256(EVIDENCE_PATH) : null;
	if (evidence_existed && (evidence_digest == null || system(`cp -p ${shell_quote(EVIDENCE_PATH)} ${shell_quote(evidence_backup)}`) != 0 || sha256(evidence_backup) != evidence_digest)) {
		system(`rm -rf ${shell_quote(WORK_DIR)}`);
		fail("onboarding-apply", "onboarding_snapshot_failed", null);
	}
	const snapshot = { profile: current_profile(), service: service_state(), evidence_existed: evidence_existed,
		evidence_backup: evidence_backup, evidence_digest: evidence_digest };
	if (!write_json_atomic(POLICY_PATH, found.policy) || load_policy() == null) fail_apply(found, snapshot, "policy_write_failed", null);
	const compiled = run_owner("compile");
	if (!compiled.ok) fail_apply(found, snapshot, compiled.error, compiled);
	const enabled = run_owner("enable");
	if (!enabled.ok) fail_apply(found, snapshot, enabled.error, enabled);
	const service = set_service_state({ enabled: true, running: true });
	if (!service.ok) fail_apply(found, snapshot, "supervisor_start_failed", service.readback);
	const readback = run_owner("status");
	if (!readback.ok || current_profile() != COMPILED_PROFILE || service.readback.enabled != true || service.readback.running != true)
		fail_apply(found, snapshot, "onboarding_readback_failed", readback);
	system(`rm -rf ${shell_quote(WORK_DIR)}`);
	ok("onboarding-apply", { state: "active", recovery_profile_display_name: found.preview.recovery_profile_display_name,
		provider_count: length(found.preview.providers), region_count: length(found.preview.regions),
		entry_group: found.preview.entry_group, activation: enabled.response?.result ?? null,
		service: service.readback, status: readback.response?.result ?? null });
};
