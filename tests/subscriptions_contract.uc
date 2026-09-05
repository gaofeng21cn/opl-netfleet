import { valid_id, valid_url, desired_source, userinfo, referenced, public_source } from "../openwrt/files/usr/libexec/opl-netfleet/core/subscriptions.uc";

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
check(desired({ url: "https://example.test/new" }, source).source_changed, "URL edit invalidates cache identity");
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
print("subscriptions_contract_ok\n");
