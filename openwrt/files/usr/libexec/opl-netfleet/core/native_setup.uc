import { desired_source } from "./subscriptions.uc";

export function validate_request(request, revision) {
	if (type(request) != "object" || request.confirmed != true)
		return { ok: false, error: "explicit_confirmation_required" };
	for (let key in request)
		if (index(["confirmed", "revision", "source"], key) < 0)
			return { ok: false, error: "unknown_setup_field" };
	if (type(revision) != "string" || request.revision != revision)
		return { ok: false, error: "setup_revision_conflict" };
	for (let key in request.source ?? {})
		if (index(["id", "name", "url", "user_agent"], key) < 0)
			return { ok: false, error: "unknown_setup_source_field" };
	return desired_source({ revision: revision, source: request.source }, null);
};

// These values originate in netifd, and the adapter separately checks the live route.
export function upstream_candidates(interfaces) {
	const result = [];
	const own = {};
	for (let entry in interfaces ?? []) {
		for (let field in ["ipv4-address", "ipv6-address"])
			for (let address in entry[field] ?? [])
				if (type(address?.address) == "string") own[lc(address.address)] = true;
	}
	for (let entry in interfaces ?? []) {
		if (entry?.up != true || index(["wan", "wan6"], entry.interface) < 0) continue;
		for (let address in entry["dns-server"] ?? []) {
			if (type(address) != "string") continue;
			address = lc(address);
			if (own[address] || index(result, address) >= 0) continue;
			if (match(address, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/)) {
				const octets = split(address, ".");
				if (length(filter(octets, part => int(part) > 255)) > 0 ||
					int(octets[0]) == 0 || int(octets[0]) == 127 || int(octets[0]) >= 224) continue;
			} else if (!match(address, /^[0-9a-f:]+$/) || index(address, ":") < 0 ||
				match(address, /^[0:]*1?$/) || match(address, /^fe[89ab]/) || index(address, "ff") == 0) continue;
			push(result, address);
		}
	}
	return result;
};
