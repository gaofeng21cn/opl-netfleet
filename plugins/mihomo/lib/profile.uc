/* SPDX-License-Identifier: Apache-2.0 */
// One projection for the native gateway and network configuration candidates.
return function(context) {
	function sniff(value) {
		if (type(value) != 'object') return value;
		const result = json(sprintf('%J', value));
		for (let protocol, settings in result) if (type(settings) == 'object') {
			// Read previously saved NetFleet port maps; all new writes use the
			// core's actual `ports` field. Preserve an existing canonical value.
			if (settings.ports == null && settings.port != null) settings.ports = settings.port;
			delete settings.port;
		}
		return result;
	}
	function ports(profile) {
		if (type(profile) != 'object') return profile;
		const result = { ...profile };
		if (type(profile.sniffer) == 'object') result.sniffer = { ...profile.sniffer,
			...(profile.sniffer.sniff != null ? { sniff: sniff(profile.sniffer.sniff) } : {}) };
		return result;
	}
	function normalize(profile) {
		const result = ports(profile), sniffer = result.sniffer;
		if (type(sniffer) != 'object') return result;
		// DNS reverse mapping is not a unique TLS identity for shared IPs.
		if (sniffer.enable === true && type(sniffer.sniff?.TLS) == 'object' &&
			(sniffer['force-dns-mapping'] === true || type(sniffer['force-domain']) == 'array' && length(sniffer['force-domain'])))
			sniffer.sniff.TLS['override-destination'] = true;
		return result;
	}
	return { sniff, ports, normalize };
};
