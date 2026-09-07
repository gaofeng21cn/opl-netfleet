import * as fs from "fs";
import * as plugins from "/usr/libexec/opl-netfleet/application/plugins.uc";

function check(value, message) { if (!value) die(message); };
check(fs.stat("/tmp/netfleet-native-vm-authorized") != null, "isolated VM authorization required");
const root = "/usr/libexec/opl-netfleet/plugins", id = "vm-test", directory = `${root}/${id}`;
const request = "/tmp/netfleet-plugin-test-request.json", state = "/tmp/netfleet-plugin-test-loaded";
check(fs.lstat(directory) == null, "fixture must not replace existing plugin");
if (fs.lstat(root) == null) check(fs.mkdir(root, 0755), "plugin root created");
check(fs.mkdir(directory, 0755), "plugin installed without core restart");
const manifest = { schema: "opl-netfleet-plugin.v1", id: id, label: "VM plugin", version: "1.0.0", api_version: 1,
	package: `opl-netfleet-plugin-${id}`, dependencies: [], backends: ["native-mihomo", "nikki-mihomo"], permissions: ["diagnostics"], actions: { inspect: "read", reset: "write" } };
function publish(version, behavior) {
	manifest.version = version;
	fs.writefile(`${directory}/manifest.json`, sprintf("%J", manifest));
	fs.chmod(`${directory}/manifest.json`, 0644);
	fs.writefile(`${directory}/control`, '#!/usr/bin/ucode\nimport * as fs from "fs";\n' +
		`const state = "${state}"; const action = ARGV[0];\n` +
		'if (action == "load") fs.writefile(state, "loaded");\n' +
		'if (action == "unload") fs.unlink(state);\n' +
		(behavior ?? '') +
		`printf("%J\\n", {ok:true,result:{loaded:fs.stat(state)!=null,ready:true,version:"${version}"}});\n`);
	fs.chmod(`${directory}/control`, 0755);
};
function call(action, access, revision) {
	const row = filter(plugins.inventory(null), item => item.id == id)[0];
	fs.writefile(request, sprintf("%J", { request: { id: id, action: action, revision: revision ?? row.revision, confirm: true } }));
	fs.chmod(request, 0600);
	return plugins.dispatch(access ?? (action == "get" || action == "inspect" ? "plugin-read" : "plugin-call"), request);
};
publish("1.0.0");
check(filter(plugins.inventory(null), item => item.id == id)[0].version == "1.0.0", "new plugin discovered without import/restart");
check(!call("get").result.loaded, "install does not load");
check(call("inspect").error == "plugin_not_loaded", "custom code unavailable until loaded");
check(call("load", "plugin-read").error == "plugin_action_not_allowed", "read RPC cannot load");
check(call("load").result.loaded, "load verified through plugin owner");
check(call("inspect").result.version == "1.0.0", "custom action reaches process");
const old = plugins.inventory(null)[0].revision;
check(call("unload").result.loaded == false, "unload drains before replacement");
publish("1.1.0");
check(call("load", null, old).error == "plugin_confirmation_or_revision_required", "stale request rejected after update");
check(call("load").result.version == "1.1.0", "updated bytes loaded by same host process");
check(call("reload").result.loaded, "reload completes unload/load/readback");
const lock = fs.open("/var/lock/opl-netfleet-deploy.lock", "a");
check(lock.lock("xn"), "take real owner lock");
check(call("unload").error == "mutation_busy", "plugin writes serialize with core owner");
lock.close();
const maintenance = "/var/run/opl-netfleet-plugin-maintenance";
if (fs.lstat(maintenance) == null) fs.mkdir(maintenance, 0700);
fs.mkdir(`${maintenance}/${id}`, 0700);
check(call("reload").error == "plugin_package_maintenance", "package drain excludes new load");
check(call("unload").result.loaded == false, "maintenance keeps exit available");
fs.rmdir(`${maintenance}/${id}`);
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
check(!length(filter(plugins.inventory(null), item => item.id == id)), "uninstalled plugin disappears without restart");
fs.unlink(request); fs.unlink(state);
print("plugins_device_ok\n");
