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
function cleanup(directory) {
	for (let name in fs.lsdir(directory) ?? []) {
		const entry = `${directory}/${name}`;
		if (fs.lstat(entry)?.type == "directory") cleanup(entry); else fs.unlink(entry);
	}
	fs.rmdir(directory);
};
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
	const capabilities = {
		"platform.runtime": { ROOT_DIR: workspace, RUN_DIR: `${workspace}/run` },
		"platform.process": host.use("platform.process"), "platform.storage": storage
	};
	const profiles = loadfile(`${root}/plugins/mihomo/lib/profile-storage.uc`)()({ use: name => capabilities[name] });
	check(profiles.resolve_profile("file:../outside") == null && profiles.resolve_profile("subscription:../outside") == null,
		"shared profile references reject traversal without loading OpenWrt");
	check(storage.mkdir(`${workspace}/subscriptions`), "create isolated subscription cache");
	const alpha = `${workspace}/subscriptions/alpha.yaml`, beta = `${workspace}/subscriptions/beta.yaml`;
	check(storage.write_json_atomic(alpha, { proxies: [] }) && storage.write_json_atomic(beta, { proxies: [] }), "prepare owned caches");
	const link = profiles.provider_runtime_path("sample");
	check(profiles.prepare_provider_links({ sample: { path: alpha } }) && fs.readlink(link) == alpha, "provider link binds exact owner cache");
	check(profiles.prepare_provider_links({ sample: { path: beta } }) && fs.readlink(link) == beta, "provider replacement remains inside owner cache");
	check(!profiles.remove_provider_links({ sample: { path: alpha } }) && fs.readlink(link) == beta, "stale cleanup cannot remove another cache generation");
	check(profiles.remove_provider_links({ sample: { path: beta } }) && fs.lstat(link) == null, "matching owner can remove its link");
	check(storage.write_text(link, "foreign") && !profiles.prepare_provider_links({ sample: { path: alpha } }) &&
		fs.readfile(link) == "foreign", "existing file survives link preparation");
	if (system("command -v yq >/dev/null 2>&1") == 0) {
		const cache_state = {};
		const cached_storage = loadfile(`${root}/plugins/platform-storage/lib/storage.uc`)()({ state: cache_state, use: host.use });
		const yaml_path = `${workspace}/cached.yaml`;
		check(storage.write_text(yaml_path, "items:\n  - name: alpha\n"), "prepare YAML document");
		const parsed = cached_storage.read_yaml(yaml_path, true);
		check(parsed?.items?.[0]?.name == "alpha", "YAML conversion returns actual document");
		parsed.items[0].name = "caller mutation";
		check(cached_storage.read_yaml(yaml_path, true)?.items?.[0]?.name == "alpha", "cache isolates nested caller changes");
		check(length(cache_state.yaml_cache) == 1, "unchanged source reuses one conversion");
		check(storage.write_text(yaml_path, "items:\n  - name: bravo\n") &&
			cached_storage.read_yaml(yaml_path, true)?.items?.[0]?.name == "bravo", "same-length replacement invalidates conversion immediately");
		check(storage.write_text(yaml_path, "items: [broken") && cached_storage.read_yaml(yaml_path, true) == null &&
			length(cache_state.yaml_cache) == 0, "malformed replacement cannot return prior valid YAML");
		for (let n = 0; n < 6; n++) {
			const path = `${workspace}/cache-${n}.yaml`;
			storage.write_text(path, `name: item${n}\n`);
			check(cached_storage.read_yaml(path)?.name == `item${n}`, "bounded cache retains document meaning");
		}
		check(length(cache_state.yaml_cache) == 4, "conversion cache is bounded in persistent plugin state");
		const gone = `${workspace}/cache-5.yaml`; fs.unlink(gone);
		check(cached_storage.read_yaml(gone) == null && length(cache_state.yaml_cache) == 3, "deletion invalidates cached document");
	} else warn("YAML conversion requires yq; exercised by OpenWrt qualification.\n");
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
	host.release(); cleanup(workspace); die(error.message);
}
host.release(); cleanup(workspace);
printf("storage capabilities: %d assertions passed\n", assertions);
