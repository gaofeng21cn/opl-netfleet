import * as fs from "fs";

const path = replace(sourcepath(), /[^/]+$/, "../openwrt/files/usr/libexec/opl-netfleet/plugins/mihomo/lib/gateway.uc");
const source = fs.readfile(path);
const start = index(source, "cleanup = function(");
const end = index(source, "attach = function(", start);
if (start < 0 || end < 0) die("gateway cleanup implementation unavailable");
const implementation = substr(source, start, end - start);
loadstring(`
let cleanup, commands = [], removed = false, compatibility_fails = true;
let table_present = true, native_present = true, clear_fails = false, marked = 2, claim = true, clear_calls = 0;
const SERVICE = "test-core", OWNERSHIP = "/unused/owner.json", STATE = "/unused";
const fs = { unlink: path => { if (path == OWNERSHIP) removed = true; else claim = false; return true; },
  stat: path => path == "/usr/lib/ucode/netfleet_interception.so" ? native_present : claim };
function require(name) { return { clear_marked: () => { clear_calls++; if (clear_fails) die("mark_cleanup_failed"); marked = 0; } }; }
function ownership() { return { service: SERVICE, table: "11900", pref: "11900",
  mark: "0x40000000", mask: "0x40000000", families: [4, 6], bridge: {} }; }
function shell(command) {
  push(commands, command);
  if (command == "nft list table inet netfleet_compat") return table_present;
  if (command == "nft delete table inet netfleet_compat" && !compatibility_fails) table_present = false;
  return command != "nft delete table inet netfleet_compat" || !compatibility_fails;
}
function capture(command) { return ""; }
function shell_quote(value) { return value; }
` + implementation + `
let result = cleanup();
if (result.ok || result.error != "compatibility_cleanup_failed" || !result.result.base_clean ||
    !removed || !claim || clear_calls || index(commands, "nft delete table inet netfleet") < 0 ||
    index(commands, "ip -4 rule del pref 11900 fwmark 0x40000000/0x40000000 table 11900") < 0 ||
    index(commands, "ip -6 route del local default dev lo table 11900") < 0)
  die("optional failure prevented base cleanup or was reported as success");
compatibility_fails = false;
result = cleanup();
if (!result.ok || !result.result.clean || marked || claim || clear_calls != 1) die("successful cleanup regressed");
// A prior stop can remove the table before deleting its conntrack ownership.
marked = 3; claim = true;
result = cleanup();
if (!result.ok || marked || claim || clear_calls != 2) die("absent table left compatibility marks");
clear_fails = true; claim = true; marked = 1; removed = false;
result = cleanup();
if (result.ok || !removed || !claim || !marked || !result.result.base_clean) die("failed mark cleanup lost retry state or blocked base stop");
clear_fails = false; native_present = false;
result = cleanup();
if (result.ok || !claim) die("missing native cleaner reported a claimed dataplane clean");
claim = false;
result = cleanup();
if (!result.ok) die("legacy unclaimed gateway cannot stop");
`)();
print("gateway_cleanup_contract_ok\n");
