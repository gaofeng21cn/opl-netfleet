import * as fs from "fs";

const path = ARGV[0] ?? replace(sourcepath(), /[^/]+$/, "../openwrt/files/usr/libexec/opl-netfleet/application/components.uc");
const source = fs.readfile(path);
const start = index(source, "function restore_services(");
const end = index(source, "function upgrade(", start);
if (start < 0 || end < 0) die("recovery implementation unavailable");
const implementation = substr(source, start, end - start);
const harness = `
let now = 0, sets = 0, starts = 0, chosen = "old", broken = false, changed = false;
const SERVICE = "test-core", MAIN = "test-main", KIND = "native-mihomo";
function time() { return now; }
function system(command) { now++; return 0; }
function run_command(command, work) { starts++; return true; }
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
now = 7; sets = 0; starts = 0;
check(restore_services(before, "/unused") && sets == 0, "already restored selections must not be rewritten");
now = 7; broken = true;
check(!restore_services(before, "/unused") && now == 52, "persistent probe failure must time out");
now = 7; broken = false; changed = true;
check(!restore_services(before, "/unused") && now == 7, "changed private configuration must fail immediately");
`;
loadstring(harness + implementation + cases)();
print("components_recovery_contract_ok\n");
