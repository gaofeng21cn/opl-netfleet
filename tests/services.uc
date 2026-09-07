import * as fs from "fs";
import { create } from "../openwrt/files/usr/libexec/opl-netfleet/kernel/host.uc";

const root = fs.realpath(replace(sourcepath(), /[^/]+$/, "../openwrt/files/usr/libexec/opl-netfleet"));
const workspace = fs.mkdtemp("/tmp/netfleet-service-test.XXXXXX");
if (workspace == null) die("test workspace unavailable");
const host = create(root, {
	trusted_owner: fs.stat(root).uid,
	code_locks: false,
	system: json(fs.readfile(`${root}/../../share/opl-netfleet/system.json`)),
	override_path: `${workspace}/system.json`,
	lock_root: `${workspace}/locks`,
	maintenance_root: `${workspace}/maintenance`,
	network_lock: `${workspace}/network.lock`
});

export function use(name) { return host.use(name); };
export function release() {
	host.release();
	for (let name in fs.lsdir(`${workspace}/locks`) ?? []) fs.unlink(`${workspace}/locks/${name}`);
	fs.rmdir(`${workspace}/locks`);
	fs.rmdir(`${workspace}/maintenance`);
	fs.unlink(`${workspace}/network.lock`);
	fs.rmdir(workspace);
};
