import * as fs from "fs";
import { cursor } from "uci";
import { get, set, update_result } from "/usr/libexec/opl-netfleet/application/subscriptions.uc";
import { sha256, subscription_quota } from "/usr/libexec/opl-netfleet/adapters/uci.uc";
import { core_service } from "/usr/libexec/opl-netfleet/adapters/native.uc";

function check(value, message) { if (!value) die(message); };
const work = "/tmp/netfleet-native-fixture";
const input = `${work}/subscription-input.json`;
const cached = "/etc/opl-netfleet/native/subscriptions/fixture.yaml";
const lock = fs.open("/var/lock/opl-netfleet-deploy.lock", "a", 0600);
check(lock != null && lock.lock("xn") == true, "single global writer");
function request(source, revision, deleted) {
	fs.writefile(input, sprintf("%J", { request: { source: source, revision: revision ?? get().result.revision, delete: deleted ?? false } }));
	fs.chmod(input, 0600);
	return set(input);
};
if (ARGV[0] == "active") {
	const old = sha256(cached);
	const pid = core_service().service.instances.core.pid;
	const policy_digest = sha256("/etc/opl-netfleet/policy.json");
	const evidence_digest = sha256("/etc/opl-netfleet/evidence.json");
	check(request({ id: "fixture", quota_reset_day: 15 }).ok, "active metadata edit accepted");
	check(get().result.sources[0].quota_reset_day == 15 && !get().result.sources[0].pending_update, "metadata save is immediate and does not require refresh");
	check(sha256(cached) == old && core_service().service.instances.core.pid == pid &&
		sha256("/etc/opl-netfleet/policy.json") == policy_digest && sha256("/etc/opl-netfleet/evidence.json") == evidence_digest,
		"reset day preserves cache, running core, policy and measurement identity");
	const next_url = cursor().get("netfleet", "fixture", "url") + "&revision=active";
	check(request({ id: "fixture", name: "Active edit", url: next_url }).ok, "active source edit accepted");
	check(sha256(cached) == old, "active edit preserves running cache");
	check(core_service().service.instances.core.pid == pid, "active edit does not restart core");
	check(get().result.sources[0].pending_update && get().result.sources[0].using_previous_cache, "pending source identity visible");
	lock.close();
	print("native_runtime_active_edit_ok\n");
	exit(0);
}
const port = ARGV[0];
check(get().result.managed_by == "netfleet", "native source ownership");
const url = `https://192.168.1.2:${port}/native-subscriptions/valid?token=vm-only-credential`;
const created = request({ id: "fixture", name: "VM subscription", url: url, quota_reset_day: 15 });
check(created.ok, sprintf("%J", created));
check(created.result.sources[0].url == url && created.result.sources[0].user_agent == "clash.meta" &&
	created.result.sources[0].info_url == "", "authenticated editor receives current source fields");
check(!request({ id: "fixture", name: "Stale edit" }, "stale").ok, "stale revision rejected");
const first = update_result("fixture");
check(first.ok && first.changed, sprintf("%J", first));
check(get().result.sources[0].cache_present && get().result.sources[0].cache_current && get().result.sources[0].node_count > 0, "download recorded");
check(get().result.sources[0].quota.used == "3072 B" && get().result.sources[0].quota.expire == null, "quota and unlimited expiry projection");
check(get().result.sources[0].quota_reset_day == 15 && cursor().get("netfleet", "fixture", "quota_reset_day") == "15", "refresh preserves persisted manual reset day");
check(subscription_quota("fixture", {}).reset_day == 15 && subscription_quota("fixture", {}).reset_day_source == "manual", "status reads device-local reference and provenance");
const config_before_invalid = sha256("/etc/config/netfleet");
check(request({ id: "fixture", quota_reset_day: 32 }).error == "invalid_quota_reset_day" && sha256("/etc/config/netfleet") == config_before_invalid, "invalid date does not mutate UCI");
check(request({ id: "fixture", quota_reset_day: null }).ok && get().result.sources[0].quota_reset_day == null && subscription_quota("fixture", {}).reset_day == null, "clear persists and disappears from status");
check(request({ id: "fixture", quota_reset_day: 31 }).ok, "restore monthly reset reference");
check((fs.stat(cached).mode & 0777) == 0600 && (fs.stat("/etc/config/netfleet").mode & 0777) == 0600, "private files");
const original_digest = sha256(cached);
const original_mtime = fs.stat(cached).mtime;
const second = update_result("fixture");
check(second.ok && !second.changed && sha256(cached) == original_digest && fs.stat(cached).mtime == original_mtime, "unchanged body preserves identity and mtime");
check(request({ id: "fixture", name: "Renamed", url: "" }).ok, "credential-preserving edit");
check(sha256(cached) == original_digest, "rename retains cache");
check(request({ id: "fixture" }, null, true).error == "subscription_referenced_by_policy", "referenced deletion rejected");

// Editing credentials keeps the last known-good source until an accepted
// refresh replaces it; failed refresh must not erase runtime or quota facts.
const success_at = get().result.sources[0].last_success;
check(request({ id: "fixture", url: `https://192.168.1.2:${port}/native-subscriptions/missing?token=vm-only-credential` }).ok, "unavailable source edit");
const failed = update_result("fixture");
check(!failed.ok && sha256(cached) == original_digest, "download failure retains prior cache");
check(get().result.sources[0].quota_reset_day == 31, "failed refresh retains manual date");
check(get().result.sources[0].last_success == success_at, "failure retains success time");
check(get().result.sources[0].pending_update && get().result.sources[0].using_previous_cache, "failed replacement remains pending");
check(request({ id: "fixture", url: url }).ok, "restore source URL");
check(update_result("fixture").ok, "source recovers");

check(request({ id: "spare", name: "Spare", url: url }).ok, "add unreferenced source");
check(update_result("spare").ok, "spare source download");
const spare_digest = sha256("/etc/opl-netfleet/native/subscriptions/spare.yaml");
check(request({ id: "spare", name: "New identity", url: `https://192.168.1.2:${port}/native-subscriptions/invalid?token=vm-only-credential` }).ok, "source URL edit");
check(sha256("/etc/opl-netfleet/native/subscriptions/spare.yaml") == spare_digest, "new source identity retains last known-good cache");
check(get().result.sources[1].pending_update && !get().result.sources[1].cache_current, "last known-good does not claim current identity");
check(!update_result("spare").ok, "invalid subscription rejected");
check(request({ id: "spare" }, null, true).ok, "unreferenced source deletion");
check(length(get().result.sources) == 1, "single configured provider remains");
fs.unlink(input);
lock.close();
print("native_runtime_subscriptions_ok\n");
