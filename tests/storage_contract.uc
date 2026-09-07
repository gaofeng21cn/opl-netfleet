import * as fs from "fs";
import { create } from "../openwrt/files/usr/libexec/opl-netfleet/kernel/host.uc";
import { create as create_adapter } from "../openwrt/files/usr/libexec/opl-netfleet/adapters/openwrt.uc";

const root = fs.realpath(replace(sourcepath(), /[^/]+$/, "../openwrt/files/usr/libexec/opl-netfleet"));
const workspace = fs.mkdtemp("/tmp/netfleet-storage.XXXXXX");
if (workspace == null) die("workspace unavailable");
const path = `${workspace}/value.json`;
const host = create(root, { adapter: create_adapter(), trusted_owner: fs.stat(root).uid, code_locks: false,
	system: json(fs.readfile(`${root}/../../share/opl-netfleet/system.json`)),
	override_path: `${workspace}/system.json`, maintenance_root: `${workspace}/maintenance` });
let assertions = 0;
function check(value, message) { if (!value) die(message); assertions++; };
try {
	// Resolving storage and documents must not load UCI or backend credentials.
	const storage = host.use("platform.storage");
	const documents = host.use("platform.documents");
	check(storage.read_json(path) == null, "missing file is unknown");
	check(storage.write_text(`${workspace}/missing/child`, "value") == false, "failed text write is not success");
	check(storage.write_text(path, "") && fs.stat(path).size == 0, "empty file is a successful complete write");
	check(storage.write_json_atomic(path, {revision: 1}), "first atomic write");
	check(storage.read_yaml(path)?.revision == 1, "JSON artifact accepted by document reader");
	check(storage.file_mtime(path) == int(fs.stat(path).mtime), "mtime uses filesystem time");
	check(storage.file_mtime(workspace) == null, "directory has no artifact mtime");
	const before = storage.sha256(path);
	check(storage.write_json_atomic(path, {revision: 2}) && storage.sha256(path) != before,
		"replacement exposes complete new content and digest");
	check(!storage.write_json_atomic(`${workspace}/missing/child.json`, {}), "failed write propagates failure");
	check(storage.read_json(path)?.revision == 2, "failed write preserves previous artifact");
	const policy = json(fs.readfile(`${root}/../../../etc/opl-netfleet/policy.example.json`));
	check(documents.validate_policy(null).ok == false, "missing policy is invalid");
	check(documents.validate_policy(policy).ok, "candidate policy matches platform paths");
	check(storage.write_json_atomic(path, policy) && documents.load_policy(path) != null,
		"policy validation uses storage without backend initialization");
	policy.evidence.path = `${workspace}/unexpected.json`;
	check(documents.validate_policy(policy).ok == false, "candidate with another evidence destination is rejected before writing");
	check(storage.write_json_atomic(path, policy) && documents.load_policy(path) == null,
		"OpenWrt document provider rejects another evidence destination");
} catch (error) {
	host.release(); fs.unlink(path); fs.unlink(`${path}.tmp`); fs.rmdir(workspace); die(error.message);
}
host.release(); fs.unlink(path); fs.rmdir(workspace);
printf("storage capabilities: %d assertions passed\n", assertions);
