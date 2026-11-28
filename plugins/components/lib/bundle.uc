import * as fs from "fs";

const SEMVER_RE = /^([0-9]+)\.([0-9]+)\.([0-9]+)$/;
const SHA256_RE = /^[a-f0-9]{64}$/;
const HEX40_RE = /^[a-f0-9]{40}$/;

function valid_semver(value) {
	return type(value) == "string" && match(value, SEMVER_RE) != null;
}

export function semver_cmp(a, b) {
	const ma = valid_semver(a) ? match(a, SEMVER_RE) : null;
	const mb = valid_semver(b) ? match(b, SEMVER_RE) : null;
	if (ma == null || mb == null) return null;
	for (let i = 1; i <= 3; i++) {
		const va = int(ma[i]), vb = int(mb[i]);
		if (va != vb) return va < vb ? -1 : 1;
	}
	return 0;
};

export function enabled(paths) {
	return paths?.SHELL_META_PATH != null && paths?.BUNDLE_CURRENT != null &&
		fs.lstat(paths.SHELL_META_PATH) != null && fs.lstat(paths.BUNDLE_CURRENT) != null;
};

function current_target_rel(ctx) {
	const raw = fs.readlink(ctx.paths.BUNDLE_CURRENT);
	return type(raw) == "string" && length(raw) ? raw : null;
}

function work_id(work) {
	return fs.basename(work);
}

function root_dir_safe(path) {
	const st = fs.lstat(path);
	if (st == null) return fs.mkdir(path, 0755) == true;
	return st.type == "directory" && st.uid == 0 && (st.mode & 022) == 0;
}

export function shell_info(ctx) {
	return fs.lstat(ctx.paths.SHELL_META_PATH) != null ? ctx.read_json(ctx.paths.SHELL_META_PATH) : null;
};

export function current_info(ctx) {
	const p1 = `${ctx.paths.BUNDLE_CURRENT}/share/build.json`;
	const p2 = `${ctx.paths.BUNDLE_ROOT}/build.json`;
	return fs.lstat(p1) != null ? ctx.read_json(p1) : fs.lstat(p2) != null ? ctx.read_json(p2) : null;
};

export function previous_info(ctx) {
	const p = `${ctx.paths.BUNDLE_PREVIOUS}/share/build.json`;
	return fs.lstat(p) != null ? ctx.read_json(p) : null;
};

