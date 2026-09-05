import * as fs from "fs";

// Only the disposable ARM64 OpenWrt experiment invokes this test.
if (fs.stat("/tmp/netfleet-native-vm-authorized") == null) die("disposable VM required");
const work = "/tmp/netfleet-native-fixture";
const input = `${work}/sources.json`;
const base = "/etc/opl-netfleet/native";
const cache_path = `${base}/cache/fixture.json`;
const initial = json(fs.readfile(input));
const original = json(fs.readfile(cache_path));
function check(value, label) { if (!value) die(label); };
function call(action, argument, expected) {
	const process = fs.popen(`ucode /usr/libexec/opl-netfleet/main.uc ${action} ${argument ?? ""}`);
	const output = process.read("all");
	const rc = process.close();
	check(index(output, "vm-only-credential") < 0, "credential in output");
	const result = json(output);
	check(result.ok == expected && (expected ? rc == 0 : rc != 0), `unexpected ${action} result: ${result.error}`);
	return result;
};
function save(config) {
	fs.writefile(input, sprintf("%J", config));
	return call("native-sources-set", input, true).result;
};
function retained() {
	const cache = json(fs.readfile(cache_path));
	check(cache.content_sha256 == original.content_sha256 && cache.source_sha256 == original.source_sha256 &&
		cache.last_success == original.last_success && sprintf("%J", cache.proxies) == sprintf("%J", original.proxies),
		"failed download destroyed accepted cache");
};

const stable = initial.sources[0];
for (let endpoint in ["invalid", "empty", "bad-node", "missing", "redirect"]) {
	const source = { ...stable, url: replace(stable.url, "/valid?", `/${endpoint}?`) };
	const before = save({ schema_version: 1, sources: [source] }).sources[0];
	check(!before.ready && before.last_success == null && before.previous_cache_retained, "changed source inherited success");
	const failed = call("native-sources-refresh", "fixture", false);
	check(failed.error == "source_refresh_failed" && failed.detail.failed_count == 1 &&
		failed.detail.sources[0].last_result == "failed", `negative case ${endpoint}`);
	retained();
}

// A failed source must not prevent another source from being accepted.
const mixed = { schema_version: 1, sources: [
	{ ...stable, url: replace(stable.url, "/valid?", "/missing?") },
	{ ...stable, id: "second" }
] };
save(mixed);
const partial = call("native-sources-refresh", null, false).detail;
check(partial.failed_count == 1 && partial.sources[1].ready && partial.sources[1].last_result == "updated", "partial refresh");
retained();

const renamed = save({ schema_version: 1, sources: [{ ...stable, display_name: "Renamed", enabled: false }] }).sources[0];
check(!renamed.ready && renamed.cache_present && renamed.last_success == original.last_success, "rename/disable identity");
check(fs.stat(`${base}/cache/second.json`) == null, "removed source cache");
check(call("native-sources-refresh", "fixture", false).error == "enabled_source_not_found", "disabled explicit refresh");
save(initial);

const before_lock = fs.readfile(cache_path);
const lock = fs.open("/var/lock/opl-netfleet-deploy.lock", "a", 0600);
check(lock.lock("xn"), "acquire shared lock");
check(call("native-sources-refresh", "fixture", false).error == "mutation_busy", "busy refresh");
check(call("native-sources-set", input, false).error == "mutation_busy", "busy save");
check(fs.readfile(cache_path) == before_lock, "busy mutated cache");
lock.close();
const after = call("native-sources-refresh", "fixture", true).result.sources[0];
check(after.ready && after.last_result == "unchanged" && after.last_changed == original.last_changed, "unchanged after failed attempts");

fs.chmod(`${base}/cache`, 0755);
check(call("native-sources-get", null, false).error == "unsafe_cache_directory", "unsafe cache directory accepted");
fs.chmod(`${base}/cache`, 0700);
check(fs.stat("/etc/nikki") == null && fs.stat("/etc/config/nikki") == null && fs.stat("/etc/init.d/nikki") == null,
	"Nikki state created");
for (let name in fs.lsdir("/tmp")) check(index(name, "opl-netfleet-native.") != 0, "scratch leaked");
check(index(fs.readfile(cache_path), "vm-only-credential") < 0, "credential in cache");
print("native_sources_integration_ok\n");
