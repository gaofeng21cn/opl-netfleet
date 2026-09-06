export const BACKUP_FORMAT = "netfleet-backup-v1";
export const MAX_PROFILE_BYTES = 8388608;
export const MAX_BACKUP_BYTES = 33554432;

export function profile_id(id) {
	return type(id) == "string" && length(id) <= 120 &&
		match(id, /^[A-Za-z0-9][A-Za-z0-9_.-]*\.(json|yaml|yml)$/) != null &&
		index(id, "..") < 0 && id != "OPL-NetFleet.json";
};

export function file_path(path) {
	if (type(path) != "string" || length(path) > 240 ||
		!match(path, /^[A-Za-z0-9][A-Za-z0-9_./-]*$/) || index(path, "..") >= 0) return false;
	const parts = split(path, "/");
	if (length(filter(parts, part => part == "" || part == ".")) > 0) return false;
	if (path == "native/mixin.json") return true;
	if (parts[0] == "policy-sources") return length(parts) == 2 && match(parts[1], /^[A-Za-z0-9][A-Za-z0-9_-]*\.json$/) != null;
	if (parts[0] != "native") return false;
	if (parts[1] == "profiles") return length(parts) == 3 && profile_id(parts[2]);
	if (parts[1] == "subscriptions") return length(parts) == 3 && match(parts[2], /^[A-Za-z0-9_]+\.yaml$/) != null;
	if (index(["providers", "rulesets", "geodata", "certs"], parts[1]) >= 0) return length(parts) > 2;
	if (parts[1] != "run") return false;
	if (length(parts) == 3) return index(["geoip.dat", "geosite.dat", "country.mmdb", "GeoIP.dat", "GeoSite.dat", "Country.mmdb", "ASN.mmdb"], parts[2]) >= 0;
	return length(parts) > 3 && index(["providers", "rulesets", "geodata", "certs"], parts[2]) >= 0 &&
		index(path, "native/run/providers/proxy/netfleet-") != 0;
};

export function profile_referenced(id, policy, selected) {
	const ref = `file:${id}`;
	return selected == ref || policy?.policy_source?.ref == ref || policy?.recovery_profile?.ref == ref;
};

function valid_option(value) {
	if (type(value) == "string") return length(value) <= 32768 && index(value, "\u0000") < 0;
	return type(value) == "array" && length(value) <= 2048 &&
		length(filter(value, entry => type(entry) != "string" || length(entry) > 32768 || index(entry, "\u0000") >= 0)) == 0;
};

export function validate_backup(value) {
	if (type(value) != "object" || value.format != BACKUP_FORMAT ||
		length(filter(keys(value), key => index(["format", "created_at", "policy", "sections", "files"], key) < 0)) > 0 ||
		type(value.sections) != "array" || !length(value.sections) || length(value.sections) > 512 ||
		type(value.files) != "array" || length(value.files) > 2048 || type(value.policy) != "object")
		return { ok: false, error: "invalid_backup_format" };
	const sections = {}, paths = {};
	let bytes = 0;
	for (let section in value.sections) {
		if (type(section) != "object" || length(keys(section)) != 3 ||
			!match(section.name ?? "", /^[A-Za-z0-9_]+$/) || !match(section.type ?? "", /^[A-Za-z0-9_]+$/) ||
			type(section.options) != "object" || sections[section.name] != null)
			return { ok: false, error: "invalid_backup_section" };
		for (let key, option in section.options)
			if (!match(key, /^[A-Za-z0-9_]+$/) || !valid_option(option)) return { ok: false, error: "invalid_backup_option" };
		sections[section.name] = section;
	}
	if (sections.config?.type != "config" || sections.mixin?.type != "mixin")
		return { ok: false, error: "missing_backup_configuration" };
	if (sections.proxy?.options?.tcp_mode != "tproxy" || sections.proxy?.options?.udp_mode != "tproxy" ||
		`${sections.mixin.options.tun_enabled ?? "0"}` == "1") return { ok: false, error: "tproxy_mode_required" };
	for (let file in value.files) {
		if (type(file) != "object" || length(keys(file)) != 3 || !file_path(file.path) || paths[file.path] != null ||
			file.encoding != "base64" || type(file.content) != "string" || !match(file.content, /^[A-Za-z0-9+/]*={0,2}$/) ||
			length(file.content) % 4 != 0 || length(file.content) > MAX_PROFILE_BYTES * 4 / 3 + 4)
			return { ok: false, error: "invalid_backup_file" };
		let decoded;
		try { decoded = b64dec(file.content); } catch (error) { return { ok: false, error: "invalid_backup_encoding" }; }
		if (decoded == null || b64enc(decoded) != file.content || length(decoded) > MAX_PROFILE_BYTES)
			return { ok: false, error: "invalid_backup_encoding" };
		bytes += length(file.content);
		if (bytes > MAX_BACKUP_BYTES) return { ok: false, error: "backup_too_large" };
		paths[file.path] = true;
	}
	function has_ref(ref) {
		if (type(ref) != "string") return false;
		const parts = split(ref, ":");
		if (length(parts) != 2) return false;
		if (parts[0] == "file") return profile_id(parts[1]) && paths[`native/profiles/${parts[1]}`] == true;
		if (parts[0] == "subscription") return match(parts[1], /^[A-Za-z0-9_]+$/) != null &&
			sections[parts[1]]?.type == "subscription" && paths[`native/subscriptions/${parts[1]}.yaml`] == true;
		if (parts[0] == "bundle") return paths[`policy-sources/${parts[1]}.json`] == true;
		return false;
	}
	if (!has_ref(value.policy.policy_source?.ref) || !has_ref(value.policy.recovery_profile?.ref))
		return { ok: false, error: "backup_profile_reference_missing" };
	for (let name, provider in value.policy.providers ?? {})
		if (sections[provider.section]?.type != "subscription" || provider.enabled == true && !has_ref(`subscription:${provider.section}`))
			return { ok: false, error: "backup_subscription_reference_missing" };
	return { ok: true };
};

export function redact_line(text, secrets) {
	let line = `${text ?? ""}`;
	for (let secret in secrets ?? []) if (type(secret) == "string" && length(secret) > 0) line = replace(line, secret, "[redacted]");
	line = replace(line, /[A-Za-z][A-Za-z0-9+.-]*:\/\/[^[:space:]"'<>]+/g, "[url redacted]");
	line = replace(line, /((api[_-]?secret|secret|password|passwd|token|authorization|uuid)[[:space:]"']*[:=][[:space:]"']*)[^[:space:],}"']+/gi, "$1[redacted]");
	return substr(line, 0, 1024);
};
