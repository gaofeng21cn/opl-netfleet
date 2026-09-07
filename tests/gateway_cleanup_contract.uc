import * as fs from "fs";

const path = replace(sourcepath(), /[^/]+$/, "../openwrt/files/usr/libexec/opl-netfleet/plugins/mihomo/lib/gateway.uc");
const source = fs.readfile(path);
const start = index(source, "cleanup = function(");
const end = index(source, "attach = function(", start);
if (start < 0 || end < 0) die("gateway cleanup implementation unavailable");
const implementation = substr(source, start, end - start);
loadstring(`
let cleanup, commands = [], removed = false, compatibility_fails = true;
const SERVICE = "test-core", OWNERSHIP = "/unused/owner.json";
const fs = { unlink: path => { removed = true; return true; } };
function ownership() { return { service: SERVICE, table: "11900", pref: "11900",
  mark: "0x40000000", mask: "0x40000000", families: [4, 6], bridge: {} }; }
function shell(command) {
  push(commands, command);
  return command != "nft delete table inet netfleet_compat" || !compatibility_fails;
}
function capture(command) { return ""; }
function shell_quote(value) { return value; }
` + implementation + `
let result = cleanup();
if (result.ok || result.error != "compatibility_cleanup_failed" || !result.result.base_clean ||
    !removed || index(commands, "nft delete table inet netfleet") < 0 ||
    index(commands, "ip -4 rule del pref 11900 fwmark 0x40000000/0x40000000 table 11900") < 0 ||
    index(commands, "ip -6 route del local default dev lo table 11900") < 0)
  die("optional failure prevented base cleanup or was reported as success");
compatibility_fails = false;
result = cleanup();
if (!result.ok || !result.result.clean) die("successful cleanup regressed");
`)();
print("gateway_cleanup_contract_ok\n");
