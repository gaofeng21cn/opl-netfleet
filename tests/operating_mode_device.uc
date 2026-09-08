import * as fs from "fs";

if (fs.stat("/tmp/netfleet-native-vm-authorized") == null) die("isolated native VM required");
const main = "/usr/libexec/opl-netfleet/main.uc";
const request_path = "/tmp/netfleet-native-fixture/mode-request.json";
function check(value, label) { if (!value) die(label); }
function call(action, request) {
	if (request != null) {
		fs.writefile(request_path, sprintf("%J", { request }));
		fs.chmod(request_path, 0600);
	}
	const child = fs.popen(`ucode ${main} ${action}${request == null ? "" : " " + request_path}`);
	const raw = child.read("all");
	const rc = child.close();
	const result = json(raw);
	check(rc == 0 || result?.ok == false, "mode owner response missing");
	return result;
}
const inventory = call("plugins-list").result.plugins;
const plugin = filter(inventory, row => row.id == "activation" && row.instance == "default")[0];
check(plugin?.revision != null, "activation revision missing");
function get() { return call("plugin-read", { id: "activation", action: "get-mode" }).result; }
function change(mode) {
	const before = get();
	const result = call("plugin-call", { id: "activation", instance: "default", action: "set-mode",
		revision: plugin.revision, confirm: true, params: { mode, expected_mode: before.mode } });
	check(result.ok && result.result.mode == mode, `mode transition failed: ${mode}: ${result.error}`);
	check(call("status").result.operating_mode == mode, "status and mode owner disagree");
	return result;
}
function core_pid() {
	const child = fs.popen("ubus call service list '{\"name\":\"opl-netfleet-core\"}'");
	const value = json(child.read("all")); child.close();
	return value?.["opl-netfleet-core"]?.instances?.core?.pid;
}
for (let mode in ["mihomo", "netfleet", "mihomo", "openwrt", "netfleet", "openwrt", "mihomo"]) {
	change(mode);
	const pid = core_pid();
	const repeated = change(mode);
	check(repeated.result.unchanged && core_pid() == pid, "unchanged mode restarted core");
	if (mode == "openwrt") check(get().cleanup.ok && !get().supervisor.enabled, "direct cleanup or persistence missing");
}
const pid = core_pid();
const stale = call("plugin-call", { id: "activation", action: "set-mode", revision: plugin.revision, confirm: true,
	params: { mode: "openwrt", expected_mode: "netfleet" } });
check(!stale.ok && stale.error == "runtime_mode_changed" && core_pid() == pid, "stale switch mutated core");
fs.unlink(request_path);
print("operating_mode_device_ok\n");
