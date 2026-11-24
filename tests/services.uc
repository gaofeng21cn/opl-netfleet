import * as fs from "fs";
import { create } from "../openwrt/files/usr/libexec/opl-netfleet/kernel/host.uc";
import { create as create_adapter, stage_runtime, remove_tree } from "./host-test-adapter.uc";

const root = fs.realpath(replace(sourcepath(), /[^/]+$/, "../openwrt/files/usr/libexec/opl-netfleet"));
const workspace = fs.mkdtemp("/tmp/netfleet-service-test.XXXXXX");
if (workspace == null) die("test workspace unavailable");
const shared_runtime = getenv("NETFLEET_TEST_RUNTIME");
const use_shared = shared_runtime != null && length(shared_runtime) > 0 && fs.lstat(shared_runtime)?.type == "directory";
const runtime_root = use_shared ? fs.realpath(shared_runtime) : stage_runtime(`${workspace}/runtime`);
const host = create(runtime_root, {
	adapter: create_adapter(),
	trusted_owner: fs.stat(runtime_root).uid,
	code_locks: false,
	lazy_inspection: true,
	system: json(fs.readfile(`${root}/../../share/opl-netfleet/system.json`)),
	override_path: `${workspace}/system.json`,
	lock_root: `${workspace}/locks`,
	maintenance_root: `${workspace}/maintenance`,
	network_lock: `${workspace}/network.lock`
});

export function use(name) { return host.use(name); };
export function release() {
	host.release();
	remove_tree(workspace);
};
