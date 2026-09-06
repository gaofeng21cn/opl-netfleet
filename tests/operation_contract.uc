import * as fs from "fs";
import { begin, update, finish, get } from "../openwrt/files/usr/libexec/opl-netfleet/application/operation.uc";
import { ok } from "../openwrt/files/usr/libexec/opl-netfleet/output.uc";

function check(value, message) { if (!value) die(message); };
const path = "/tmp/opl-netfleet-operation-subscription.json";
const package_path = "/tmp/opl-netfleet-operation-packages.json";
const selection_path = "/tmp/opl-netfleet-operation-selection.json";
const previous = fs.readfile(path);
const previous_packages = fs.readfile(package_path);
const previous_selection = fs.readfile(selection_path);

begin("subscription", "preparing", { total: 2 });
let snapshot = get("subscription");
check(snapshot.state == "running" && snapshot.phase == "preparing" && snapshot.total == 2 && snapshot.completed == 0,
	"live owner publishes preparation without invented completion");
check(snapshot.owner == null && snapshot.finished_at == null, "public operation excludes process internals");
check((fs.stat(path).mode & 0777) == 0600, "operation state is private");
const id = snapshot.id;
update("downloading", { completed: 0, subject: "Example airport" });
snapshot = get("subscription");
check(snapshot.id == id && snapshot.phase == "downloading" && snapshot.subject == "Example airport", "real download phase and display name");
update("validating", { completed: 1 });
check(get("subscription").completed == 1, "completed providers advance after validation");
update("compiling", { subject: null });
check(get("subscription").subject == null && get("subscription").completed == 1, "later phases keep actual partial count");
update("rolling_back");
finish(false, "runtime_restart_failed", { url: "https://example.invalid/?token=private" });
snapshot = get("subscription");
check(snapshot.state == "failed" && snapshot.phase == "rolling_back" && snapshot.error == "runtime_restart_failed" &&
	snapshot.finished_at >= snapshot.started_at && snapshot.completed == 1, "rollback failure remains failed and partial");
check(index(fs.readfile(path), "private") < 0, "result details are not persisted");
update("verifying", { completed: 2 });
check(get("subscription").phase == "rolling_back", "terminal operation cannot be revived by a late update");

begin("subscription", "rolling_back");
finish(false, "runtime_restart_failed", { rollback: { ok: true } });
check(get("subscription").state == "failed" && get("subscription").recovery == "restored", "failed update reports successful restoration separately");
begin("subscription", "rolling_back");
finish(false, "rollback_failed", { rollback: { ok: false }, recovery: { ok: true, mode: "direct" } });
check(get("subscription").recovery == "direct", "direct recovery is only shown after confirmed cleanup");

begin("subscription", "validating", { total: 2, completed: 2 });
ok("refresh", { state: "cache_partial", result: { ok: false, reason: "cache_partial", failed_count: 1 } });
check(get("subscription").state == "failed" && get("subscription").error == "cache_partial", "inner partial failure is not outer RPC success");
begin("subscription", "validating", { total: 2, completed: 2 });
ok("refresh", { state: "unchanged", result: { ok: true, reason: "unchanged", changed_count: 0 } });
check(get("subscription").state == "succeeded" && get("subscription").phase == "validating", "unchanged content finishes without fake reload or selection");

begin("subscription", "downloading", { total: 1 });
let stored = json(fs.readfile(path));
stored.owner.pid = 0;
fs.writefile(path, sprintf("%J", stored));
const interrupted_bytes = fs.readfile(path);
snapshot = get("subscription");
check(snapshot.state == "interrupted" && snapshot.error == "operation_interrupted", "missing process is not eternally running");
check(fs.readfile(path) == interrupted_bytes, "interrupted readback does not mutate owner state");
begin("subscription", "downloading", { total: 1 });
stored = json(fs.readfile(path));
stored.owner.started = "different-process";
fs.writefile(path, sprintf("%J", stored));
check(get("subscription").state == "interrupted", "reused PID does not claim the operation is alive");

begin("selection", "preparing", { subject: "overseas", total: 2, completed: 0 });
snapshot = get("selection");
check(snapshot.state == "running" && snapshot.kind == "selection" && snapshot.phase == "preparing" && snapshot.total == 2,
	"selection operation publishes its initial progress");
update("checking", { subject: "provider-check", total: 2, completed: 0 });
update("selecting", { subject: "overseas", completed: 1 });
check(get("selection").phase == "selecting" && get("selection").completed == 1, "selection operation advances through measured candidates");
finish(true, null, { ok: true });
check(get("selection").state == "succeeded" && get("selection").phase == "selecting", "selection operation closes successfully");

begin("selection", "preparing", { total: 1 });
finish(false, "protected_probe_failed", { rollback: { ok: true } });
check(get("selection").state == "failed" && get("selection").recovery == "restored", "selection failure reports confirmed restoration");

begin("packages", "installing", { id: "packages-test_123", total: 2, subject: "https://example.invalid/?token=private" });
snapshot = get("packages");
check(snapshot.id == "packages-test_123" && snapshot.subject == null, "worker request identity is bound without exposing URLs");
finish(false, "https://example.invalid/?token=private");
check(get("packages").error == "operation_failed", "error details cannot expose credentials");
check(begin("../../outside", "downloading") == null && get("../../outside") == null, "only known operation paths are addressable");

if (previous == null) fs.unlink(path); else fs.writefile(path, previous);
if (previous_packages == null) fs.unlink(package_path); else fs.writefile(package_path, previous_packages);
if (previous_selection == null) fs.unlink(selection_path); else fs.writefile(selection_path, previous_selection);
print("operation_contract_ok\n");
