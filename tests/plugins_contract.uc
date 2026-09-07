import { valid_id, descriptor_error, action_access } from "../openwrt/files/usr/libexec/opl-netfleet/kernel/schema.uc";
function check(value, message) { if (!value) die(message); };
const manifest = { schema: "opl-netfleet-plugin.v1", id: "test-plugin", label: "Test plugin", version: "1.0.0", api_version: 1,
	package: "opl-netfleet-plugin-test-plugin", dependencies: [], backends: ["native-mihomo"], permissions: ["diagnostics"], actions: { inspect: "read", reset: "write" } };
check(descriptor_error(manifest, manifest.id) == null, "valid descriptor accepted");
for (let id in ["../test", "test/child", "test;id", "-test"])
	check(!valid_id(id), "unsafe ID rejected");
check(descriptor_error({ ...manifest, entry: "/bin/sh" }, manifest.id) != null, "manifest cannot choose executable path");
check(descriptor_error({ ...manifest, actions: { load: "read" } }, manifest.id) != null, "lifecycle cannot become read RPC");
check(descriptor_error({ ...manifest, dependencies: ["curl;id"] }, manifest.id) != null, "dependency shell injection rejected");
check(descriptor_error({ ...manifest, api_version: 2 }, manifest.id) == null, "future API retains diagnostic identity");
check(action_access(manifest, "get") == "read" && action_access(manifest, "load") == "write", "fixed lifecycle access");
check(action_access(manifest, "inspect") == "read" && action_access(manifest, "reset") == "write", "custom action access");
check(action_access(manifest, "unknown") == null, "undeclared action unavailable");
print("plugins_contract_ok\n");
