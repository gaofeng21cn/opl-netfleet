import * as fs from "fs";
import * as extensions from "/usr/libexec/opl-netfleet/application/extensions.uc";
import * as compatibility from "/usr/libexec/opl-netfleet/application/compatibility.uc";
import * as dashboard from "/usr/libexec/opl-netfleet/application/dashboard.uc";
import { descriptor_error } from "/usr/libexec/opl-netfleet/core/extensions.uc";

function check(value, message) { if (!value) die(message); };
const rpc_path = ARGV[0] ?? "/usr/libexec/rpcd/opl-netfleet";
const acl_path = ARGV[1] ?? "/usr/share/rpcd/acl.d/luci-app-netfleet.json";
const rpc = fs.popen(`sh '${rpc_path}' list`);
const methods = json(rpc.read("all"));
check(rpc.close() == 0, "real RPC list succeeds");
const acl = json(fs.readfile(acl_path));
for (let definition in [compatibility.extension, dashboard.extension]) {
	check(descriptor_error(definition) == null, "shipped module descriptor validates");
	for (let command, entry in definition.commands) {
		const method = replace(command, "-", "_");
		check(methods[method] != null, "declared command exists in real RPC list");
		let permitted = false;
		for (let key, group in acl) if (index(group?.[entry.access]?.ubus?.["opl-netfleet"] ?? [], method) >= 0) permitted = true;
		check(permitted, "declared access matches installed RPC ACL");
	}
}
const rows = extensions.inventory({}, { zashboard: { available: true, installed_version: "v1.0.0" } });
check(length(rows) == 2 && rows[1].installed_version == "v1.0.0", "inventory reuses resource owner projection");
check(extensions.dispatch("compatibility-private-backup") == null && extensions.dispatch("compatibility-tick") == null,
	"private operations not exposed by registry");
check(compatibility.dispatch("run").error == "extension_action_not_allowed", "adapter cannot bypass allowlist");
check(dashboard.dispatch("unknown").error == "extension_action_not_allowed", "resource adapter rejects unknown method");
if (!compatibility.inspection().available) {
	check(extensions.dispatch("compatibility-get").result.installed == false, "absent optional component readable through real registry");
	check(extensions.dispatch("compatibility-enable", "/unused").ok == false, "absent optional component cannot activate");
}
check(extensions.dispatch("dashboard-get").ok == true, "resource caller reaches existing owner");
print("extensions_device_ok\n");
