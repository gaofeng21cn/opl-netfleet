import { valid_id, valid_url, desired_source, userinfo, referenced, public_source, source_identity_input } from "../openwrt/files/usr/libexec/opl-netfleet/core/subscriptions.uc";

function check(value, label) { if (!value) die(label); };
const source = { id: "Provider_1", name: "Example", url: "https://example.test/sub?token=private", user_agent: "clash.meta", info_url: "", prefer: "remote" };
function desired(patch, previous) { return desired_source({ revision: "digest", source: { ...source, ...patch } }, previous); };
check(valid_id("Provider_1") && !valid_id("../provider") && !valid_id("a-b"), "stable policy section ID");
check(valid_url(source.url) && valid_url("http://example.test/sub"), "Nikki HTTP subscription compatibility");
for (let url in ["file:///secret", "https://user@example.test/sub", "https://example.test/sub\nheader", "https://example.test/sub#fragment", "https://example.test/sub\u0000x"])
	check(!valid_url(url), "reject unsafe URL");
check(desired({}, null).ok, "create subscription");
check(desired({ url: "" }, source).source.url == source.url, "blank URL preserves private credential");
check(!desired({ url: "" }, null).ok, "new subscription requires URL");
check(desired({ name: "Renamed" }, source).source_changed == false, "display edit retains cache identity");
check(desired({ url: "https://example.test/new" }, source).source_changed, "URL edit changes desired source identity");
check(sprintf("%J", source_identity_input(source)) == sprintf("%J", source_identity_input({ ...source, name: "Renamed" })),
	"display name does not change downloaded source identity");
check(sprintf("%J", source_identity_input(source)) != sprintf("%J", source_identity_input({ ...source, url: "https://example.test/new" })),
	"new URL remains distinguishable from last accepted cache");
check(!desired({ user_agent: "foo\r\nURL: bad" }, source).ok, "reject curl configuration injection");
check(!desired({ unknown: true }, source).ok, "reject unknown input");
check(desired_source({ revision: "digest", source: { id: "Provider_1" }, delete: true }, source).deleted, "explicit delete");
const quota = userinfo("HTTP/2 200\r\nSubscription-Userinfo: upload=10; download=20; total=100; expire=0\r\n");
check(quota.used == 30 && quota.avaliable == 70 && quota.expire == 0, "wire quota projection");
check(userinfo("HTTP/1.1 302 Found\nsubscription-userinfo: total=100\nHTTP/2 200\ncontent-type: application/yaml\n") == null, "ignore redirect quota");
check(userinfo("subscription-userinfo: expire=abc; total=100\n").expire == null, "malformed expiry remains unknown");
check(referenced({ providers: { primary: { section: "Provider_1", enabled: false } } }, "Provider_1"), "disabled provider still references source");
check(referenced({ recovery_profile: { ref: "subscription:Provider_1" } }, "Provider_1"), "recovery input cannot be removed");
check(!referenced({ providers: { primary: { section: "other" } } }, "Provider_1"), "unreferenced source can be removed");
const output = public_source({ ...source, last_attempt: "20", last_success: "10", last_result: "failed", last_error: "subscription_download_failed" }, { present: true, digest: "digest", node_count: 3 });
check(output.last_success == 10 && output.last_attempt == 20 && output.cache_present, "failed update retains success and cache");
check(index(sprintf("%J", output), source.url) < 0 && output.has_url, "credentials never projected");
const pending = public_source({ ...source, last_success: "10", last_result: "pending", total: "100 B" },
	{ present: true, current: false, digest: "old-digest", node_count: 3 });
check(pending.pending_update && pending.using_previous_cache && !pending.cache_current && pending.cache_present &&
	pending.last_success == 10 && pending.quota.total == "100 B", "source edit projects retained last good cache and quota");
const pending_failure = public_source({ ...source, last_success: "10", last_attempt: "30", last_result: "failed" },
	{ present: true, current: false, digest: "old-digest", node_count: 3 });
check(pending_failure.pending_update && pending_failure.using_previous_cache && pending_failure.last_success == 10,
	"failed new source leaves pending and last good cache");
const current = public_source({ ...source, last_success: "40", last_result: "unchanged" },
	{ present: true, current: true, digest: "old-digest", node_count: 3 });
check(current.cache_current && !current.pending_update && !current.using_previous_cache,
	"accepted new URL with identical bytes is current");
check(public_source(source, { present: false }).pending_update, "new source needs explicit refresh");
print("subscriptions_contract_ok\n");
