import * as fs from "fs";

// Run only in the disposable native qualification guest, with its real core.
if (fs.stat("/tmp/netfleet-native-vm-authorized") == null) die("isolated native VM required");
const work = "/tmp/netfleet-native-fixture";
const main = "/usr/libexec/opl-netfleet/main.uc";
const source = "/etc/opl-netfleet/native/profiles/fixture.json";
const original = fs.readfile(source);
function check(value, message) { if (!value) die(message); }
function call(action, request) {
	if (request != null) fs.writefile(`${work}/configuration-request.json`, sprintf("%J", { request }));
	const child = fs.popen(`flock /var/lock/opl-netfleet-deploy.lock ucode ${main} ${action}${request == null ? "" : " " + work + "/configuration-request.json"}`);
	const value = json(child.read("all")); child.close();
	if (action == "config-apply") print(sprintf("%J\n", value));
	return value;
}
function request() {
	const config = call("config-get").result;
	const value = { revision: config.revision, policy_source: { kind: config.policy_source.kind, ref: config.policy_source.ref },
		recovery_profile_ref: config.recovery_profile.ref, providers: {}, regions: {}, capabilities: {},
		routing_rules: config.routing_rules, automation: config.automation, safety: config.safety };
	for (let provider in config.providers) value.providers[provider.id] = { section: provider.section,
		enabled: provider.enabled, role: provider.role, billing: provider.billing, region_ids: provider.region_ids };
	for (let region in config.regions) value.regions[region.id] = { display_name: region.display_name, mode: region.mode };
	for (let capability in config.capabilities) value.capabilities[capability.id] = { display_name: capability.display_name,
		enabled: capability.enabled, mode: capability.mode, region_ids: capability.region_ids,
		prefer_region_from: capability.prefer_region_from, entry_group: capability.entry_group, policy_groups: capability.policy_groups };
	value.automation.selection_interval_seconds++;
	return value;
}
function pid() {
	const child = fs.popen("pidof mihomo"); const value = trim(child.read("all")); child.close(); return value;
}
const unhealthy_native = json(original);
unhealthy_native["proxy-groups"][0].proxies = ["REJECT"];
fs.writefile(source, sprintf("%J", unhealthy_native));
// The compiler replaces this entry with the working provider path. The native
// Recovery Profile itself rejects every request and cannot pass enable probes.
const applied = call("config-apply", request());
check(applied.ok && applied.result.config.active && call("probe").ok,
	"active apply must not detour through an unhealthy native profile");
const policy_before = fs.readfile("/etc/opl-netfleet/policy.json");
const healthy_source = fs.readfile(source);
const before_pid = pid();
const invalid = json(healthy_source);
push(invalid["proxy-groups"], { name: "Unused invalid fixture", type: "select", proxies: ["missing-fixture-member"] });
fs.writefile(source, sprintf("%J", invalid));
const compile_failure = call("config-apply", request());
check(!compile_failure.ok && compile_failure.detail?.rollback?.state == "active_restored" &&
	pid() == before_pid && fs.readfile("/etc/opl-netfleet/policy.json") == policy_before && call("probe").ok,
	"compile failure must preserve the old live core and policy");
const blocked = json(healthy_source);
blocked.rules = ["MATCH,REJECT"];
fs.writefile(source, sprintf("%J", blocked));
const activation_failure = call("config-apply", request());
check(!activation_failure.ok && activation_failure.error == "protected_probe_failed" &&
	activation_failure.detail?.rollback?.state == "active_restored" &&
	fs.readfile("/etc/opl-netfleet/policy.json") == policy_before && call("probe").ok,
	"post-switch probe failure must restore the old active runtime without native enable");
fs.writefile(source, healthy_source);
check(call("status").result.active && !call("config-get").result.pending_apply,
	"rollback must restore the exact accepted artifact");
fs.writefile(source, original);
check(call("config-apply", request()).ok, "restore the original fixture through the configuration owner");
print("configuration_apply_device_ok\n");
