import { create } from "/usr/libexec/opl-netfleet/kernel/host.uc";
import { create as create_adapter } from "/usr/libexec/opl-netfleet/adapters/openwrt.uc";
const host = create("/usr/libexec/opl-netfleet", { adapter: create_adapter() });
import * as fs from "fs";
import { cursor } from "uci";
const get = host.use("network.editor").get;
const validate = host.use("network.editor").validate;
const apply = host.use("network.editor").apply;
const atomic_json = host.use("platform.files").atomic_json;
const read_json = host.use("platform.storage").read_json;
const sha256 = host.use("platform.storage").sha256;
const api_secret = host.use("platform.credentials").api_secret;
const proxies = host.use("mihomo.controller").proxies;

const work = ARGV[0];
const phase = ARGV[1] ?? "apply";
function check(value, reason) { if (!value) die(reason); };
function clone(value) { return json(sprintf("%J", value)); };
function request(settings, revision) {
	const path = `${work}/request.json`;
	check(atomic_json(path, { request: { revision: revision, settings: settings } }), "request_write_failed");
	return path;
};
function choices() {
	const result = {};
	for (let name, value in proxies(api_secret(), 2)?.proxies ?? {})
		if (value.type == "Selector") result[name] = value.now;
	return result;
};

if (phase == "legacy_sniff") {
	const source = fs.realpath(host.use("mihomo.backend").resolve_profile(host.use("platform.profile").current_profile()));
	const mixin = "/etc/opl-netfleet/native/mixin.json";
	const original_source = fs.readfile(source), original_mixin = fs.readfile(mixin), original_uci = fs.readfile("/etc/config/netfleet");
	const profile = json(original_source), extra = original_mixin == null ? {} : json(original_mixin);
	profile.sniffer = { enable: false, sniff: { TLS: { port: [443] } } };
	extra.sniffer = { sniff: { HTTP: { port: [80] } } };
	delete extra["netfleet-replace-sniff"];
	const uci = cursor();
	uci.delete("netfleet", "mixin", "sniffer_sniff");
	check(uci.commit("netfleet") && atomic_json(source, profile) && atomic_json(mixin, extra), "legacy_sniff_fixture");
	const legacy = get();
	check(legacy.ok && length(keys(legacy.result.settings.advanced["sniffer.sniff"])) == 2, "legacy_partial_overlay_preserved");
	extra["netfleet-replace-sniff"] = true;
	check(atomic_json(mixin, extra), "explicit_sniff_fixture");
	const replaced = get();
	check(replaced.ok && length(keys(replaced.result.settings.advanced["sniffer.sniff"])) == 1, "explicit_protocol_replacement");
	fs.writefile(source, original_source);
	if (original_mixin == null) fs.unlink(mixin); else fs.writefile(mixin, original_mixin);
	fs.writefile("/etc/config/netfleet", original_uci);
} else if (phase == "apply") {
	const uci = cursor();
	check(uci.set("netfleet", "proxy", "network_vm_private", "preserve") && uci.commit("netfleet"), "private_uci_fixture");
	const extra = read_json("/etc/opl-netfleet/native/mixin.json") ?? {};
	if (extra.hosts == null) extra.hosts = {};
	extra.hosts["network-private.test"] = "203.0.113.88";
	check(atomic_json("/etc/opl-netfleet/native/mixin.json", extra), "private_mixin_fixture");
	const current = get();
	check(current.ok && current.result.available && current.result.running, "network_get_native_runtime");
	check(atomic_json(`${work}/initial-settings.json`, current.result.settings), "save_initial_settings");
	check(atomic_json(`${work}/initial-choices.json`, choices()), "save_initial_choices");
	const config_before = sha256("/etc/config/netfleet");
	const changed = clone(current.result.settings);
	changed.advanced["tcp-concurrent"] = !(changed.advanced["tcp-concurrent"] ?? false);
	changed.advanced["log-level"] = "warning";
	changed.advanced["sniffer.sniff"] = { HTTP: { port: [80, "8080-8081"], "override-destination": false } };
	changed.listeners.mixed_port = 17890;
	changed.listeners.http_port = 0;
	changed.listeners.socks_port = 0;
	changed.listeners.authentication_enabled = true;
	changed.listeners.credentials = [{ id: "new_network_vm", username: "network-vm", password: "network-vm-private" }];
	changed.dns.policies = [...changed.dns.policies, { domain: "management-proof.test", nameservers: ["udp://127.0.0.1:1054"] }];
	changed.dns.proxy_nameservers = ["udp://127.0.0.1:1054"];
	changed.dns.proxy_policies = [...changed.dns.proxy_policies, { domain: "management-proxy.test", nameservers: ["udp://127.0.0.1:1054"] }];
	const path = request(changed, current.result.revision);
	const validated = validate(path);
	check(validated.ok && sha256("/etc/config/netfleet") == config_before, `candidate_validation_zero_mutation:${sprintf("%J", validated)}`);
	const result = apply(path);
	check(result.ok && result.result.state == "applied", `network_apply_failed:${sprintf("%J", result)}`);
	const saved = get();
	check(saved.result.settings.listeners.mixed_port == 17890, "listener_readback");
	check(saved.result.settings.advanced["tcp-concurrent"] == changed.advanced["tcp-concurrent"], "advanced_configuration_readback");
	const active = read_json("/etc/opl-netfleet/native/run/config.yaml");
	check(active["tcp-concurrent"] == changed.advanced["tcp-concurrent"] && active["log-level"] == "warning" &&
		length(keys(active.sniffer.sniff)) == 1, "advanced_running_readback");
	check(active["netfleet-replace-sniff"] == null, "private_marker_not_in_core_config");
	check(cursor().get("netfleet", "mixin", "tcp_concurrent") == null, "changed_uci_override_removed");
	check(filter(saved.result.explanation, e => e.id == "tcp-concurrent")[0].source == "override", "advanced_origin_readback");
	check(saved.result.settings.listeners.credentials[0].password == null && saved.result.settings.listeners.credentials[0].password_configured,
		"password_not_returned");
	check(read_json("/etc/opl-netfleet/native/run/config.yaml").authentication[0] == "network-vm:network-vm-private", "authentication_installed");
	check(cursor().get("netfleet", "proxy", "network_vm_private") == "preserve" &&
		read_json("/etc/opl-netfleet/native/mixin.json").hosts["network-private.test"] == "203.0.113.88", "private_fields_preserved");
	check(sprintf("%J", choices()) == sprintf("%J", read_json(`${work}/initial-choices.json`)), "selectors_retained");
	check(!apply(path).ok && get().result.revision == saved.result.revision, "stale_revision_zero_mutation");
	const bad = clone(saved.result.settings);
	bad.listeners.mixed_port = 9090;
	const rejected = apply(request(bad, saved.result.revision));
	check(!rejected.ok && get().result.revision == saved.result.revision, "invalid_port_zero_mutation");
	const off = clone(saved.result.settings);
	off.lan.enabled = false;
	off.router.enabled = false;
	check(apply(request(off, saved.result.revision)).ok, "disabled_proxy_scopes_apply");
} else if (phase == "rollback") {
	const current = get().result;
	const changed = clone(current.settings);
	changed.listeners.mixed_port = 17891;
	const before = sha256("/etc/config/netfleet");
	const mixin_before = sha256("/etc/opl-netfleet/native/mixin.json");
	const result = apply(request(changed, current.revision));
	check(!result.ok && result.result?.rollback?.ok == true, `failure_rollback:${sprintf("%J", result)}`);
	check(result.error == "network_core_start_failed", "runtime_failure_reason_preserved");
	check(sha256("/etc/config/netfleet") == before && sha256("/etc/opl-netfleet/native/mixin.json") == mixin_before, "exact_private_files_restored");
	check(sprintf("%J", choices()) == sprintf("%J", read_json(`${work}/initial-choices.json`)), "rollback_selectors_retained");
} else if (phase == "restore") {
	const initial = read_json(`${work}/initial-settings.json`);
	check(initial != null, "initial_settings_missing");
	const current = get().result;
	// Fixture starts with no authentication; production passwords are never stored in this VM proof.
	check(length(initial.listeners.credentials) == 0, "fixture_authentication_assumption");
	// Anonymous UCI section IDs change with section order; restore against the current revision.
	check(length(initial.lan.rules) == length(current.settings.lan.rules), "unchanged_rule_count");
	for (let i = 0; i < length(initial.lan.rules); i++) {
		initial.lan.rules[i].id = current.settings.lan.rules[i].id;
		check(sprintf("%J", initial.lan.rules[i]) == sprintf("%J", current.settings.lan.rules[i]), "unchanged_rule_content");
	}
	const result = apply(request(initial, current.revision));
	check(result.ok, `restore_original_network_settings:${sprintf("%J", result)}`);
} else die("unknown_phase");
print(`network_device ${phase} passed\n`);

host.release();