export function feed_config(ctx) {
	const p = ctx.paths.RELEASE_FEED_PATH;
	if (p != null && fs.lstat(p) != null) {
		if (!ctx.private_file(p)) return null;
		const cfg = ctx.read_json(p);
		const url = type(cfg?.url) == "string" ? trim(replace(cfg.url, /\/+$/, "")) : null;
		if (url == null || match(url, /[[:space:]@]/) != null) return null;
		if (match(url, /^https:\/\//)) return { url, allow_insecure: false };
		if (match(url, /^http:\/\//) && cfg.allow_insecure === true) return { url, allow_insecure: true };
		return null;
	}
	const opkg_url = ctx.opkg_feed();
	if (type(opkg_url) == "string" && match(opkg_url, /^https:\/\/[^[:space:]@]+$/)) {
		return { url: trim(replace(opkg_url, /\/+$/, "")), allow_insecure: false };
	}
	return null;
};

function curl_proto_args(allow_insecure) {
	return allow_insecure === true
		? "--proto '=http,https' --proto-redir '=http,https'"
		: "--proto '=https' --proto-redir '=https'";
}

function download_file(ctx, feed, remote_name, dest, work, max_time) {
	const url = `${feed.url}/${remote_name}`;
	const cmd = `curl -q -fsSL ${curl_proto_args(feed.allow_insecure)} --connect-timeout 10 --max-time ${max_time ?? 30} --output ${ctx.q(dest)} ${ctx.q(url)}`;
	return ctx.run_command(cmd, work);
}

function verify_usign(ctx, msg_path, sig_path, work) {
	const pub = ctx.paths.BUNDLE_KEY_PATH;
	const info = fs.lstat(pub);
	if (info == null || info.type != "file" || info.uid != 0 || (info.mode & 022) != 0) return false;
	return ctx.run_command(`usign -V -p ${ctx.q(pub)} -m ${ctx.q(msg_path)} -x ${ctx.q(sig_path)}`, work);
}

function dependency_satisfied(ctx, dep, installed_map) {
	if (dep == "opl-netfleet-kernel" || match(dep, /^opl-netfleet-plugin-[a-z][a-z0-9-]*$/) != null) return true;
	if (dep == "gzip" || dep == "tar") return ctx.capture(`command -v ${dep}`) != null;
	if (dep == "mihomo") {
		return installed_map?.["mihomo-meta"] != null || installed_map?.["mihomo"] != null ||
			ctx.capture("command -v mihomo") != null;
	}
	return installed_map?.[dep] != null;
}

function evaluate_gates(ctx, manifest) {
	const shell = shell_info(ctx);
	const shell_ver = shell?.shell_version ?? shell?.version ?? manifest?.min_shell_version;
	const cmp = valid_semver(shell_ver) && valid_semver(manifest?.min_shell_version)
		? semver_cmp(shell_ver, manifest.min_shell_version) : null;
	const shell_upgrade_required = cmp == null || cmp < 0;
	const installed_map = ctx.installed() ?? {};
	const missing_dependencies = [];
	for (let dep in (manifest?.system_dependencies ?? [])) {
		if (!dependency_satisfied(ctx, dep, installed_map)) push(missing_dependencies, dep);
	}
	return { shell, shell_version: shell_ver, shell_upgrade_required, missing_dependencies };
}

function validate_manifest(ctx, raw) {
	if (type(raw) != "object" || raw.schema != "opl-netfleet-release-bundle.v1") return null;
	if (!valid_semver(raw.version) || !valid_semver(raw.min_shell_version)) return null;
	if (type(raw.archive) != "string" || !match(raw.archive, /^opl-netfleet-bundle-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz$/)) return null;
	if (!match(raw.archive_sha256 ?? "", SHA256_RE) || type(raw.archive_size) != "int" || raw.archive_size <= 0) return null;
	if (!match(raw.source_commit ?? "", HEX40_RE) || !match(raw.source_tree ?? "", HEX40_RE)) return null;
	if (type(raw.files) != "object" || !length(keys(raw.files))) return null;
	return raw;
}

export function check(ctx, work, feed_override) {
	const cache_path = `${ctx.ROOT}/bundle-checked.json`;
	const feed = feed_override ?? feed_config(ctx);
	if (feed == null) ctx.fail("feed_not_configured");
	const tmp = ctx.mkdtemp("/tmp/opl-netfleet-bcheck.XXXXXX");
	if (tmp == null) ctx.fail("update_stage_failed");
	const mf_path = `${tmp}/release-manifest.json`;
	const sig_path = `${tmp}/release-manifest.json.sig`;
	let err = null, manifest = null, gates = null, caught = null;
	try {
		if (!download_file(ctx, feed, "release-manifest.json", mf_path, work, 30) ||
			!download_file(ctx, feed, "release-manifest.json.sig", sig_path, work, 30)) {
			err = "feed_check_failed";
		} else if (!verify_usign(ctx, mf_path, sig_path, work)) {
			err = "bundle_signature_invalid";
		} else {
			manifest = validate_manifest(ctx, ctx.read_json(mf_path));
			if (manifest == null) err = "bundle_manifest_invalid";
			else gates = evaluate_gates(ctx, manifest);
		}
	} catch (e) {
		caught = e;
	}
	ctx.run_command(`rm -rf ${ctx.q(tmp)}`, work);
	if (caught != null) die(caught);
	const record = {
		feed: feed.url,
		checked_at: int(time()),
		error: err,
		available_version: manifest?.version ?? null,
		min_shell_version: manifest?.min_shell_version ?? null,
		source_commit: manifest?.source_commit ?? null,
		shell_upgrade_required: gates?.shell_upgrade_required ?? false,
		missing_dependencies: gates?.missing_dependencies ?? [],
		manifest: manifest
	};
	if (!ctx.atomic_json(cache_path, record)) ctx.fail("update_state_write_failed");
	if (err != null) ctx.fail(err);
	return record;
};

function read_cache(ctx, feed_url) {
	const p = `${ctx.ROOT}/bundle-checked.json`;
	if (!ctx.private_file(p)) return null;
	const cached = ctx.read_json(p);
	return cached != null && cached.feed == feed_url ? cached : null;
}

export function get_state(ctx) {
	const versions = ctx.installed();
	const mgr = ctx.package_manager();
	const shell = shell_info(ctx);
	const cur = current_info(ctx);
	const prev = previous_info(ctx);
	const feed = feed_config(ctx);
	const cache = feed != null ? read_cache(ctx, feed.url) : null;
	const cur_ver = cur?.version ?? versions?.[ctx.PACKAGES[0]] ?? null;
	const cand_ver = cache?.error == null ? cache?.available_version : null;
	const update_cmp = cand_ver != null && cur_ver != null ? semver_cmp(cur_ver, cand_ver) : null;
	const shell_req = cache?.error == null && cache?.shell_upgrade_required == true;
	const missing_deps = cache?.error == null ? (cache?.missing_dependencies ?? []) : [];
	const has_update = update_cmp != null && update_cmp < 0;
	const can_apply = has_update && !shell_req && !length(missing_deps);

	const running = ctx.controller_version(ctx.api_secret(), 2);
	const binary = ctx.capture("mihomo -v");
	const binary_version = match(binary ?? "", /^Mihomo[[:space:]]+([^[:space:]]+)/)?.[1] ?? null;
	const core_pkg = versions?.[ctx.PACKAGES[2]] ?? versions?.["mihomo"] ?? null;
	const luci_pkg = versions?.[ctx.PACKAGES[1]] ?? null;

	const netfleet_reason = shell_req ? "shell_upgrade_required" :
		length(missing_deps) ? "shell_dependencies_missing" : null;
	const rows = [
		{
			id: "netfleet",
			label: "NetFleet",
			installed_version: cur_ver,
			running_version: cur_ver,
			available_version: has_update ? cand_ver : null,
			update_available: has_update,
			managed: versions != null && !shell_req && !length(missing_deps),
			reason: netfleet_reason
		},
		{
			id: "luci",
			label: "LuCI 接入组件",
			installed_version: luci_pkg ?? cur_ver,
			running_version: null,
			available_version: null,
			update_available: false,
			managed: false,
			reason: "shell_package_managed"
		},
		{
			id: "mihomo",
			label: "Mihomo",
			installed_version: core_pkg ?? binary_version,
			running_version: running,
			available_version: null,
			update_available: false,
			managed: false,
			reason: ctx.KIND != "native-mihomo" ? "core_managed_externally" : "shell_package_managed"
		}
	];
	const product = ctx.product_packages();
	const missing_product = filter(product, name => versions != null && versions[name] == null);
	const dep_list = [];
	const checked_deps = {};
	for (let dep in ctx.DEPENDENCIES) {
		checked_deps[dep] = true;
		push(dep_list, {
			id: dep, label: dep, installed_version: versions?.[dep] ?? null,
			available: versions != null && (versions[dep] != null || (mgr == "opkg" && ctx.adapter.package_available(dep)))
		});
	}
	if (!checked_deps["usign"]) {
		push(dep_list, {
			id: "usign", label: "usign", installed_version: versions?.["usign"] ?? null,
			available: versions != null && (versions?.["usign"] != null || ctx.capture("command -v usign") != null)
		});
	}
	const prev_ver = prev?.version ?? null;
	return {
		supported: versions != null,
		unsupported_reason: null,
		delivery_mode: "release-bundle",
		package_manager: mgr,
		backend: ctx.KIND,
		architecture: mgr == "apk" ? ctx.capture("apk --print-arch") : ctx.opkg_arch(),
		shell_version: shell?.shell_version ?? shell?.version ?? null,
		bundle_version: cur_ver,
		min_shell_version: cache?.min_shell_version ?? cur?.min_shell_version ?? null,
		shell_upgrade_required: shell_req,
		missing_dependencies: missing_deps,
		previous_version: prev_ver,
		rollback_available: prev_ver != null && prev_ver != cur_ver,
		capabilities: { batch_plugin_update: false, release_bundle: true },
		feed: {
			configured: feed != null,
			url: feed?.url ?? null,
			checked_at: cache?.checked_at ?? null,
			error: cache?.error ?? null
		},
		components: rows,
		plugin_packages: [],
		auto_update: type(ctx.auto_update_summary) == "function" ? ctx.auto_update_summary() : null,
		dashboard: ctx.dashboard_resource(),
		extensions: ctx.inventory(versions),
		product: {
			packages: map(product, name => ({ name, installed_version: versions?.[name] ?? null, available_version: can_apply ? cand_ver : null })),
			missing: missing_product,
			updates: []
		},
		dependencies: dep_list
	};
};

function available_bytes(ctx, dir) {
	const raw = ctx.capture(`df -Pk ${ctx.q(dir)} | awk 'NR==2 { print $4 }'`);
	if (raw == null || !match(raw, /^[0-9]+$/)) return null;
	return int(raw) * 1024;
}

function check_archive_entries(ctx, archive_path) {
	const pipe = fs.popen(`tar -tzf ${ctx.q(archive_path)} 2>/dev/null`);
	if (pipe == null) return false;
	const list = pipe.read("all");
	if (pipe.close() != 0 || list == null) return false;
	for (let raw in split(list, "\n")) {
		if (!length(raw)) continue;
		const clean = replace(raw, /^\.\//, "");
		if (!length(clean) || clean == ".") continue;
		if (substr(clean, 0, 1) == "/" || match(clean, /(^|\/)\.\.?(\/|$)/) != null || match(clean, /[\r\t]/) != null || index(clean, "\x00") >= 0)
			return false;
	}
	return true;
}

function verify_staged_tree(ctx, staging, manifest) {
	const found_files = {};
	function walk(dir, rel_prefix) {
		const entries = fs.lsdir(dir);
		if (type(entries) != "array") return false;
		for (let name in entries) {
			if (name == "." || name == "..") continue;
			const full = `${dir}/${name}`;
			const rel = rel_prefix == "" ? name : `${rel_prefix}/${name}`;
			const st = fs.lstat(full);
			if (st == null || st.type == "link") return false;
			if (st.type == "directory") {
				fs.chmod(full, 0755);
				if (!walk(full, rel)) return false;
			} else if (st.type == "file") {
				found_files[rel] = st;
			} else {
				return false;
			}
		}
		return true;
	}
	if (!walk(staging, "")) return false;
	const expected_keys = keys(manifest.files);
	if (length(keys(found_files)) != length(expected_keys)) return false;
	for (let rel, meta in manifest.files) {
		const st = found_files[rel];
		if (st == null || st.size != meta.size) return false;
		const full = `${staging}/${rel}`;
		if (ctx.sha256(full) != meta.sha256) return false;
		const exec_expected = meta.mode == "0755";
		fs.chmod(full, exec_expected ? 0755 : 0644);
	}
	return true;
}

function prevalidate_staging(ctx, staging, manifest, work) {
	const script = `
import * as fs from 'fs';
const root = ARGV[0] + '/runtime';
const expected_ver = ARGV[1];
const expected_commit = ARGV[2];
const build_path = ARGV[0] + '/share/build.json';
const build = json(fs.readfile(build_path));
if (build?.version != expected_ver || build?.source_commit != expected_commit) die('bundle_build_identity_mismatch');
const sys_default = json(fs.readfile(ARGV[0] + '/share/system.json'));
if (type(sys_default?.bindings) != 'object' || type(sys_default?.enabled) != 'object') die('bundle_system_invalid');
const host_mod = loadstring(sprintf('import { create } from %J; return create;', root + '/kernel/host.uc'))();
const adapter_mod = loadstring(sprintf('import { create } from %J; return create;', root + '/adapters/openwrt.uc'))();
const base_adapter = adapter_mod(root);
const stage_adapter = { ...base_adapter, paths: { ...base_adapter.paths, default_system: ARGV[0] + '/share/system.json' } };
const host = host_mod(root, { adapter: stage_adapter, code_locks: false });
let stage_err = null;
try {
	const list = host.inventory(null);
	if (type(list) != 'array' || !length(list)) die('bundle_plugins_empty');
	for (let item in list) {
		if (item.kind == 'plugin' && item.state == 'invalid') die('bundle_plugin_invalid:' + item.id);
	}
	if (type(loadfile(root + '/main.uc')) != 'function') die('bundle_main_invalid');
	if (host.system.scheduler?.service != null) {
		host.graph(host.system.scheduler.service, 1, {}, {}, {});
	}
	for (let id, flag in host.system.enabled) {
		if (flag != true) continue;
		const p = host.inspect(id);
		if (!p?.ok) die('bundle_enabled_plugin_broken:' + id);
		const seen_mod = {};
		for (let svc, def in p.manifest.services ?? {}) {
			if (host.system.bindings[svc] == id) host.graph(svc, def.version, {}, {}, {});
			if (type(def?.module) == 'string' && !seen_mod[def.module]) {
				seen_mod[def.module] = true;
				if (type(loadfile(p.directory + '/' + def.module)) != 'function')
					die('bundle_module_invalid:' + id + ':' + def.module);
			}
		}
	}
} catch (e) {
	stage_err = e;
}
host.release();
if (stage_err != null) die(stage_err);
print('OK\\n');
`;
	const script_path = `${work}/prevalidate.uc`;
	if (!fs.writefile(script_path, script)) return false;
	fs.chmod(script_path, 0600);
	const ok = ctx.run_command(`/usr/bin/ucode ${ctx.q(script_path)} ${ctx.q(staging)} ${ctx.q(manifest.version)} ${ctx.q(manifest.source_commit)}`, work);
	fs.unlink(script_path);
	return ok;
}

function atomic_symlink(link_path, target) {
	const parent = fs.dirname(link_path);
	const tmp_link = `${parent}/.${fs.basename(link_path)}.next.${int(time())}`;
	fs.unlink(tmp_link);
	if (!fs.symlink(target, tmp_link)) return false;
	if (!fs.rename(tmp_link, link_path)) {
		fs.unlink(tmp_link);
		return false;
	}
	return fs.readlink(link_path) == target;
}

function wait_rpcd_ready(ctx, expected_version) {
	for (let i = 0; i < 20; i++) {
		const listed = ctx.capture("ubus -v list opl-netfleet");
		const plisted = ctx.capture("ubus -v list opl-netfleet.plugins");
		if (listed != null && plisted != null) {
			const plist = ctx.parsed("ubus -t 10 call opl-netfleet.plugins plugins_list '{}'");
			const cur = current_info(ctx);
			if (plist?.ok == true && cur?.version == expected_version) return true;
		}
		system("sleep 1");
	}
	return false;
}

function find_product_ui_asset(ctx, base_www) {
	const root = `${base_www}/plugins/product-ui`;
	const entries = fs.lsdir(root);
	if (type(entries) != "array") return false;
	for (let rev in entries) {
		if (rev == "." || rev == "..") continue;
		const comp = `${root}/${rev}/resources/components.js`;
		const st = fs.lstat(comp);
		if (st != null && st.type == "file" && st.size > 0) return true;
	}
	return false;
}

function prune_generations(ctx, keep_targets) {
	const entries = fs.lsdir(ctx.paths.BUNDLE_RELEASES);
	if (type(entries) != "array") return;
	const keep_names = {};
	for (let rel in keep_targets) {
		if (type(rel) != "string") continue;
		const base = fs.basename(rel);
		if (length(base)) keep_names[base] = true;
	}
	for (let name in entries) {
		if (name == "." || name == "..") continue;
		if (keep_names[name]) continue;
		if (!match(name, /^[0-9A-Za-z._-]+$/)) continue;
		system(`rm -rf ${ctx.q(`${ctx.paths.BUNDLE_RELEASES}/${name}`)}`);
	}
}

function verify_switched(ctx, expected_version, expected_commit, before, work) {
	const deadline = time() + 15;
	if (!find_product_ui_asset(ctx, "/www/luci-static/resources/netfleet/bundle")) return false;
	while (time() <= deadline) {
		const cur = current_info(ctx);
		const plist = ctx.parsed(`ubus -t 10 call opl-netfleet.plugins plugins_list '{}'`);
		const status_res = ctx.parsed(`ubus -t 10 call opl-netfleet status '{}'`);
		const st = status_res?.result;
		const status_ok = before.unconfigured
			? (status_res?.ok == true || status_res?.error == "policy_unreadable")
			: (status_res?.ok == true && st?.build?.version == expected_version && st?.build?.source_commit == expected_commit && st?.active == before.active);
		if (cur?.version == expected_version && cur?.source_commit == expected_commit && plist?.ok == true && status_ok) {
			const status_plugin = filter(plist.result?.plugins ?? [], p => p.id == "status")[0];
			if (status_plugin == null || status_plugin.state == "invalid") {
				system("sleep 1");
				continue;
			}
			if (before.retain_core) {
				const now_core = ctx.native_identity();
				if (now_core?.pid != before.core_pid || now_core?.birth != before.core_birth) return false;
			}
			if (before.core) {
				const ready = st.runtime?.controller_available == true &&
					(ctx.KIND != "native-mihomo" || (st.runtime?.lan_runtime?.dns_ready == true && st.runtime?.lan_runtime?.transparent_proxy_ready == true));
				const probe_res = before.active ? ctx.parsed("ubus -t 10 call opl-netfleet probe '{}'") : null;
				const ubus_probe_ok = !before.active || (probe_res?.ok == true && probe_res?.result?.ok == true);
				if (ready && (!before.active || (ctx.probe_ok() && ubus_probe_ok))) return true;
			} else {
				return true;
			}
		}
		system("sleep 1");
	}
	return false;
}

function stop_for_switch(ctx, work, before) {
	if (ctx.service_running("opl-netfleet") && !ctx.run_command("/etc/init.d/opl-netfleet stop", work)) return false;
	if (before.retain_core) {
		const watch = ctx.parsed(`ubus call service list '${sprintf("%J", { name: ctx.SERVICE })}'`)?.[ctx.SERVICE]?.instances?.lifecycle;
		if (watch != null && watch.running == true) {
			ctx.run_command(`ubus call service delete '${sprintf("%J", { name: ctx.SERVICE, instance: "lifecycle" })}'`, work);
			if (watch.pid != null) ctx.run_command(`kill -KILL ${int(watch.pid)}`, work);
		}
		return true;
	}
	if (before.core && ctx.service_running(ctx.SERVICE) && !ctx.run_command(`/etc/init.d/${ctx.SERVICE} stop`, work)) return false;
	return true;
}

function resume_after_switch(ctx, work, before) {
	ctx.run_command("/etc/init.d/rpcd restart", work);
	if (before.retain_core) {
		const core_now = ctx.native_identity();
		if (core_now?.pid != before.core_pid || core_now?.birth != before.core_birth) return false;
		if (before.watch_spec != null) {
			ctx.run_command(`ubus call service add ${ctx.q(sprintf("%J", { name: ctx.SERVICE, instances: { lifecycle: before.watch_spec } }))}`, work);
		}
	} else if (before.core && !ctx.service_running(ctx.SERVICE)) {
		if (!ctx.run_command(`NETFLEET_PACKAGE_RESTORE=1 /etc/init.d/${ctx.SERVICE} start`, work)) return false;
	}
	if (before.supervisor && !ctx.service_running("opl-netfleet")) {
		if (!ctx.run_command("NETFLEET_PACKAGE_RESTORE=1 /etc/init.d/opl-netfleet start", work)) return false;
	}
	return true;
}

function rollback_switch(ctx, work, state, reason) {
	ctx.operation.update("rolling_back");
	ctx.network_enter();
	const before = state.before;
	const prev_target = state.previous_target;
	const prev_build = `${ctx.paths.BUNDLE_ROOT}/${prev_target}/share/build.json`;
	const expected_ver = before.version ?? ctx.read_json(prev_build)?.version;
	const expected_commit = before.source_commit ?? ctx.read_json(prev_build)?.source_commit;
	stop_for_switch(ctx, work, before);
	if (prev_target == null || !atomic_symlink(ctx.paths.BUNDLE_CURRENT, prev_target)) {
		if (ctx.KIND == "native-mihomo") ctx.gateway.cleanup();
		ctx.fail("rollback_identity_mismatch");
	}
	system("sync");
	const resumed = resume_after_switch(ctx, work, before) &&
		wait_rpcd_ready(ctx, expected_ver) &&
		verify_switched(ctx, expected_ver, expected_commit, before, work);
	if (!resumed) {
		if (ctx.KIND == "native-mihomo") ctx.gateway.cleanup();
		ctx.fail("rollback_runtime_failed");
	}
	let prev_link_target = fs.readlink(ctx.paths.BUNDLE_PREVIOUS);
	if (prev_link_target == state.target_rel) {
		if (type(state.previous_prev_target) == "string" && length(state.previous_prev_target) && state.previous_prev_target != state.target_rel) {
			atomic_symlink(ctx.paths.BUNDLE_PREVIOUS, state.previous_prev_target);
			prev_link_target = state.previous_prev_target;
		} else {
			fs.unlink(ctx.paths.BUNDLE_PREVIOUS);
			prev_link_target = null;
		}
	}
	prune_generations(ctx, [prev_target, prev_link_target]);
	const rolled_error = `${reason}_rolled_back`;
	ctx.journal(work, { ...state, phase: "rolled_back", error: rolled_error });
	fs.unlink(ctx.PENDING);
	system("sync");
	return rolled_error;
}

export function snapshot_before(ctx) {
	const policy_path = ctx.paths?.POLICY_PATH ?? "/etc/opl-netfleet/policy.json";
	const before_status = ctx.parsed(`ucode ${ctx.q(ctx.MAIN)} status`)?.result;
	const unconfigured = fs.lstat(policy_path) == null && (ctx.KIND == "nikki-mihomo" || !ctx.service_running(ctx.SERVICE));
	if (before_status == null && !unconfigured) ctx.fail("runtime_readback_failed");
	const cur = current_info(ctx);
	const core_running = unconfigured ? false : ctx.service_running(ctx.SERVICE);
	const retain_core = ctx.KIND == "native-mihomo" && core_running && before_status?.active == true;
	let core_id = null, watch_spec = null;
	if (retain_core) {
		core_id = ctx.native_identity();
		const svc = ctx.parsed(`ubus call service list '${sprintf("%J", { name: ctx.SERVICE })}'`)?.[ctx.SERVICE]?.instances?.lifecycle;
		if (svc?.running == true && type(svc.command) == "array") {
			watch_spec = { command: svc.command, term_timeout: svc.term_timeout ?? 5, stdout: true, stderr: true };
			if (svc.respawn != null) watch_spec.respawn = [svc.respawn.threshold, svc.respawn.timeout, svc.respawn.retry];
		}
	}
	const private_inputs = ctx.private_paths();
	return {
		backend: ctx.KIND,
		version: cur?.version ?? null,
		source_commit: cur?.source_commit ?? null,
		active: before_status?.active == true,
		unconfigured: unconfigured,
		core: core_running,
		retain_core: retain_core,
		core_pid: core_id?.pid ?? null,
		core_birth: core_id?.birth ?? null,
		watch_spec: watch_spec,
		supervisor: ctx.service_running("opl-netfleet"),
		inputs: ctx.input_identity(private_inputs),
		paths: private_inputs
	};
}

export function apply(ctx, request, work) {
	ctx.operation.update("checking");
	const feed = feed_config(ctx);
	if (feed == null || feed.url != request.feed) ctx.fail("update_request_changed");
	const checked = check(ctx, work, feed);
	const manifest = checked.manifest;
	if (request.version != null && manifest.version != request.version) ctx.fail("candidate_changed");
	if (checked.shell_upgrade_required) ctx.fail("shell_upgrade_required");
	if (length(checked.missing_dependencies)) ctx.fail("shell_dependencies_missing");

	const before_target = current_target_rel(ctx);
	if (before_target == null) ctx.fail("runtime_readback_failed");
	const target_rel = `releases/${manifest.version}`;
	const target_dir = `${ctx.paths.BUNDLE_RELEASES}/${manifest.version}`;
	if (before_target == target_rel) ctx.fail("bundle_already_active");

	const needed = (manifest.archive_size * 4) > 8388608 ? manifest.archive_size * 4 : 8388608;
	const avail = available_bytes(ctx, ctx.paths.BUNDLE_ROOT);
	if (avail != null && avail < needed) ctx.fail("insufficient_update_space");

	ctx.operation.update("downloading", { subject: "netfleet", total: manifest.archive_size, completed: 0 });
	ctx.cancellation(work);
	const dl_path = `${work}/bundle.tar.gz`;
	if (!download_file(ctx, feed, manifest.archive, dl_path, work, 120)) ctx.fail("candidate_download_failed");
	const dl_stat = fs.lstat(dl_path);
	if (dl_stat == null || dl_stat.size != manifest.archive_size || ctx.sha256(dl_path) != manifest.archive_sha256)
		ctx.fail("bundle_archive_mismatch");

	ctx.operation.update("validating");
	ctx.cancellation(work);
	if (!check_archive_entries(ctx, dl_path)) ctx.fail("bundle_stage_invalid");

	if (!root_dir_safe(ctx.paths.BUNDLE_RELEASES)) ctx.fail("unsafe_update_directory");
	const staging = `${ctx.paths.BUNDLE_RELEASES}/.staging-${request.id}`;
	ctx.run_command(`rm -rf ${ctx.q(staging)}`, work);
	if (fs.mkdir(staging, 0755) != true) ctx.fail("update_stage_failed");

	let staged_promoted = false, apply_err = null;
	try {
		if (!ctx.run_command(`tar -xzf ${ctx.q(dl_path)} -C ${ctx.q(staging)}`, work) ||
			!verify_staged_tree(ctx, staging, manifest)) ctx.fail("bundle_stage_invalid");
		fs.chmod(staging, 0755);
		ctx.run_command(`chmod -R go-w ${ctx.q(staging)}`, work);
		if (!prevalidate_staging(ctx, staging, manifest, work)) ctx.fail("bundle_prevalidate_failed");

		const before = snapshot_before(ctx);
		ctx.network_enter();
		if (current_target_rel(ctx) != before_target || !ctx.same_inputs(before)) ctx.fail("runtime_precondition_changed");
		if (before.retain_core) {
			const fresh_core = ctx.native_identity();
			if (fresh_core?.pid != before.core_pid || fresh_core?.birth != before.core_birth) ctx.fail("runtime_precondition_changed");
		}
		if (system("/etc/init.d/opl-netfleet-update-recovery enable >/dev/null 2>&1") != 0) ctx.fail("update_recovery_unavailable");

		ctx.run_command(`rm -rf ${ctx.q(target_dir)}`, work);
		if (!fs.rename(staging, target_dir)) ctx.fail("update_stage_failed");
		staged_promoted = true;

		const state = {
			schema: "opl-netfleet-bundle-tx.v1",
			kind: "bundle",
			phase: "switching",
			write_started: true,
			version: manifest.version,
			source_commit: manifest.source_commit,
			target_rel: target_rel,
			previous_target: before_target,
			previous_prev_target: fs.readlink(ctx.paths.BUNDLE_PREVIOUS),
			before: before
		};
		ctx.journal(work, state);
		if (!ctx.atomic_json(ctx.PENDING, { id: request.id, kind: "bundle" }) || system("sync") != 0) ctx.fail("update_state_write_failed");

		let err = null;
		try {
			ctx.operation.update("installing", { subject: "netfleet", total: 0, completed: 0 });
			if (!stop_for_switch(ctx, work, before)) ctx.fail("runtime_stop_failed");
			if (!atomic_symlink(ctx.paths.BUNDLE_CURRENT, target_rel)) ctx.fail("bundle_switch_failed");
			system("sync");
			ctx.operation.update("verifying");
			if (!resume_after_switch(ctx, work, before) ||
				!wait_rpcd_ready(ctx, manifest.version) ||
				!verify_switched(ctx, manifest.version, manifest.source_commit, before, work)) {
				ctx.fail("bundle_verify_failed");
			}
		} catch (failure) {
			err = ctx.error_code(failure);
		}
		if (err == null) {
			atomic_symlink(ctx.paths.BUNDLE_PREVIOUS, before_target);
			prune_generations(ctx, [target_rel, before_target]);
			ctx.journal(work, { ...state, phase: "complete" });
			fs.unlink(ctx.PENDING);
			system("sync");
			return;
		}
		const rolled = rollback_switch(ctx, work, state, err);
		ctx.fail(rolled);
	} catch (e) {
		apply_err = e;
	}
	if (!staged_promoted) ctx.run_command(`rm -rf ${ctx.q(staging)}`, work);
	if (apply_err != null) die(apply_err);
};

export function recover(ctx, work, pending, state) {
	ctx.network_enter();
	if (type(state) != "object" || state.kind != "bundle") ctx.fail("update_recovery_state_invalid");
	if (index(["complete", "rolled_back"], state.phase) >= 0) {
		const expected_rel = state.phase == "complete" ? state.target_rel : state.previous_target;
		if (current_target_rel(ctx) != expected_rel) {
			const ok = atomic_symlink(ctx.paths.BUNDLE_CURRENT, expected_rel);
			if (!ok) ctx.fail("rollback_identity_mismatch");
			system("sync");
		}
		const build = ctx.read_json(`${ctx.paths.BUNDLE_ROOT}/${expected_rel}/share/build.json`);
		if (!resume_after_switch(ctx, work, state.before) ||
			!wait_rpcd_ready(ctx, build?.version) ||
			!verify_switched(ctx, build?.version, build?.source_commit, state.before, work)) {
			ctx.fail("rollback_runtime_failed");
		}
		fs.unlink(ctx.PENDING);
		system("sync");
		const recovered_error = state.error ?? (state.failure_reason ? `${state.failure_reason}_rolled_back` : "update_interrupted_rolled_back");
		ctx.operation.finish(state.phase == "complete", state.phase == "complete" ? null : recovered_error,
			state.phase == "rolled_back" ? { rollback: { ok: true } } : null);
		return { recovered: true };
	}
	const rolled = rollback_switch(ctx, work, state, "update_interrupted");
	ctx.operation.finish(false, rolled, { rollback: { ok: true } });
	return { recovered: true };
};

export function rollback_previous(ctx, work) {
	const cur_target = current_target_rel(ctx);
	const prev_target = fs.readlink(ctx.paths.BUNDLE_PREVIOUS);
	if (cur_target == null || type(prev_target) != "string" || !length(prev_target) || prev_target == cur_target)
		ctx.fail("rollback_package_unavailable");
	const prev_build_path = `${ctx.paths.BUNDLE_ROOT}/${prev_target}/share/build.json`;
	if (fs.lstat(prev_build_path) == null) ctx.fail("rollback_package_unavailable");
	const prev_build = ctx.read_json(prev_build_path);
	if (prev_build == null || !valid_semver(prev_build.version)) ctx.fail("rollback_package_unavailable");
	const before = snapshot_before(ctx);
	ctx.network_enter();
	if (current_target_rel(ctx) != cur_target || !ctx.same_inputs(before)) ctx.fail("runtime_precondition_changed");
	if (system("/etc/init.d/opl-netfleet-update-recovery enable >/dev/null 2>&1") != 0) ctx.fail("update_recovery_unavailable");
	const state = {
		schema: "opl-netfleet-bundle-tx.v1",
		kind: "bundle",
		phase: "switching",
		write_started: true,
		version: prev_build.version,
		source_commit: prev_build.source_commit,
		target_rel: prev_target,
		previous_target: cur_target,
		before: before
	};
	ctx.operation.update("rolling_back", { subject: "netfleet", total: 0, completed: 0 });
	ctx.journal(work, state);
	if (!ctx.atomic_json(ctx.PENDING, { id: work_id(work), kind: "bundle" }) || system("sync") != 0) ctx.fail("update_state_write_failed");
	stop_for_switch(ctx, work, before);
	if (!atomic_symlink(ctx.paths.BUNDLE_CURRENT, prev_target)) {
		atomic_symlink(ctx.paths.BUNDLE_CURRENT, cur_target);
		ctx.fail("rollback_identity_mismatch");
	}
	system("sync");
	if (!resume_after_switch(ctx, work, before) ||
		!wait_rpcd_ready(ctx, prev_build.version) ||
		!verify_switched(ctx, prev_build.version, prev_build.source_commit, before, work)) {
		atomic_symlink(ctx.paths.BUNDLE_CURRENT, cur_target);
		system("sync");
		resume_after_switch(ctx, work, before);
		ctx.fail("rollback_runtime_failed");
	}
	atomic_symlink(ctx.paths.BUNDLE_PREVIOUS, cur_target);
	prune_generations(ctx, [prev_target, cur_target]);
	ctx.journal(work, { ...state, phase: "complete" });
	fs.unlink(ctx.PENDING);
	system("sync");
	return { rolled_back: true, version: prev_build.version, previous_version: before.version };
};
