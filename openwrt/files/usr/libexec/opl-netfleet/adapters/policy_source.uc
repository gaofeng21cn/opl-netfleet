import { read_json, read_yaml } from "./uci.uc";
import { resolve_profile } from "./nikki.uc";

export const POLICY_SOURCE_DIR = "/etc/opl-netfleet/policy-sources";

function bundle_id(reference) {
	const parts = split(reference ?? "", ":");
	if (length(parts) != 2 || parts[0] != "bundle" ||
		!match(parts[1], /^[A-Za-z0-9][A-Za-z0-9_-]*$/)) {
		return null;
	}
	return parts[1];
};

export function resolve(source) {
	if (source?.kind == "profile") {
		return resolve_profile(source.ref);
	}
	if (source?.kind == "bundle") {
		const id = bundle_id(source.ref);
		return id == null ? null : `${POLICY_SOURCE_DIR}/${id}.json`;
	}
	return null;
};

export function load(source) {
	const path = resolve(source);
	if (path == null) {
		return null;
	}
	return source.kind == "bundle" ? read_json(path) : read_yaml(path);
};
