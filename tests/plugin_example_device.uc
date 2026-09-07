import * as fs from "fs";
import { shell_quote as q } from "/usr/libexec/opl-netfleet/adapters/uci.uc";
function check(value, message) { if (!value) die(message); };
check(fs.stat("/tmp/netfleet-native-vm-authorized") != null, "isolated VM authorization required");
const root = "/usr/libexec/opl-netfleet/plugins/device-info";
check(fs.lstat(root) == null && fs.mkdir(root, 0755), "example installation is isolated");
for (let name in ["manifest.json", "control", "LICENSE"]) {
	check(fs.writefile(`${root}/${name}`, fs.readfile(`/tmp/examples/plugins/device-info/${name}`)), "copy actual example");
	fs.chmod(`${root}/${name}`, name == "control" ? 0755 : 0644);
}
const request = "/tmp/netfleet-plugin-example-request.json";
const rpc = "/tmp/openwrt/files/usr/libexec/rpcd/opl-netfleet";
function call(method, action, revision) {
	fs.writefile(request, sprintf("%J", { request: { id: "device-info", action: action, revision: revision, confirm: true } }));
	fs.chmod(request, 0600);
	const process = fs.popen(`sh ${q(rpc)} call ${q(method)} <${q(request)}`);
	const result = json(process.read("all"));
	check(process.close() == 0, "real RPC transport succeeds");
	return result;
};
const listing = call("plugins_list");
const plugin = filter(listing.result.plugins, item => item.id == "device-info")[0];
check(plugin?.revision != null, "real RPC discovers example");
check(call("plugin_read", "load", plugin.revision).error == "plugin_action_not_allowed", "read RPC cannot mutate");
check(call("plugin_call", "load", plugin.revision).result.ready, "example loads through real RPC");
const inspected = call("plugin_read", "inspect");
check(inspected.ok && inspected.result.uptime_seconds > 0 && inspected.result.release.distribution == "OpenWrt", "example reads actual device via ubus");
check(call("plugin_call", "reload", plugin.revision).result.loaded, "example reloads through real RPC");
check(call("plugin_call", "unload", plugin.revision).result.loaded == false, "example exit readback");
for (let name in ["manifest.json", "control", "LICENSE"]) fs.unlink(`${root}/${name}`);
fs.rmdir(root); fs.unlink(request);
print("plugin_example_device_ok\n");
