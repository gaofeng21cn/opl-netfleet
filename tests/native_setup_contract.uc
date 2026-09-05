import { validate_request, upstream_candidates } from "../openwrt/files/usr/libexec/opl-netfleet/core/native_setup.uc";

function check(value, reason) {
	if (!value) { print(`${reason}\n`); exit(1); }
};
const source = { id: "alpha", name: "Alpha", url: "https://subscription.example.invalid/profile?token=private" };
const request = { confirmed: true, revision: "revision", source: source };
const accepted = validate_request(request, "revision");
check(accepted.ok && accepted.source.id == "alpha" && accepted.source.user_agent == "clash.meta", "initial_source_rejected");
check(!validate_request({ ...request, confirmed: false }, "revision").ok, "confirmation_required");
check(!validate_request(request, "new-revision").ok, "stale_setup_rejected");
check(!validate_request({ ...request, overwrite: true }, "revision").ok, "unknown_setup_field_rejected");
check(!validate_request({ ...request, source: { ...source, url: "file:///etc/passwd" } }, "revision").ok,
	"local_source_rejected");
check(!validate_request({ ...request, source: { ...source, id: "../alpha" } }, "revision").ok, "source_path_rejected");
check(!validate_request({ ...request, source: { ...source, user_agent: "agent\nheader" } }, "revision").ok,
	"source_control_character_rejected");
check(!validate_request({ ...request, source: { ...source, info_url: source.url } }, "revision").ok,
	"unrequested_setup_source_field_rejected");
const upstream = upstream_candidates([
	{ interface: "lan", up: true, "ipv4-address": [{ address: "192.0.2.1" }], "dns-server": ["203.0.113.10"] },
	{ interface: "wan", up: true, "ipv4-address": [{ address: "192.0.2.2" }],
		"dns-server": ["192.0.2.1", "192.0.2.2", "127.0.0.1", "0.0.0.0", "300.1.1.1", "224.0.0.1",
			"198.51.100.53", "198.51.100.53", "https://resolver.example.invalid/dns-query", "1.1.1.1;exit"] },
	{ interface: "wan6", up: true, "ipv6-address": [{ address: "2001:db8::1" }],
		"dns-server": ["2001:db8::1", "2001:db8::53", "fe80::53", "febf::53", "::", "::1", "0:0:0:0:0:0:0:1"] },
	{ interface: "wan", up: false, "dns-server": ["203.0.113.53"] }
]);
check(length(upstream) == 2 && upstream[0] == "198.51.100.53" && upstream[1] == "2001:db8::53",
	"only_current_wan_ip_resolvers");
check(length(upstream_candidates([])) == 0, "no_invented_dns_default");
print("native_setup_contract passed\n");
