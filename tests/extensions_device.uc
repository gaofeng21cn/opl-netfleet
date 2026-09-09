import * as fs from "fs";
import { create } from "/usr/libexec/opl-netfleet/kernel/host.uc";
import { create as create_adapter } from "/usr/libexec/opl-netfleet/adapters/openwrt.uc";
const baseline = create("/usr/libexec/opl-netfleet", { adapter: create_adapter() });
const system = baseline.system;
baseline.release();
// This contract explicitly exercises the installed optional management plugin.
// Keep the production default disabled and enable only this in-memory host.
const compatibility_installed = fs.lstat('/usr/libexec/opl-netfleet/plugins/https-compat/manifest.json') != null;
system.enabled['https-compat'] = compatibility_installed;
const host = create("/usr/libexec/opl-netfleet", { adapter: create_adapter(), system });
const compatibility = compatibility_installed ? host.use("https-compat.control") : null;
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
for (let definition in compatibility_installed ? [compatibility.extension, dashboard.extension] : [dashboard.extension]) {
	check(descriptor_error(definition) == null, "shipped module descriptor validates");
	for (let command, entry in definition.commands) {
		check(host.command(command) != null, "adapter command registered by installed service manifest");
		const method = replace(command, "-", "_");
		if (definition.id == 'https-compat') {
			check(methods[method] == null, "HTTPS CLI commands do not add host-specific RPC methods");
			continue;
		}
		check(methods[method] != null, "declared command exists in real RPC list");
		let permitted = false;
		for (let key, group in acl) if (index(group?.[entry.access]?.ubus?.["opl-netfleet"] ?? [], method) >= 0) permitted = true;
		check(permitted, "declared access matches installed RPC ACL");
	}
}
if (compatibility_installed) {
const manifest = host.found['https-compat'].manifest;
const plugin_rpc = fs.popen(`sh '${rpc_path}.plugins' list`);
const plugin_methods = json(plugin_rpc.read('all'));
check(plugin_rpc.close() == 0, 'real generic plugin RPC list succeeds');
for (let action in ['config-get', 'config-set', 'enable', 'disable', 'probe', 'public-ca']) {
	const entry = manifest.actions[action];
	check(entry != null && entry.lock == 'plugin', "HTTPS action belongs to its plugin");
	const method = entry.access == 'read' ? 'plugin_read' : 'plugin_call';
	check(plugin_methods[method] != null, "HTTPS uses the real generic plugin RPC");
	let permitted = false;
	for (let key, group in acl) if (index(group?.[entry.access]?.ubus?.['opl-netfleet.plugins'] ?? [], method) >= 0) permitted = true;
	check(permitted, "generic plugin action access matches installed ACL");
}
}
const rows = host.inventory(null);
for (let id, enabled in host.system.enabled) if (enabled)
	check(length(filter(rows, row => row.id == id && row.runtime == "service")) == 1, "configured service plugin appears once in inventory");
const components = host.use("components.control").get();
check(components.dashboard.installed_version == dashboard.resource().installed_version, "components reuses resource owner version");
check(dispatch("compatibility-private-backup") == null && dispatch("compatibility-tick") == null,
	"private operations not exposed by registry");
if (compatibility_installed)
	check(compatibility.dispatch("run").error == "extension_action_not_allowed", "adapter cannot bypass allowlist");
check(dashboard.dispatch("unknown").error == "extension_action_not_allowed", "resource adapter rejects unknown method");
if (compatibility_installed && !compatibility.inspection().available) {
	check(dispatch("compatibility-get").result.installed == false, "absent optional component readable through real registry");
	check(dispatch("compatibility-enable", "/unused").ok == false, "absent optional component cannot activate");
}
check(dispatch("dashboard-get").ok == true, "resource caller reaches existing owner");
host.release();
print("extensions_device_ok\n");
