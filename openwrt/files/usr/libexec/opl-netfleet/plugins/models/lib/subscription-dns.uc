/* SPDX-License-Identifier: Apache-2.0 */
// Only accepted provider caches enter this pure compiler projection.
function loopback_resolver(value) {
	const address = replace(lc(value), /^[a-z][a-z0-9+.-]*:\/\//, '');
	const authority = split(split(split(address, '/')[0], '?')[0], '#')[0];
	return match(authority, /^(localhost\.?|127\.[0-9]+\.[0-9]+\.[0-9]+)(:[0-9]+)?$/) != null ||
		match(authority, /^\[[0:]*:1\](:[0-9]+)?$/) != null || authority == '::1';
};

function resolvers(value) {
	const values = type(value) == 'array' ? value : value == null ? [] : [value];
	if (!length(values)) return null;
	for (let item in values)
		if (type(item) != 'string' || !length(item) || match(item, /[[:space:][:cntrl:]]/)) return null;
	// A subscription cannot provision a resolver on this device's loopback.
	// Preserve device-owned local DNS and all portable subscription resolvers.
	return filter(values, item => !loopback_resolver(item));
};

function matching(host, policies) {
	let best = null, specificity = -1;
	for (let key, value in policies ?? {}) {
		const name = lc(key), suffix = substr(name, 0, 2) == '+.', domain = suffix ? substr(name, 2) : name;
		if (host != domain && !(suffix && substr(host, -length(domain) - 1) == '.' + domain)) continue;
		const rank = length(domain) * 2 + (suffix ? 0 : 1);
		if (rank > specificity) { best = { value }; specificity = rank; }
	}
	return best;
};

export function project_dns(names, providers) {
	const policies = {}, owners = {};
	for (let id in names) {
		const profile = providers[id].profile, dns = profile.dns;
		if (dns == null) continue;
		if (type(dns) != 'object') return { ok: false, error: `invalid subscription DNS: ${id}` };
		for (let field in ['proxy-server-nameserver-policy', 'nameserver-policy'])
			if (dns[field] != null && type(dns[field]) != 'object') return { ok: false, error: `invalid subscription DNS policy: ${id}` };
		for (let node in profile.proxies ?? []) {
			if (type(node.server) != 'string') continue;
			const host = lc(replace(node.server, /\.$/, ''));
			if (!length(host) || match(host, /^[0-9.]+$/) || index(host, ':') >= 0) continue;
			const rule = matching(host, dns['proxy-server-nameserver-policy']) ?? matching(host, dns['nameserver-policy']);
			const declared = rule != null ? rule.value : dns['proxy-server-nameserver'];
			if (rule == null && (declared == null || type(declared) == 'array' && !length(declared))) continue;
			const values = resolvers(declared);
			if (values == null) return { ok: false, error: `invalid subscription DNS resolvers: ${id}` };
			if (!length(values)) continue;
			if (policies[host] != null && sprintf('%J', policies[host]) != sprintf('%J', values))
				return { ok: false, error: `subscription DNS conflict: ${owners[host]}/${id}` };
			policies[host] = values;
			owners[host] = id;
		}
	}
	return { ok: true, policies };
};

export function manual_dns(profile, source) {
	const result = { ...profile, dns: { ...(profile.dns ?? {}) } };
	const field = 'proxy-server-nameserver-policy';
	if (type(result.dns[field]) == 'object') {
		result.dns[field] = { ...result.dns[field] };
		for (let host in keys(result.dns[field]))
			if (source?.['netfleet-subscription-dns']?.[lc(replace(host, /\.$/, ''))] != null) delete result.dns[field][host];
	}
	return result;
};
export function apply_dns(profile, source) {
	const managed = source?.['netfleet-subscription-dns'];
	const result = { ...profile };
	delete result['netfleet-subscription-dns'];
	if (type(managed) != 'object' || !length(keys(managed))) return result;
	result['netfleet-subscription-dns'] = managed;
	result.dns = manual_dns(profile, source).dns;
	const dns = result.dns;
	if (!length(dns['proxy-server-nameserver'] ?? [])) {
		dns['proxy-server-nameserver'] = length(dns.nameserver ?? []) ? dns.nameserver : ['system'];
		dns['proxy-server-nameserver-policy'] = { ...(dns['nameserver-policy'] ?? {}), ...(dns['proxy-server-nameserver-policy'] ?? {}) };
	}
	dns['proxy-server-nameserver-policy'] = { ...(dns['proxy-server-nameserver-policy'] ?? {}), ...managed };
	return result;
};
