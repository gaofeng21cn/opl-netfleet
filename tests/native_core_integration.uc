import * as fs from "fs";
import { shell_quote } from "../openwrt/files/usr/libexec/opl-netfleet/adapters/uci.uc";
import { url_path_segment } from "../openwrt/files/usr/libexec/opl-netfleet/adapters/mihomo.uc";
import { provider_group_leaf } from "../openwrt/files/usr/libexec/opl-netfleet/core/selector.uc";

if (fs.stat("/tmp/netfleet-native-vm-authorized") == null) die("disposable VM required");
const work = "/tmp/netfleet-native-fixture";
const base = "/etc/opl-netfleet/native";
const input = `${work}/core-input.json`;
const original = json(fs.readfile(`${work}/run/config.json`));
const manifest = json(fs.readfile(`${work}/manifest.json`)).generated_groups.standard;
const probe = `https://192.168.1.2:${ARGV[0]}/generate_204`;
function check(value, label) { if (!value) die(label); };
function command(cmd) {
	const p = fs.popen(cmd);
	const out = p.read("all");
	check(p.close() == 0, "fixture command failed");
	return out;
};
function invoke(action, argument, expected) {
	const p = fs.popen(`ucode /usr/libexec/opl-netfleet/main.uc ${action} ${argument == null ? "" : shell_quote(argument)}`);
	const out = p.read("all");
	const rc = p.close();
	check(index(out, "native-vm-fixture") < 0 && index(out, "native-region-node") < 0, "private core output");
	const result = json(out);
	check(result.ok == expected && (expected ? rc == 0 : rc != 0), `unexpected ${action}: ${result.error}`);
	return result;
};
function api(path, method, body) {
	return command(`curl -q -fsS --max-time 8 --noproxy '*' --proxy '' --unix-socket ${base}/core/controller.sock ` +
		`-X ${method ?? "GET"} ${body == null ? "" : "-H 'Content-Type: application/json' --data " + shell_quote(sprintf("%J", body))} ` +
		shell_quote(`http://localhost${path}`));
};
function pid() {
	return json(command("ubus call service list '{\"name\":\"opl-netfleet-core\"}'"))["opl-netfleet-core"]?.instances?.core?.pid;
};
function stage(profile) {
	fs.writefile(input, sprintf("%J", profile));
	fs.chmod(input, 0600);
	return invoke("native-core-stage", input, true);
};

stage(original);
const started = invoke("native-core-start", null, true).result;
check(started.listener_ready && started.controller_ready && !started.transparent_proxy, "core readiness");
const first_pid = pid();
invoke("native-core-start", null, true);
check(pid() == first_pid, "idempotent start replaced core");
for (let group in manifest.candidate_groups) api(`/proxies/${url_path_segment(group.name)}`, "DELETE");
api("/providers/proxies/NETFLEET-SOURCE-fixture/healthcheck");
api(`/group/standard/delay?url=${url_path_segment(probe)}&timeout=3000`);
api("/proxies/standard", "PUT", { name: manifest.region_groups[0].name });
const proxies = json(api("/proxies")).proxies;
const providers = json(api("/providers/proxies")).providers;
check(provider_group_leaf(proxies, providers, "NETFLEET-SOURCE-fixture", manifest.candidate_groups[0].name) == "native-region-node",
	"no verified provider leaf");
const before = json(command("curl -fsS --noproxy '*' http://127.0.0.1:19091/connections")).downloadTotal;
command(`curl -fsS --cacert /tmp/local-probe.crt --noproxy '' --proxy http://127.0.0.1:17890 ${shell_quote(probe)}`);
const after = json(command("curl -fsS --noproxy '*' http://127.0.0.1:19091/connections")).downloadTotal;
check(after > before, "explicit proxy bypassed provider");
check(invoke("native-sources-refresh", "fixture", false).error == "native_core_registered", "active refresh");
check(invoke("native-sources-set", `${work}/sources.json`, false).error == "native_core_registered", "active source edit");
check(invoke("native-core-stage", input, false).error == "native_core_registered", "active stage");
const lock = fs.open("/var/lock/opl-netfleet-deploy.lock", "a", 0600);
check(lock.lock("xn"), "lock");
check(invoke("native-core-stop", null, false).error == "mutation_busy", "busy stop");
check(pid() == first_pid, "busy stop killed core");
lock.close();
invoke("native-core-stop", null, true);
invoke("native-core-stop", null, true);
check(pid() == null && fs.stat(`${base}/core/controller.sock`) == null, "stop cleanup");

const saved_stage = fs.readfile(`${base}/core.json`);
fs.writefile(input, sprintf("%J", { ...original, "proxy-groups": [{ name: "bad", type: "not-a-group" }] }));
invoke("native-core-stage", input, false);
check(fs.readfile(`${base}/core.json`) == saved_stage, "invalid stage destroyed previous stage");
const sources = json(fs.readfile(`${work}/sources.json`));
const changed_sources = { ...sources, sources: [{ ...sources.sources[0], user_agent: "changed" }] };
fs.writefile(`${work}/changed-sources.json`, sprintf("%J", changed_sources));
fs.chmod(`${work}/changed-sources.json`, 0600);
invoke("native-sources-set", `${work}/changed-sources.json`, true);
check(invoke("native-core-start", null, false).error == "core_stage_stale", "stale source accepted");
invoke("native-sources-set", `${work}/sources.json`, true);

fs.writefile("/etc/config/nikki", "# VM conflict sentinel\n");
check(invoke("native-core-start", null, false).error == "existing_backend_owner", "Nikki conflict accepted");
fs.unlink("/etc/config/nikki");
command("ubus call service add '{\"name\":\"opl-netfleet-core\",\"instances\":{\"foreign\":{\"command\":[\"/bin/sleep\",\"60\"]}}}'");
check(invoke("native-core-stop", null, false).error == "core_owner_conflict", "foreign service stopped");
command("ubus call service delete '{\"name\":\"opl-netfleet-core\"}'");

// The fixture's independent SOCKS helper already owns 1081.
stage({ ...original, "mixed-port": 1081 });
check(invoke("native-core-start", null, false).error == "core_start_not_ready", "occupied port accepted");
check(pid() == null, "failed start left service");
check(json(command("curl -fsS --noproxy '*' http://127.0.0.1:19091/version")).version != null, "failed start killed foreign helper");
stage(original);
invoke("native-core-start", null, true);
system(`kill -KILL ${pid()}`);
for (let i = 0; i < 5; i++) {
	if (!invoke("native-core-status", null, true).result.running) break;
	system("sleep 1");
}
check(!invoke("native-core-status", null, true).result.running, "crashed core reported running");
check(invoke("native-sources-refresh", "fixture", false).error == "native_core_registered", "crash allowed uncoordinated refresh");
invoke("native-core-stop", null, true);
check(pid() == null && fs.stat(`${base}/core/controller.sock`) == null, "crash cleanup");
print("native_core_integration_ok\n");
