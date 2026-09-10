import * as fs from "fs";

const path = ARGV[0] ?? replace(sourcepath(), /[^/]+$/, "../openwrt/files/usr/libexec/opl-netfleet/plugins/components/lib/control.uc");
const source = fs.readfile(path);
const start = index(source, "restore_services = function(");
const end = index(source, "rollback = function(", start);
if (start < 0 || end < 0) die("recovery implementation unavailable");
const implementation = substr(source, start, end - start);
const harness = `
let now = 0, sets = 0, starts = 0, chosen = "old", broken = false, changed = false, running = {};
let restore_services;
const SERVICE = "test-core", MAIN = "test-main", KIND = "native-mihomo";
function time() { return now; }
function system(command) { now++; return 0; }
function run_command(command, work) { starts++; return true; }
function service_running(name) { return running[name] == true; }
function same_inputs(before) { return !changed; }
function api_secret() { return "test"; }
function controller_version(secret, timeout) { return now >= 1 ? "test" : null; }
function proxies(secret, timeout) { return {proxies: now >= 3 ? {group: {all: ["old", "desired"], now: chosen}} : {}}; }
function select(secret, name, choice) { sets++; chosen = choice; return true; }
function q(value) { return value; }
function parsed(command) { return {result: {active: true, runtime: {controller_available: true, lan_runtime: {dns_ready: now >= 5, transparent_proxy_ready: now >= 5}}}}; }
function probe_ok() { return !broken && now >= 7; }
function check(value, message) { if (!value) die(message); }
`;
const cases = `
const before = {core: true, supervisor: true, active: true, selections: {group: "desired"}};
check(restore_services(before, "/unused"), "eventually ready runtime must recover");
check(now == 7 && sets == 1 && starts == 2, "wait for providers, gateway and probe without restarting repeatedly");
now = 7; sets = 0; starts = 0; running = {"test-core": true, "opl-netfleet": true};
check(restore_services(before, "/unused") && sets == 0 && starts == 0, "already restored runtime must not be restarted or selections rewritten");
running = {"test-core": true};
check(restore_services(before, "/unused") && starts == 1, "only the missing supervisor must be started");
running = {"opl-netfleet": true}; starts = 0;
check(restore_services(before, "/unused") && starts == 1, "only the missing core must be started");
now = 7; broken = true;
check(!restore_services(before, "/unused") && now == 52, "persistent probe failure must time out");
now = 7; broken = false; changed = true;
check(!restore_services(before, "/unused") && now == 7, "changed private configuration must fail immediately");
`;
loadstring(harness + implementation + cases)();
const recovery_start = index(source, "rollback = function(");
const recovery_end = index(source, "upgrade = function(", recovery_start);
const recovery = substr(source, recovery_start, recovery_end - recovery_start);
loadstring(`
let rollback, stops = 0, starts = 0, commands = [], world_calls = 0, saved;
let package_ok = false, world_ok = true, identity_ok = true, runtime_ok = true, input_ok = true, bytes_ok = true;
const UPGRADE_STATE = "/unused", fs = {unlink: path => true};
function q(value) { return value; }
function stop_services(work) { stops++; return true; }
function run_command(command, work) { push(commands, command); return index(command, "apk ") != 0 || package_ok; }
function restore_world(names, before, work) { world_calls++; if (!world_ok) die("world unavailable"); return true; }
function installed() { return {package: identity_ok ? "old" : "new"}; }
function input_identity(paths) { return {code: bytes_ok ? "old" : "partial"}; }
function same_inputs(before) { return input_ok; }
function restore_services(before, work) { starts++; return runtime_ok; }
function atomic_json(path, value) { saved = value; return true; }
function check(value, message) { if (!value) die(message); }
` + recovery + `
const before = {world: {}, runtime_paths: ["code"], runtime_inputs: {code: "old"}};
check(rollback(before, "/unused", ["package"], {package: "old"}, ["old.apk"], true) == "rollback_install_failed",
    "nonzero package result remains an error");
check(starts == 1 && world_calls == 1 && saved.runtime_restored,
    "package errors must not skip world or runtime restoration");
package_ok = true; world_ok = false;
rollback(before, "/unused", ["package"], {package: "old"}, ["old.apk"], true);
check(starts == 2 && saved.runtime_restored, "world exceptions must not skip runtime restoration");
world_ok = true; identity_ok = false;
let previous_stops = stops;
rollback(before, "/unused", ["package"], {package: "old"}, ["old.apk"], true);
check(starts == 2 && stops == previous_stops + 2 && !saved.runtime_restored,
    "wrong package identity must stay stopped and still run final cleanup");
identity_ok = true; runtime_ok = false;
previous_stops = stops;
rollback(before, "/unused", ["package"], {package: "old"}, ["old.apk"], true);
check(stops == previous_stops + 2 && !saved.runtime_restored, "failed restart must clean again");
runtime_ok = true;
bytes_ok = false;
let previous_starts = starts;
rollback(before, "/unused", ["package"], {package: "old"}, ["old.apk"], true);
check(starts == previous_starts && !saved.runtime_restored, "version equality must not hide partially restored runtime files");
bytes_ok = true;
check(rollback(before, "/unused", ["package"], {package: "old"}, ["old.apk"], true) == null,
    "verified successful rollback remains successful");
`)();
print("components_recovery_contract_ok\n");

// APK local paths replace world roots with checksums. Exercise administrator
// constraints and rollback, including unrelated roots, against the real helper.
const world_start = index(source, "restore_world = function(");
const world_end = index(source, "feed = function(", world_start);
loadstring(`
let restore_world, actual, commands = [], succeeds = true;
function q(value) { return value; }
function run_command(command, work) { push(commands, command); return succeeds; }
function package_world() { return actual; }
function check(value, message) { if (!value) die(message); }
` + substr(source, world_start, world_end - world_start) + `
const before = {a: "a", b: "b>=2", c: "c><Q1old", unrelated: "unrelated@stable"};
actual = {a: "a", b: "b>=2", c: "c", unrelated: "unrelated@stable"};
check(restore_world(["a", "b", "c", "dep"], before, "/unused"), "successful update normalizes archive pins but preserves administrator constraints");
check(index(commands[0], "a b>=2 c") >= 0 && index(commands[1], "del dep") >= 0, "restore exact roots and remove accidental dependency roots");
actual.c = "c><Q1old";
check(restore_world(["c"], before, "/unused", true), "rollback restores the original checksum pin");
actual.b = "b><Q1new";
check(!restore_world(["b"], before, "/unused"), "an unrestored version constraint must fail");
actual = {a: "a", b: "b>=2", c: "c", unrelated: "changed"};
check(!restore_world(["a", "b", "c"], before, "/unused"), "unrelated world roots cannot change silently");
succeeds = false;
check(!restore_world(["a"], before, "/unused"), "unsatisfied constraints require transaction rollback");
`)();
