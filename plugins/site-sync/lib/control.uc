import * as fs from "fs";

import { counter, project, selected_sources } from "./projection.uc";

return function(context) {
	const process = context.use("platform.process");
	const q = process.shell_quote;
	const storage = context.use("platform.storage");
	const files = context.use("platform.files");
	const read_events = context.use("events.store").read_events;
	const traffic_totals = context.use("mihomo.controller").traffic_totals;
	const api_secret = context.use("platform.credentials").api_secret;
	const sync_sources = context.use("refresh.control").sync_sources;
	const main = context.root + "/main.uc";
	const base = "/etc/opl-netfleet/site-sync";
	const runtime = "/var/run/opl-netfleet-site-sync";
	const state_file = base + "/applied.json";
	const receipt_file = runtime + "/receipt.json";
	const network_lock = "/var/lock/opl-netfleet-deploy.lock";

	function configuration() {
		const path = base + "/config.json";
		if (!files.private_directory(base) || !files.private_file(path) || fs.stat(path).size > 16384) return null;
		const config = storage.read_json(path);
		if (config?.enabled != true || type(config.origin) != "string" || length(config.origin) > 253 ||
			!match(config.origin, /^https:\/\/[A-Za-z0-9.-]+(:[0-9]{1,5})?$/) ||
			type(config.token) != "string" || !match(config.token, /^[A-Za-z0-9_-]{43}$/) ||
			type(config.site_id) != "string" || !match(config.site_id, /^[a-z][a-z0-9-]{1,47}$/) ||
			type(config.sections) != "object") return null;
		return config;
	}

	function request(config, path, body) {
		const scratch = fs.mkdtemp("/tmp/netfleet-site-sync.XXXXXX");
		if (scratch == null) return null;
		const input = scratch + "/request.json", output = scratch + "/response.json";
		let payload = null;
		try {
			if (body != null && !files.write_private(input, sprintf("%J", body))) die("sync_request_write_failed");
			const options = 'header = "Authorization: Bearer ' + config.token + '"\n' +
				(body == null ? "" : 'data-binary = "@' + input + '"\nheader = "Content-Type: application/json"\n');
			const result = process.capture("curl -q --config - --silent --proto '=https' --noproxy '*' " +
				"--connect-timeout 4 --max-time 8 --max-filesize 65536 --output " + q(output) +
				" --write-out '%{http_code}' " + q(config.origin + path), 10, options);
			if (result.status == 0 && result.output == "200" && (fs.stat(output)?.size ?? 65537) <= 65536)
				payload = storage.read_json(output);
		} catch (error) {}
		fs.unlink(input); fs.unlink(output); fs.rmdir(scratch);
		return payload;
	}

	function read(path) {
		return files.private_file(path) ? storage.read_json(path) : null;
	}

	function run(config, earlier, now) {
		const saved = read(state_file);
		const applied = saved?.site_id == config.site_id && saved.origin == config.origin && counter(saved.revision) ? saved.revision : 0;
		const status = process.capture_json("ucode " + q(main) + " status", 12)?.result;
		if (type(status) != "object") return { ok: false, error: "status_unavailable" };
		const totals = traffic_totals(api_secret(), 2);
		const recent = read_events()?.events;
		const last = type(recent) == "array" && length(recent) ? recent[length(recent) - 1] : null;
		const event = status.recovery != null ? "recovering" : last?.action == "refresh" ?
			(last.ok != true ? "failed" : last.changed_count > 0 ? "updated" : "unchanged") :
			last?.action == "resume" && last.ok == true ? "restored" : null;
		const body = project(config.site_id, applied, status, totals, earlier?.traffic, now,
			value => storage.sha256_text(config.token + ":" + value), event);
		const response = request(config, "/api/v1/agent/heartbeat", body);
		const revision = response?.desired_revision;
		const traffic = { ...(totals ?? {}), at: now };
		if (response?.ok != true || !counter(revision))
			return { ok: false, error: "heartbeat_failed", traffic: traffic };
		if (revision == applied) return { ok: true, desired_revision: revision, traffic: traffic };
		const result = request(config, "/api/v1/agent/subscriptions", null);
		const sources = selected_sources(result, revision, config.sections);
		if (sources == null) return { ok: false, error: "subscription_response_rejected", traffic: traffic };
		const stage = fs.mkdtemp(runtime + "/apply.XXXXXX");
		if (stage == null) return { ok: false, error: "subscription_stage_failed", traffic: traffic };
		const input = stage + "/request.json";
		let applied_ok;
		try {
			applied_ok = files.write_private(input, sprintf("%J", { origin: config.origin, site_id: config.site_id,
				revision: revision, config_digest: storage.sha256_text(sprintf("%J", config)), sources: sources })) &&
				system("flock -n " + q(network_lock) + " ucode " + q(main) + " site-sync-apply " +
					q(input) + " >/dev/null 2>&1") == 0;
		} catch (error) { applied_ok = false; }
		fs.unlink(input); fs.rmdir(stage);
		return applied_ok ? { ok: true, desired_revision: revision, traffic: traffic } :
			{ ok: false, error: "subscription_apply_failed", traffic: traffic };
	}

	function command_heartbeat(argv) {
		const config = configuration();
		if (config == null) return { ok: true, state: "disabled" };
		if (fs.lstat(runtime) == null) fs.mkdir(runtime, 0700);
		if (!files.private_directory(runtime)) return { ok: false, error: "unsafe_sync_state" };
		const lock = fs.open(runtime + "/worker.lock", "ae", 0600);
		if (!lock?.lock("xn")) { lock?.close(); return { ok: true, state: "busy" }; }
		let result;
		try {
			const earlier = read(receipt_file), now = int(time());
			if (argv[1] == "scheduled" && now - (earlier?.attempted_at ?? 0) < 60) {
				result = { ok: true, state: "not_due" };
			} else {
				try { result = run(config, earlier, now); }
				catch (error) { result = { ok: false, error: "site_sync_failed" }; }
				files.atomic_json(receipt_file, { ...result, attempted_at: now });
			}
		} catch (error) { result = { ok: false, error: "site_sync_failed" }; }
		lock.close();
		return { ok: result.ok, error: result.error, state: result.state, desired_revision: result.desired_revision };
	}

	function command_apply(argv) {
		const config = configuration(), path = argv[1];
		if (config == null || type(path) != "string" ||
			!match(path, /^\/var\/run\/opl-netfleet-site-sync\/apply\.[A-Za-z0-9]+\/request\.json$/) ||
			!files.private_file(path) || fs.stat(path).size > 65536) return { ok: false, error: "invalid_sync_stage" };
		const input = read(path);
		if (input?.origin != config.origin || input.site_id != config.site_id || !counter(input.revision) ||
			input.config_digest != storage.sha256_text(sprintf("%J", config))) return { ok: false, error: "sync_config_changed" };
		const result = sync_sources(input.sources);
		if (result?.ok != true) return { ok: false, error: "subscription_apply_failed" };
		return files.atomic_json(state_file, { origin: config.origin, site_id: config.site_id, revision: input.revision }) ?
			{ ok: true } : { ok: false, error: "sync_receipt_failed" };
	}

	function schedule(state) {
		const now = int(time());
		if (now < (state.next_at ?? 0) || configuration() == null) return;
		state.next_at = now + 60;
		system("(ucode " + q(main) + " site-sync-heartbeat scheduled </dev/null >/dev/null 2>&1) &");
	}

	return { command_heartbeat, command_apply, schedule };
};
