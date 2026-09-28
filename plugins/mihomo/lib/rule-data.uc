import * as fs from "fs";

// Native gateway-owned rule generations. The host serializes every write command.
return function(context, gateway) {
const files = context.use("platform.files");
const storage = context.use("platform.storage");
const process = context.use("platform.process");
const q = process.shell_quote;
const ROOT = "/etc/opl-netfleet/native/run/rule-data";
const RUN = "/etc/opl-netfleet/native/run";
const CONFIG = RUN + "/config.yaml";
const ACTIVE = ROOT + "/active.json";
const HISTORY = ROOT + "/history.json";
const PENDING = ROOT + "/pending.json";
const LOCK = "/etc/opl-netfleet/rulesets.lock.json";
const UPSTREAM = "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/";
function read(path) { return files.private_file(path) ? storage.read_json(path) : null; }
function shell(command) { return system(command + " >/dev/null 2>&1") == 0; }
function capture(command) {
 const value = process.capture(command, 15);
 if (value.status != 0) return null;
 try { return json(value.output); } catch (error) { return null; }
}
function directory(path) {
 return fs.lstat(path) == null ? fs.mkdir(path, 0700) : files.private_directory(path);
}
function owned(path) { return type(path) == "string" && match(path, /^\/etc\/opl-netfleet\/native\/run\/rule-data\/generation\.[A-Za-z0-9]+$/) != null; }
function discard(path) { if (owned(path)) shell("rm -rf " + q(path)); }
function supported(policy) {
 return storage.read_json("/etc/opl-netfleet/backend.json")?.kind == "native-mihomo" &&
  policy?.policy_source?.kind == "bundle" && policy.policy_source.ref == "bundle:base-v1";
}
function status(policy) {
 const h = read(HISTORY) ?? {};
 const enabled = supported(policy) && policy?.automation?.rule_refresh_enabled == true;
 const interval = policy?.automation?.rule_refresh_interval_seconds ?? 604800;
 const due = (h.last_success_at ?? 0) + interval;
 const retry = h.last_ok == false ? (h.last_attempt_at ?? 0) + 3600 : 0;
 return { supported: supported(policy), enabled, interval_seconds: interval,
  last_attempt_at: h.last_attempt_at ?? null, last_success_at: h.last_success_at ?? null,
  last_ok: h.last_ok ?? null, last_error: h.last_error ?? null,
  upstream_commit: read(ACTIVE)?.commit ?? null,
  next_run_at: enabled ? (due > retry ? due : retry) : null,
  pending: files.private_file(PENDING) };
}
function project(profile, generation) {
 const active = generation ?? read(ACTIVE);
 if (active == null) return profile;
 if (!owned(active.directory)) die("rule_data_generation_invalid");
 for (let id, entry in active.rules ?? {}) {
  const provider = profile["rule-providers"]?.[id];
  // User-owned provider overrides are never replaced by a builtin refresh.
  if (provider?.type != "file" || index(["./rulesets/" + id + ".mrs", RUN + "/rulesets/" + id + ".mrs", entry.path], provider.path) < 0) continue;
  if (entry.path != active.directory + "/" + id + ".mrs" || !files.private_file(entry.path)) die("rule_data_file_missing");
  provider.path = entry.path;
 }
 return profile;
}
function api(method, path, body) {
 const options = body == null ? "" : " --data-binary @" + q(body) + " -H 'Content-Type: application/json'";
 return shell("curl -q -fsS --noproxy '*' --proxy '' --max-time 45 --unix-socket " + q(RUN + "/controller.sock") +
  " -X " + q(method) + options + " " + q("http://localhost" + path));
}
function path_segment(value) {
 let result = "";
 for (let i = 0; i < length(value); i++) {
  const byte = ord(substr(value, i, 1));
  result += (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || index([45,46,95,126], byte) >= 0 ? chr(byte) : sprintf("%%%02X", byte);
 }
 return result;
}
function selectors() {
 const state = capture("curl -q -fsS --noproxy '*' --proxy '' --max-time 10 --unix-socket " + q(RUN + "/controller.sock") + " http://localhost/proxies");
 if (state?.proxies == null) return null;
 const result = {};
 for (let name, proxy in state.proxies) if (proxy.type == "Selector" && type(proxy.now) == "string") result[name] = proxy.now;
 return result;
}
function restore_selectors(values) {
 if (values == null) return false;
 const current = selectors();
 if (current == null) return false;
 for (let name, value in values) {
  if (current[name] == value) continue;
  if (!files.atomic_json(ROOT + "/selection.json", { name: value }) ||
   !api("PUT", "/proxies/" + path_segment(name), ROOT + "/selection.json")) return false;
 }
 const after = selectors();
 for (let name, value in values) if (after?.[name] != value) return false;
 return true;
}
function controller_rules() {
 return capture("curl -q -fsS --noproxy '*' --proxy '' --max-time 10 --unix-socket " + q(RUN + "/controller.sock") + " http://localhost/providers/rules");
}
function sets() {
 const all = capture("nft -j list table inet netfleet");
 if (all == null) return null;
 const result = {};
 for (let row in all.nftables ?? []) if (index(["china_ip", "china_ip6"], row.set?.name) >= 0)
  result[row.set.name] = row.set.elem ?? [];
 return result;
}
function batch(elements) {
 const commands = [];
 for (let name, elem in elements) {
  if (index(["china_ip", "china_ip6"], name) < 0 || type(elem) != "array") die("invalid_rule_data_set");
  push(commands, { flush: { set: { family: "inet", table: "netfleet", name } } });
  if (length(elem)) push(commands, { add: { element: { family: "inet", table: "netfleet", name, elem } } });
 }
 return { nftables: commands };
}
function apply_sets(elements, check) {
 if (elements == null || !length(keys(elements))) return true;
 const path = ROOT + "/sets.json";
 return files.atomic_json(path, batch(elements)) && shell("nft " + (check ? "-c " : "") + "-j -f " + q(path));
}
function active_sets() {
 const active = read(ACTIVE);
 if (active == null) return true;
 const present = sets();
 if (present == null) return false;
 const requested = {};
 for (let name in keys(present)) requested[name] = active.sets?.[name] ?? present[name];
 return apply_sets(requested, false);
}
function reload() {
 const body = ROOT + "/reload.json";
 return files.atomic_json(body, { path: CONFIG }) && api("PUT", "/configs?force=true", body);
}
function record(ok, error, commit) {
 const old = read(HISTORY) ?? {};
 const next = { ...old, last_attempt_at: int(time()), last_ok: ok, last_error: error };
 if (ok) { next.last_success_at = int(time()); next.upstream_commit = commit; }
 if (!files.atomic_json(HISTORY, next)) return { ok: false, error: "rule_data_history_write_failed" };
 return { ok, error, result: next };
}
function recover() {
 const pending = read(PENDING);
 if (pending == null) return { ok: true };
 // The accepted pointer is written last; an interrupted post-commit cleanup is complete.
 if (read(ACTIVE)?.directory == pending.candidate) {
  fs.unlink(PENDING);
  return { ok: true, committed: true };
 }
 const digest = storage.sha256(CONFIG);
 if (digest != pending.candidate_sha256 && digest != pending.previous_sha256)
  return { ok: false, error: "rule_data_recovery_conflict" };
 if (!files.atomic_json(CONFIG, pending.config) || !reload() || !restore_selectors(pending.selectors) || !apply_sets(pending.sets, false) ||
  gateway.readiness()?.result?.ready != true) {
  shell("/etc/init.d/opl-netfleet-core stop");
  return { ok: false, error: "rule_data_rollback_failed" };
 }
 fs.unlink(PENDING); discard(pending.candidate);
 return { ok: true, restored: true };
}
function download(url, path) {
 if (!shell("curl -q -fSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 60 --max-filesize 8388608 --retry 1 -o " + q(path) + " " + q(url))) return false;
 return fs.chmod(path, 0600) && fs.stat(path)?.size > 0 && fs.stat(path).size <= 8388608;
}
function cidrs(text) {
 const result = { china_ip: [], china_ip6: [] };
 for (let line in split(text, "\n")) {
  line = trim(line);
  if (!length(line) || substr(line, 0, 1) == "#") continue;
  const pair = split(line, "/");
  const ipv6 = index(pair[0], ":") >= 0;
  if (length(pair) != 2 || !match(pair[0], ipv6 ? /^[0-9a-fA-F:]+$/ : /^[0-9.]+$/) ||
   !match(pair[1], /^[0-9]+$/) || int(pair[1]) < 1 || int(pair[1]) > (ipv6 ? 128 : 32)) die("invalid_cn_cidr");
  push(result[ipv6 ? "china_ip6" : "china_ip"], { prefix: { addr: pair[0], len: int(pair[1]) } });
 }
 if (!length(result.china_ip) || !length(result.china_ip6)) die("empty_cn_cidrs");
 return result;
}
function refresh(policy, initiator) {
 if (!directory(ROOT)) return { ok: false, error: "rule_data_directory_invalid" };
 const recovered = recover();
 if (!recovered.ok) return record(false, recovered.error, null);
 if (initiator == "reconcile") return recovered;
 if (!supported(policy)) return { ok: false, error: "rule_data_not_supported" };
 if (initiator == "scheduled" && policy?.automation?.rule_refresh_enabled != true) return { ok: true, result: { state: "disabled" } };
 if (!record(false, "update_in_progress", null).result) return { ok: false, error: "rule_data_history_write_failed" };
 if (gateway.readiness()?.result?.ready != true) return record(false, "runtime_not_ready", null);
 const probes = context.use("mihomo.controller").protected_probes;
 if (probes(policy)?.ok != true) return record(false, "protected_baseline_failed", null);
 const before = storage.sha256(CONFIG);
 const core_pid = gateway.process_state().pid;
 const config = read(CONFIG);
 const initial_sets = sets();
 const initial_selectors = selectors();
 const previous = read(ACTIVE);
 const lock = storage.read_json(LOCK);
 if (config == null || initial_sets == null || initial_selectors == null || lock?.upstream?.repository != "MetaCubeX/meta-rules-dat" ||
  !match(lock.upstream.commit ?? "", /^[0-9a-f]{40}$/)) return record(false, "rule_data_inputs_invalid", null);
 const work = fs.mkdtemp(ROOT + "/generation.XXXXXX");
 if (!owned(work)) return record(false, "rule_data_stage_failed", null);
 let generation = null;
 try {
  if (!download("https://api.github.com/repos/MetaCubeX/meta-rules-dat/commits/meta", work + "/upstream.json")) die("rule_data_revision_download_failed");
  const commit = read(work + "/upstream.json")?.sha;
  if (!match(commit ?? "", /^[0-9a-f]{40}$/)) die("rule_data_revision_invalid");
  generation = { directory: work, commit, rules: {}, sets: null };
  const original = UPSTREAM + lock.upstream.commit + "/";
  for (let entry in lock.rulesets ?? []) {
   const provider = config["rule-providers"]?.[entry.id];
   if (provider == null) continue;
   const paths = ["./rulesets/" + entry.id + ".mrs", RUN + "/rulesets/" + entry.id + ".mrs", previous?.rules?.[entry.id]?.path];
   if (provider.type != "file" || index(paths, provider.path) < 0) continue;
   if (!match(entry.id ?? "", /^[a-z][a-z0-9-]+$/) || index(entry.url ?? "", original) != 0) die("rule_data_source_invalid");
   const relative = substr(entry.url, length(original));
   if (!match(relative, /^geo\/(geoip|geosite)\/[A-Za-z0-9%_.!-]+\.mrs$/)) die("rule_data_source_invalid");
   const path = work + "/" + entry.id + ".mrs";
   if (!download(UPSTREAM + commit + "/" + relative, path)) die("rule_data_download_failed");
   generation.rules[entry.id] = { path, sha256: storage.sha256(path) };
  }
  if (!length(keys(generation.rules))) die("rule_data_no_managed_providers");
  if (!download(UPSTREAM + commit + "/geo/geoip/cn.list", work + "/cn.list")) die("rule_data_cn_download_failed");
  generation.sets = cidrs(fs.readfile(work + "/cn.list"));
  const requested_sets = {};
  for (let name in keys(initial_sets)) requested_sets[name] = generation.sets[name];
  if (!apply_sets(requested_sets, true)) die("rule_data_nft_validation_failed");
  const candidate = json(sprintf("%J", config));
  for (let id, entry in generation.rules) candidate["rule-providers"][id].path = entry.path;
  const candidate_path = work + "/candidate.json";
  if (!files.atomic_json(candidate_path, candidate) || !shell("mihomo -d " + q(RUN) + " -f " + q(candidate_path) + " -t")) die("rule_data_profile_validation_failed");
  let changed = previous == null || sprintf("%J", previous.sets) != sprintf("%J", generation.sets);
  for (let id, entry in generation.rules) if (entry.sha256 != previous?.rules?.[id]?.sha256) changed = true;
  if (!changed) {
   if (!files.atomic_json(ACTIVE, { ...previous, commit })) die("rule_data_accept_failed");
   discard(work); return record(true, null, commit);
  }
  if (before != storage.sha256(CONFIG) || core_pid != gateway.process_state().pid ||
   sprintf("%J", initial_selectors) != sprintf("%J", selectors()) ||
   gateway.readiness()?.result?.ready != true) die("rule_data_precondition_changed");
  if (!files.atomic_json(PENDING, { config, sets: initial_sets, selectors: initial_selectors, candidate: work, previous_sha256: before, candidate_sha256: storage.sha256(candidate_path) })) die("rule_data_journal_failed");
  if (!files.atomic_json(CONFIG, candidate) || !reload() || !restore_selectors(initial_selectors) || !apply_sets(requested_sets, false)) die("rule_data_apply_failed");
  const observed = controller_rules()?.providers;
  for (let id in keys(generation.rules)) if (!(observed?.[id]?.ruleCount > 0)) die("rule_data_readback_failed");
  if (sets() == null || gateway.readiness()?.result?.ready != true) die("rule_data_readback_failed");
  if (probes(policy)?.ok != true) die("rule_data_protected_probe_failed");
  if (!files.atomic_json(ACTIVE, generation)) die("rule_data_accept_failed");
  fs.unlink(PENDING);
  if (previous != null) discard(previous.directory);
  return record(true, null, commit);
 } catch (error) {
  const rollback = recover();
  if (rollback.ok && read(ACTIVE)?.directory != work) discard(work);
  return record(false, rollback.ok ? error.message : rollback.error, null);
 }
}
return { status, project, active_sets, refresh, recover, cidrs, batch };
};
