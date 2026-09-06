import { BACKUP_FORMAT, profile_id, file_path, profile_referenced, validate_backup, redact_line } from "../openwrt/files/usr/libexec/opl-netfleet/core/maintenance.uc";

function check(value, label) { if (!value) die(label); };
for (let name in ["primary.json", "local-profile.yaml", "recovery.yml"]) check(profile_id(name), "accept local stable profile ID");
for (let name in ["../shadow.json", "/etc/config/netfleet", "nested/file.json", "OPL-NetFleet.json", "a..json", ".json", "x.txt"])
	check(!profile_id(name), "reject unsafe and generated profile IDs");
for (let path in ["native/profiles/local.json", "native/subscriptions/Provider_1.yaml", "native/mixin.json", "policy-sources/base-v1.json", "native/run/providers/rule/local.yaml", "native/certs/ca.pem"])
	check(file_path(path), "accept declaration input path");
for (let path in ["/etc/shadow", "native/../backend.json", "native/run/config.yaml", "native/run/cache.db", "native/profiles/OPL-NetFleet.json", "native/profiles/opl-netfleet/mvp.json", "native/run/providers/proxy/netfleet-private.yaml", "native/run/controller.sock", "native/providers//x"])
	check(!file_path(path), "reject arbitrary paths and generated runtime state");
check(profile_referenced("local.json", { recovery_profile: { ref: "file:local.json" } }, null), "recovery profile protected");
check(profile_referenced("local.json", { policy_source: { ref: "file:local.json" } }, null), "policy source protected");
check(profile_referenced("local.json", {}, "file:local.json"), "selected profile protected");
check(!profile_referenced("other.json", {}, "file:local.json"), "unused profile editable");

const example = {
	format: BACKUP_FORMAT, created_at: 1,
	policy: { policy_source: { kind: "bundle", ref: "bundle:base-v1" }, recovery_profile: { ref: "subscription:Provider_1" }, providers: { a: { section: "Provider_1" } } },
	sections: [
		{ name: "config", type: "config", options: { profile: "file:OPL-NetFleet.json", enabled: "1" } },
		{ name: "mixin", type: "mixin", options: { api_secret: "private", tun_enabled: "0" } },
		{ name: "proxy", type: "proxy", options: { tcp_mode: "tproxy", udp_mode: "tproxy" } },
		{ name: "Provider_1", type: "subscription", options: { url: "https://example.test/?token=private" } }
	],
	files: [
		{ path: "policy-sources/base-v1.json", encoding: "base64", content: b64enc("{}") },
		{ path: "native/subscriptions/Provider_1.yaml", encoding: "base64", content: b64enc("{\"proxies\":[]}") }
	]
};
check(validate_backup(example).ok, "complete backup accepted");
function copy(value) { return json(sprintf("%J", value)); };
let changed = copy(example);
changed.files[0].path = "native/run/config.yaml";
check(!validate_backup(changed).ok, "runtime config rejected before restore");
changed = copy(example);
changed.files[0].content = "====";
check(!validate_backup(changed).ok, "malformed base64 rejected");
changed = copy(example);
push(changed.files, changed.files[0]);
check(!validate_backup(changed).ok, "duplicate destination rejected");
changed = copy(example);
pop(changed.files);
check(!validate_backup(changed).ok, "referenced cache required");
changed = copy(example);
changed.sections[0].options.run = { command: "invalid" };
check(!validate_backup(changed).ok, "structured UCI options rejected");
changed = copy(example);
changed.sections[2].options.tcp_mode = "redirect";
check(!validate_backup(changed).ok, "unsupported network mode rejected");
check(index(redact_line("fatal token=private123 endpoint=https://example.test/?token=private123 secret=credential", ["credential"]), "private123") < 0,
	"log tokens and URLs redacted");
check(redact_line("listener unavailable", []) == "listener unavailable", "ordinary startup failure retained");
check(length(redact_line(join("", map([1,2,3], value => sprintf("%2000s", "x"))), [])) == 1024, "diagnostic line bounded");
print("maintenance_contract_ok\n");
