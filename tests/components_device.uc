import * as fs from "fs";

const owner = ARGV[0] ?? "/usr/libexec/opl-netfleet/application/components.uc";
function check(value, message) { if (!value) die(message); };
function call(argument) {
	const pipe = fs.popen(`ucode '${owner}' ${argument}`);
	check(pipe != null, "component owner starts");
	let response;
	try { response = json(pipe.read("all")); } catch (error) { die("component owner returns JSON"); }
	const code = pipe.close();
	check((code == 0) == (response.ok == true), "component response matches process result");
	return response;
};
const request = fs.readfile("/tmp/opl-netfleet-components/request.json");
const marker = fs.readfile("/tmp/opl-netfleet-package-upgrade-state");
const first = call("get");
check(first.ok && type(first.result.components) == "array" && length(first.result.components) == 3, "three actual component rows");
check(call("invalid-fixture-action").error == "unknown_component_action", "unknown action is rejected");
const operations = call("operation");
check(operations.ok && type(operations.result) == "object", "read-only operation response");
check(fs.readfile("/tmp/opl-netfleet-components/request.json") == request &&
	fs.readfile("/tmp/opl-netfleet-package-upgrade-state") == marker, "read-only calls do not schedule or mutate package recovery");
print("components_contract_ok\n");
