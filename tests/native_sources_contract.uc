import { valid_id, validate, project } from "../openwrt/files/usr/libexec/opl-netfleet/core/native_sources.uc";

function check(value, label) { if (!value) die(label); };
const source = { id: "alpha", display_name: "Test source", enabled: true, url: "https://example.test/sub?key=private" };
function checked(patch) {
	return validate({ schema_version: 1, sources: [{ ...source, ...patch }] });
};
check(checked({}).ok, "valid source");
check(checked({ url: "https://example.test?key=value" }).ok, "root query");
for (let id in ["../alpha", "a/b", "", "UPPER", "a.b"]) check(!valid_id(id), "invalid id");
for (let url in ["http://example.test/sub", "https://user@example.test/sub", "https://example.test/#fragment", "https://example.test/a b", "https://example.test/a\n", "https://example.test/a\u0000b"])
	check(!checked({ url: url }).ok, "invalid URL");
check(!checked({ user_agent: "agent\r\nheader" }).ok, "header injection");
check(!checked({ display_name: "name\u0000hidden" }).ok, "NUL in name");
check(!checked({ enabled: "true" }).ok, "boolean required");
check(!checked({ extra: true }).ok, "unknown field");
check(!validate({ schema_version: 1, sources: [source, source] }).ok, "duplicate id");
const cache = {
	schema_version: 1, source_sha256: "identity", content_sha256: "content",
	proxies: [{ name: "private-node" }], last_success: 100, last_changed: 90,
	attempt: { source_sha256: "identity", at: 110, result: "failed", error: "download_failed" }
};
const current = project(source, "identity", cache);
check(current.ready && current.last_success == 100 && current.last_attempt == 110 &&
	current.last_changed == 90 && current.last_result == "failed", "failed refresh retains accepted cache");
const changed = project(source, "new-identity", cache);
check(!changed.ready && changed.previous_cache_retained && changed.last_success == null &&
	changed.last_attempt == null && changed.node_count == null, "source identity isolation");
check(project({ ...source, display_name: "Renamed" }, "identity", cache).ready, "rename preserves identity");
check(!project({ ...source, enabled: false }, "identity", cache).ready, "disabled source not ready");
const public_json = sprintf("%J", current);
check(index(public_json, "private-node") < 0 && index(public_json, source.url) < 0, "redacted projection");
print("native_sources_contract_ok\n");
