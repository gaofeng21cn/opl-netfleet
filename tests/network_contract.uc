import { project, public_settings, validate_request, runtime_profile, error_code } from "../openwrt/files/usr/libexec/opl-netfleet/core/network.uc";

function check(value, reason) { if (!value) { print(`${reason}\n`); exit(1); } };
function clone(value) { return json(sprintf("%J", value)); };
let caught = null;
try { die("network_stage_failed"); } catch (error) { caught = error_code(error, "network_apply_failed"); }
check(caught == "network_stage_failed", "die_error_code_preserved");
check(error_code({ message: "network_stop_failed\nprivate context" }, "network_apply_failed") == "network_stop_failed", "object_error_code_preserved");
check(error_code("private error contents", "network_apply_failed") == "network_apply_failed", "uncontrolled_error_not_disclosed");
const profile = { "mixed-port": 7890, authentication: ["user:private-password"],
	"tproxy-port": 7892, "external-controller": "0.0.0.0:9090", secret: "unchanged-secret", private_field: { keep: true },
	dns: { nameserver: ["udp://127.0.0.1:1054"], "default-nameserver": ["198.51.100.53"],
		"proxy-server-nameserver": ["system"], "direct-nameserver": ["198.51.100.53"],
		"nameserver-policy": { "example.test": ["198.51.100.54"], "+.private.test": ["198.51.100.55"] },
		"proxy-server-nameserver-policy": { "exit.example.test": ["198.51.100.54"], "geosite:private": ["198.51.100.55"] },
		"fake-ip-filter": ["+.keep.test"], fallback: ["198.51.100.56"] } };
const sections = [
	{ ".name": "proxy", ".type": "proxy", lan_proxy: "1", router_proxy: "1", lan_inbound_interface: ["lan"] },
	{ ".name": "private_rule", ".type": "lan_access_control", enabled: "1", ip: ["192.0.2.10"], ip6: ["2001:db8::10"], mac: [], proxy: "0", dns: "0", private_field: "kept" },
	{ ".name": "fallback", ".type": "lan_access_control", enabled: "1", proxy: "1", dns: "1" }
];
const current = project(profile, sections);
const visible = public_settings(current);
check(visible.listeners.credentials[0].password == null && visible.listeners.credentials[0].password_configured, "password_not_disclosed");
check(current.listeners.credentials[0].password == "private-password", "private_owner_can_retain_password");
check(length(visible.dns.policies) == 1 && length(visible.dns.proxy_policies) == 1, "complex_policy_not_misrepresented_as_domain");
check(length(visible.lan.rules) == 2 && visible.lan.rules[1].proxy, "ordered_device_rules_projected");
const resources = { interfaces: [{ name: "lan" }, { name: "guest" }], reserved_ports: [7892, 9090, 1053] };
const request = { revision: "current", settings: visible };
const accepted = validate_request(request, "current", current, resources);
check(accepted.ok && accepted.settings.listeners.credentials[0].password == "private-password", "omitted_password_preserved");
check(!validate_request(request, "newer", current, resources).ok, "stale_revision_rejected");
function rejects(change, reason) {
	const candidate = clone(request);
	change(candidate.settings);
	check(!validate_request(candidate, "current", current, resources).ok, reason);
};
rejects((settings) => { settings.listeners.tproxy_port = 9999; }, "unowned_port_rejected");
rejects((settings) => { settings.listeners.mixed_port = 9090; }, "controller_port_collision_rejected");
rejects((settings) => { settings.listeners.mixed_port = 0; }, "proxy_probe_listener_retained");
rejects((settings) => { settings.dns.nameservers = ["file:///etc/passwd"]; }, "local_resolver_uri_rejected");
rejects((settings) => { settings.dns.proxy_nameservers = []; }, "proxy_policy_needs_default_resolver");
rejects((settings) => { settings.dns.nameservers = ["udp://example.test\nsecret"]; }, "resolver_control_character_rejected");
rejects((settings) => { settings.dns.policies = [{ domain: "+.example.test", nameservers: ["198.51.100.53"] }]; }, "wildcard_domain_rejected");
rejects((settings) => { settings.lan.interfaces = ["../../wan"]; }, "unowned_interface_rejected");
rejects((settings) => { settings.lan.rules[0].ipv4 = ["192.0.2.999"]; }, "invalid_ipv4_rejected");
rejects((settings) => { settings.lan.rules[0].ipv6 = ["2001:::1"]; }, "invalid_ipv6_rejected");
rejects((settings) => { settings.lan.rules[0].mac = ["00:11:22:33:44:zz"]; }, "invalid_mac_rejected");
rejects((settings) => { settings.lan.rules[0].id = "config"; }, "section_overwrite_rejected");
rejects((settings) => { settings.lan.rules = [settings.lan.rules[1], settings.lan.rules[0]]; }, "masked_rules_rejected");
rejects((settings) => { settings.listeners.credentials = [{ id: "new_user", username: "new" }]; }, "new_password_required");
rejects((settings) => { settings.listeners.credentials[0].username = "user:smuggled"; }, "authentication_separator_rejected");
const changed = clone(request);
changed.settings.lan.enabled = false;
changed.settings.router.enabled = false;
changed.settings.listeners.mixed_port = 17890;
changed.settings.dns.policies = [];
changed.settings.dns.proxy_policies = [];
const valid = validate_request(changed, "current", current, resources);
check(valid.ok, "supported_network_change_accepted");
const rendered = runtime_profile(profile, valid.settings);
check(rendered.dns["nameserver-policy"]["example.test"] == null && rendered.dns["proxy-server-nameserver-policy"]["exit.example.test"] == null,
	"deleted_exact_domain_removed");
check(rendered.dns["nameserver-policy"]["+.private.test"][0] == "198.51.100.55" && rendered.dns["proxy-server-nameserver-policy"]["geosite:private"][0] == "198.51.100.55",
	"complex_private_policy_preserved");
check(rendered.private_field.keep && rendered.secret == profile.secret && rendered["tproxy-port"] == 7892 && rendered.dns["fake-ip-filter"][0] == "+.keep.test" &&
	rendered.dns.fallback[0] == "198.51.100.56", "unrepresented_configuration_preserved");
check(rendered["mixed-port"] == 17890 && rendered.authentication[0] == "user:private-password", "candidate_listener_and_authentication");
print("network_contract passed\n");
