import * as fs from "fs";
import { create } from "/usr/libexec/opl-netfleet/kernel/host.uc";
import { create as create_adapter } from "/usr/libexec/opl-netfleet/adapters/openwrt.uc";

function check(value, message) { if (!value) die(message); };
check(fs.stat("/tmp/netfleet-native-vm-authorized") != null, "isolated VM authorization required");
const root = "/usr/libexec/opl-netfleet/plugins", id = "vm-test", directory = `${root}/${id}`;
const request = "/tmp/netfleet-plugin-test-request.json", state = "/tmp/netfleet-plugin-test-loaded";
function inventory() {
	const host = create("/usr/libexec/opl-netfleet", { adapter: create_adapter() });
	const rows = host.inventory(null);
	host.release();
	return rows;
};
check(fs.lstat(directory) == null, "fixture must not replace existing plugin");
if (fs.lstat(root) == null) check(fs.mkdir(root, 0755), "plugin root created");
check(fs.mkdir(directory, 0755), "plugin installed without core restart");
const manifest = { schema: "opl-netfleet-plugin.v1", id: id, label: "VM plugin", version: "1.0.0", api_version: 1,
	package: `opl-netfleet-plugin-${id}`, dependencies: [], backends: ["native-mihomo", "nikki-mihomo"], permissions: ["diagnostics"], actions: { inspect: "read", reset: "write" } };
function publish(version, behavior) {
	manifest.version = version;
	// Package updates replace files atomically, invalidating metadata-based inspection caches.
	fs.writefile(`${directory}/manifest.json.next`, sprintf("%J", manifest));
	fs.chmod(`${directory}/manifest.json.next`, 0644);
	check(fs.rename(`${directory}/manifest.json.next`, `${directory}/manifest.json`), "replace manifest");
	fs.writefile(`${directory}/control.next`, '#!/usr/bin/ucode\nimport * as fs from "fs";\n' +
		`const state = "${state}"; const action = ARGV[0];\n` +
		'if (action == "load") fs.writefile(state, "loaded");\n' +
		'if (action == "unload") fs.unlink(state);\n' +
		(behavior ?? '') +
		`printf("%J\\n", {ok:true,result:{loaded:fs.stat(state)!=null,ready:true,version:"${version}"}});\n`);
	fs.chmod(`${directory}/control.next`, 0755);
	check(fs.rename(`${directory}/control.next`, `${directory}/control`), "replace control");
};
function call(action, access, revision) {
	const row = filter(inventory(), item => item.id == id)[0];
	fs.writefile(request, sprintf("%J", { request: { id: id, action: action, revision: revision ?? row.revision, confirm: true } }));
	fs.chmod(request, 0600);
	const command = access ?? (action == "get" || action == "inspect" ? "plugin-read" : "plugin-call");
	const pipe = fs.popen(`ucode /usr/libexec/opl-netfleet/main.uc ${command} ${request}`);
	const result = json(pipe.read("all"));
	const status = pipe.close();
	check((status == 0) == (result.ok == true), "plugin result matches CLI exit status");
	return result;
};
publish("1.0.0");
check(filter(inventory(), item => item.id == id)[0].version == "1.0.0", "new plugin discovered without import/restart");
check(!call("get").result.loaded, "install does not load");
check(call("inspect").error == "plugin_not_loaded", "custom code unavailable until loaded");
check(call("load", "plugin-read").error == "plugin_action_not_allowed", "read RPC cannot load");
check(call("load").result.loaded, "load verified through plugin owner");
check(call("inspect").result.version == "1.0.0", "custom action reaches process");
const old = filter(inventory(), item => item.id == id)[0].revision;
check(call("unload").result.loaded == false, "unload drains before replacement");
publish("1.1.0");
check(call("load", null, old).error == "plugin_confirmation_or_revision_required", "stale request rejected after update");
check(call("load").result.version == "1.1.0", "updated bytes loaded by same host process");
check(call("reload").result.loaded, "reload completes unload/load/readback");
const lock = fs.popen("flock -n /var/lock/opl-netfleet-deploy.lock sh -c 'printf \"locked\\n\"; sleep 2'");
check(trim(lock.read("line")) == "locked", "independent process takes real owner lock");
check(call("unload").error == "mutation_busy", "plugin writes serialize with core owner");
lock.close();
const maintenance = "/var/run/opl-netfleet-plugin-maintenance";
if (fs.lstat(maintenance) == null) fs.mkdir(maintenance, 0700);
fs.mkdir(`${maintenance}/${id}`, 0700);
check(call("reload").error == "plugin_package_maintenance", "package drain excludes new load");
check(call("unload").error == "plugin_package_maintenance", "package maintenance excludes public plugin execution");
check(call("unload", "plugin-drain").result.state == "replacing", "drain transitions to replacement while locked");
check(call("get").error == "plugin_package_maintenance" && call("unload").error == "plugin_package_maintenance", "no plugin execution during package byte replacement");
check(call("unload", "plugin-drain").ok, "package drain retry remains idempotent");
fs.unlink(`${maintenance}/${id}/replacing`);
fs.rmdir(`${maintenance}/${id}`);
publish("1.1.1", 'if (action == "load") system("sleep 3 >/dev/null 2>&1 &");\n');
check(call("load").ok, "plugin may spawn an independent helper");
const unlocked = fs.open("/var/lock/opl-netfleet-deploy.lock", "ae");
check(unlocked.lock("xn"), "live helper does not inherit owner lock");
unlocked.close();
check(call("unload").ok, "helper plugin exits");
publish("1.1.2", 'if (action == "load") fs.writefile("/tmp/netfleet-plugin-large-state", sprintf("%0200000d", 1));\n');
check(call("load").ok && fs.stat("/tmp/netfleet-plugin-large-state").size > 131072, "response cap does not limit plugin state writes");
fs.unlink("/tmp/netfleet-plugin-large-state");
check(call("unload").ok, "large state plugin exits");
publish("1.1.3", 'if (action == "inspect") { print(sprintf("%070000d", 1)); exit(0); }\n');
check(call("load").ok && call("inspect").error == "plugin_response_invalid", "oversized response rejected without unbounded capture");
check(call("unload").ok, "exit remains available after oversized response");
publish("1.2.0", 'if (action == "load") { print("{\\"ok\\":false}"); exit(1); }\n');
check(call("load").error == "plugin_load_failed_rolled_back" && !call("get").result.loaded, "partial load rollback verified");
publish("1.3.0", 'if (action == "inspect") { print("invalid response"); exit(0); }\n');
check(call("load").ok, "load valid plugin");
check(call("inspect").error == "plugin_response_invalid", "bad JSON isolated");
check(call("unload").ok, "exit remains available after custom action fails");
manifest.api_version = 2; publish("2.0.0");
check(call("load").error == "plugin_api_incompatible", "unknown major blocks load");
check(call("get").ok && call("unload").ok, "stable diagnostics and exit survive API drift");
fs.chmod(`${directory}/control`, 0777);
check(call("get").error == "plugin_files_unsafe", "writable plugin is not executed");
fs.unlink(`${directory}/control`); fs.unlink(`${directory}/manifest.json`); fs.rmdir(directory);
check(!length(filter(inventory(), item => item.id == id)), "uninstalled plugin disappears without restart");
fs.unlink(request); fs.unlink(state);
print("plugins_device_ok\n");
