import { popen } from "fs";

return function(context) {
const ROOT_DIR = context.use("platform.runtime").ROOT_DIR;
const RUN_DIR = context.use("platform.runtime").RUN_DIR;
const shell_quote = context.use("platform.process").shell_quote;
const mkdir = context.use("platform.storage").mkdir;
const write_text = context.use("platform.storage").write_text;
const sha256 = context.use("platform.storage").sha256;
const ARTIFACT_DIR = `${ROOT_DIR}/profiles/opl-netfleet`;
const ARTIFACT_PATH = `${ARTIFACT_DIR}/mvp.json`;
const MANIFEST_PATH = `${ARTIFACT_DIR}/mvp.manifest.json`;
const PROFILE_ENTRY_PATH = `${ROOT_DIR}/profiles/OPL-NetFleet.json`;
const PROFILE_ENTRY_TARGET = "opl-netfleet/mvp.json";
const COMPILED_PROFILE = "file:OPL-NetFleet.json";
const PROXY_PROVIDER_DIR = `${RUN_DIR}/providers/proxy`;
let resolve_profile, profile_exists, provider_runtime_path, link_target, subscription_cache_path, prepare_provider_links, remove_provider_links, make_json, test_profile_object, install_artifact, remove_artifact;

resolve_profile = function(reference) {
	const parts = split(reference ?? "", ":");
	if (length(parts) != 2 || (parts[0] != "subscription" && parts[0] != "file") || length(parts[1]) == 0) {
		return null;
	}
	// Profile references are persisted in UCI and later passed to a shell
	// command. Keep the reference relative to the selected owner's directories and
	// reject traversal instead of treating an arbitrary path as a rollback.
	if (index(parts[1], "..") >= 0 || index(parts[1], "\\") >= 0 ||
		index(parts[1], "\n") >= 0 || index(parts[1], "\r") >= 0 ||
		substr(parts[1], 0, 1) == "/") {
		return null;
	}
	if (parts[0] == "subscription") {
		if (!match(parts[1], /^[A-Za-z0-9_]+$/)) {
			return null;
		}
		return `${ROOT_DIR}/subscriptions/${parts[1]}.yaml`;
	}
	return `${ROOT_DIR}/profiles/${parts[1]}`;
};

profile_exists = function(reference) {
	const path = resolve_profile(reference);
	return path != null && system(`test -f ${shell_quote(path)}`) == 0;
};

provider_runtime_path = function(provider_name) {
	return `${PROXY_PROVIDER_DIR}/netfleet-${provider_name}.yaml`;
};

link_target = function(path) {
	const process = popen(`readlink ${shell_quote(path)}`);
	if (!process) {
		return null;
	}
	const target = process.read("line");
	process.close();
	return target ? trim(target) : null;
};

subscription_cache_path = function(path) {
	const prefix = `${ROOT_DIR}/subscriptions/`;
	return type(path) == "string" && index(path, prefix) == 0 &&
		match(substr(path, length(prefix)), /^[A-Za-z0-9_]+\.yaml$/);
};

prepare_provider_links = function(provider_profiles) {
	if (!mkdir(PROXY_PROVIDER_DIR)) {
		return false;
	}
	const names = keys(provider_profiles ?? {});
	for (let i = 0; i < length(names); i++) {
		const name = names[i];
		const source = provider_profiles[name]?.path;
		const target = provider_runtime_path(name);
		if (!source || !target) {
			return false;
		}
		if (system(`test -L ${shell_quote(target)}`) == 0) {
			const existing = link_target(target);
			if (existing == source) {
				continue;
			}
			if (!subscription_cache_path(existing) || !subscription_cache_path(source) ||
				system(`ln -sfn ${shell_quote(source)} ${shell_quote(target)}`) != 0 ||
				link_target(target) != source) {
				return false;
			}
			continue;
		}
		if (system(`test -e ${shell_quote(target)}`) == 0 ||
			system(`ln -s ${shell_quote(source)} ${shell_quote(target)}`) != 0) {
			return false;
		}
	}
	return true;
};

remove_provider_links = function(provider_profiles) {
	const names = keys(provider_profiles ?? {});
	let removed = true;
	for (let i = 0; i < length(names); i++) {
		const name = names[i];
		const source = provider_profiles[name]?.path;
		const target = provider_runtime_path(name);
		if (!source) continue;
		const is_link = system(`test -L ${shell_quote(target)}`) == 0;
		if (!is_link && system(`test -e ${shell_quote(target)}`) != 0) continue;
		if (!is_link || link_target(target) != source ||
			system(`rm -f ${shell_quote(target)}`) != 0) removed = false;
	}
	return removed;
};

make_json = function(profile) {
	return sprintf("%J", profile);
};

test_profile_object = function(profile) {
	const text = make_json(profile);
	if (text == null || !mkdir(ARTIFACT_DIR) || !write_text(`${ARTIFACT_DIR}/.test.json`, text)) {
		return false;
	}
	const result = system(`mihomo -d ${shell_quote(RUN_DIR)} -f ${shell_quote(`${ARTIFACT_DIR}/.test.json`)} -t >/dev/null 2>&1`) == 0;
	system(`rm -f ${shell_quote(`${ARTIFACT_DIR}/.test.json`)}`);
	return result;
};

install_artifact = function(profile, manifest) {
	const profile_text_value = make_json(profile);
	if (profile_text_value == null || type(manifest) != "object" || !mkdir(ARTIFACT_DIR)) {
		return false;
	}
	if (system(`test -L ${shell_quote(PROFILE_ENTRY_PATH)}`) == 0) {
		if (link_target(PROFILE_ENTRY_PATH) != PROFILE_ENTRY_TARGET) {
			return false;
		}
	} else if (system(`test -e ${shell_quote(PROFILE_ENTRY_PATH)}`) == 0) {
		return false;
	}
	const profile_tmp = `${ARTIFACT_DIR}/.mvp.json.tmp`;
	const manifest_tmp = `${ARTIFACT_DIR}/.mvp.manifest.json.tmp`;
	if (!write_text(profile_tmp, profile_text_value)) {
		system(`rm -f ${shell_quote(profile_tmp)} ${shell_quote(manifest_tmp)}`);
		return false;
	}
	const artifact_digest = sha256(profile_tmp);
	if (artifact_digest == null) {
		system(`rm -f ${shell_quote(profile_tmp)} ${shell_quote(manifest_tmp)}`);
		return false;
	}
	manifest.artifact_sha256 = artifact_digest;
	if (!write_text(manifest_tmp, sprintf("%J", manifest)) ||
		system(`mihomo -d ${shell_quote(RUN_DIR)} -f ${shell_quote(profile_tmp)} -t >/dev/null 2>&1`) != 0) {
		system(`rm -f ${shell_quote(profile_tmp)} ${shell_quote(manifest_tmp)}`);
		return false;
	}
	if (system(`mv -f ${shell_quote(profile_tmp)} ${shell_quote(ARTIFACT_PATH)}`) != 0 ||
		system(`mv -f ${shell_quote(manifest_tmp)} ${shell_quote(MANIFEST_PATH)}`) != 0) {
		system(`rm -f ${shell_quote(profile_tmp)} ${shell_quote(manifest_tmp)}`);
		return false;
	}
	if (system(`test -L ${shell_quote(PROFILE_ENTRY_PATH)}`) != 0 &&
		system(`ln -s ${shell_quote(PROFILE_ENTRY_TARGET)} ${shell_quote(PROFILE_ENTRY_PATH)}`) != 0) {
		return false;
	}
	return link_target(PROFILE_ENTRY_PATH) == PROFILE_ENTRY_TARGET &&
		sha256(ARTIFACT_PATH) == artifact_digest &&
		sha256(PROFILE_ENTRY_PATH) == artifact_digest &&
		system(`mihomo -d ${shell_quote(RUN_DIR)} -f ${shell_quote(PROFILE_ENTRY_PATH)} -t >/dev/null 2>&1`) == 0;
};

remove_artifact = function() {
	if (system(`test -L ${shell_quote(PROFILE_ENTRY_PATH)}`) == 0) {
		if (link_target(PROFILE_ENTRY_PATH) != PROFILE_ENTRY_TARGET ||
			system(`rm -f ${shell_quote(PROFILE_ENTRY_PATH)}`) != 0) return false;
	} else if (system(`test -e ${shell_quote(PROFILE_ENTRY_PATH)}`) == 0) {
		return false;
	}
	return system(`rm -f ${shell_quote(ARTIFACT_PATH)} ${shell_quote(MANIFEST_PATH)}`) == 0;
};

return { ARTIFACT_DIR, ARTIFACT_PATH, MANIFEST_PATH, PROFILE_ENTRY_PATH, PROFILE_ENTRY_TARGET, COMPILED_PROFILE, PROXY_PROVIDER_DIR, resolve_profile, profile_exists, provider_runtime_path, link_target, subscription_cache_path, prepare_provider_links, remove_provider_links, make_json, test_profile_object, install_artifact, remove_artifact };
};
