import * as fs from "fs";
import { create } from "/usr/libexec/opl-netfleet/kernel/host.uc";
import { create as create_adapter } from "/usr/libexec/opl-netfleet/adapters/openwrt.uc";
const baseline = create("/usr/libexec/opl-netfleet", { adapter: create_adapter() });
const system = baseline.system;
baseline.release();
const host = create("/usr/libexec/opl-netfleet", { adapter: create_adapter(), system });
const dashboard = host.use("dashboard.control");
const descriptor_error = host.use("models.extensions").descriptor_error;

function check(value, message) { if (!value) die(message); };
function dispatch(command, envelope) {
	const entry = host.command(command);
	return entry == null ? null : host.call(entry.service, entry.method, [command, envelope]);
};
const rpc_path = ARGV[0] ?? "/usr/libexec/rpcd/opl-netfleet";
const acl_path = ARGV[1] ?? "/usr/share/rpcd/acl.d/luci-app-netfleet.json";
const rpc = fs.popen(`sh '${rpc_path}' list`);
const methods = json(rpc.read("all"));
check(rpc.close() == 0, "real RPC list succeeds");
const acl = json(fs.readfile(acl_path));
for (let definition in [dashboard.extension]) {
	check(descriptor_error(definition) == null, "shipped module descriptor validates");
	for (let command, entry in definition.commands) {
		check(host.command(command) != null, "adapter command registered by installed service manifest");
		const method = replace(command, "-", "_");
		check(methods[method] != null, "declared command exists in real RPC list");
		let permitted = false;
		for (let key, group in acl) if (index(group?.[entry.access]?.ubus?.["opl-netfleet"] ?? [], method) >= 0) permitted = true;
		check(permitted, "declared access matches installed RPC ACL");
	}
}
const rows = host.inventory(null);
for (let id, enabled in host.system.enabled) if (enabled)
	check(length(filter(rows, row => row.id == id && row.runtime == "service")) == 1, "configured service plugin appears once in inventory");
const components = host.use("components.control").get();
check(components.dashboard.installed_version == dashboard.resource().installed_version, "components reuses resource owner version");
check(dashboard.dispatch("unknown").error == "extension_action_not_allowed", "resource adapter rejects unknown method");
check(dispatch("dashboard-get").ok == true, "resource caller reaches existing owner");
host.release();
print("extensions_device_ok\n");
