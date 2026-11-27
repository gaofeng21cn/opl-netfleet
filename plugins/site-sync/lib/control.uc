import * as fs from "fs";

import { counter, default_site_name, project, selected_sources } from "./projection.uc";

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
	const parent_dir = "/etc/opl-netfleet";
	const base = parent_dir + "/site-sync";
	const runtime = "/var/run/opl-netfleet-site-sync";
	const config_file = base + "/config.json";
	const state_file = base + "/applied.json";
	const device_file = base + "/device-id";
	const receipt_file = runtime + "/receipt.json";
	const network_lock = "/var/lock/opl-netfleet-deploy.lock";

	function valid_origin(origin) {
		return type(origin) == "string" && length(origin) <= 253 &&
			match(origin, /^https:\/\/[A-Za-z0-9.-]+(:[0-9]{1,5})?$/) != null;
	}

	function device_hostname() {
		return default_site_name(fs.readfile("/proc/sys/kernel/hostname"));
	}

	function ensure_private_base() {
		if (fs.lstat(parent_dir) == null) {
			if (!fs.mkdir(parent_dir, 0700)) return false;
			fs.chmod(parent_dir, 0700);
		}
		if (fs.lstat(base) == null) {
			if (!fs.mkdir(base, 0700)) return false;
			fs.chmod(base, 0700);
		}
		return files.private_directory(base);
	}

	function ensure_device_id() {
		if (!ensure_private_base()) return null;
		if (files.private_file(device_file)) {
			const existing = trim(fs.readfile(device_file) ?? "");
			if (match(existing, /^[A-Za-z0-9_-]{8,64}$/)) return existing;
		}
		const seed = storage.sha256_text(
			sprintf("%s:%d:%s", device_hostname(), int(time()), fs.readfile("/proc/sys/kernel/random/uuid") ?? "")
		);
		const id = "dev-" + substr(seed ?? sprintf("%016x", int(time())), 0, 24);
		return files.write_private(device_file, id) ? id : null;
	}

	function configuration() {
		if (!files.private_directory(base) || !files.private_file(config_file) || fs.stat(config_file).size > 16384) return null;
		const config = storage.read_json(config_file);
		if (config?.enabled != true || !valid_origin(config.origin) ||
			type(config.token) != "string" || !match(config.token, /^[A-Za-z0-9_-]{43}$/) ||
			type(config.site_id) != "string" || !match(config.site_id, /^[a-z][a-z0-9-]{1,47}$/) ||
			(config.sections != null && type(config.sections) != "object")) return null;
		return config;
	}

	function http_request(origin, path, body, bearer) {
		const scratch = fs.mkdtemp("/tmp/netfleet-site-sync.XXXXXX");
		if (scratch == null) return { status_code: 0, payload: null };
		fs.chmod(scratch, 0700);
		const input = scratch + "/request.json", output = scratch + "/response.json";
		let status_code = 0, payload = null;
		try {
			if (body != null && !files.write_private(input, sprintf("%J", body))) die("sync_request_write_failed");
			const options = (bearer ? 'header = "Authorization: Bearer ' + bearer + '"\n' : "") +
				(body == null ? "" : 'data-binary = "@' + input + '"\nheader = "Content-Type: application/json"\n');
			const result = process.capture("curl -q --config - --silent --proto '=https' --noproxy '*' " +
				"--connect-timeout 6 --max-time 15 --max-filesize 65536 --output " + q(output) +
				" --write-out '%{http_code}' " + q(origin + path), 18, options);
			status_code = int(result.output ?? "0");
			if (result.status == 0 && (fs.stat(output)?.size ?? 65537) <= 65536) {
				payload = storage.read_json(output);
			}
		} catch (error) {}
		fs.unlink(input); fs.unlink(output); fs.rmdir(scratch);
		return { status_code, payload };
	}

	function request(config, path, body) {
		const res = http_request(config.origin, path, body, config.token);
		return res.status_code == 200 ? res.payload : null;
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
		const sources = selected_sources(result, revision, config.sections ?? {}, config.auto_sections == true);
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

	function action_status() {
		const config = configuration();
		const applied = read(state_file);
		const receipt = read(receipt_file);
		if (config == null) {
			return {
				ok: true,
				result: {
					connected: false,
					hostname: device_hostname(),
				},
			};
		}
		return {
			ok: true,
			result: {
				connected: true,
				origin: config.origin,
				site_id: config.site_id,
				name: config.name ?? config.site_id,
				hostname: device_hostname(),
				auto_sections: config.auto_sections == true,
				applied_revision: applied?.site_id == config.site_id && applied?.origin == config.origin ? (applied.revision ?? 0) : 0,
				desired_revision: receipt?.desired_revision ?? null,
				last_attempted_at: receipt?.attempted_at ?? null,
				last_ok: receipt?.ok ?? null,
				last_error: receipt?.error ?? null,
			},
		};
	}

	function enroll_device(params) {
		if (type(params) != "object") return { ok: false, error: "invalid_enroll_params" };
		const origin = trim(params.origin ?? "");
		const email = trim(params.email ?? "");
		const password = type(params.password) == "string" ? params.password : "";
		const site_name = trim(params.name ?? "") || device_hostname();
		const site_id = trim(params.site_id ?? "");
		if (!valid_origin(origin)) return { ok: false, error: "invalid_cloud_origin" };
		if (!length(email) || length(email) > 254 || !length(password) || length(password) > 512)
			return { ok: false, error: "credentials_required" };
		if (length(site_name) > 120 || match(site_name, /[[:cntrl:]]/))
			return { ok: false, error: "invalid_site_name" };
		if (length(site_id) > 0 && !match(site_id, /^[a-z][a-z0-9-]{1,47}$/))
			return { ok: false, error: "invalid_site_id" };
		const dev_id = ensure_device_id();
		if (dev_id == null) return { ok: false, error: "unsafe_sync_storage" };

		const existing = configuration();
		const body = { email, password, name: site_name, device_id: dev_id };
		if (length(site_id) > 0) body.site_id = site_id;

		const reply = http_request(origin, "/api/v1/agent/enroll", body, null);
		if (reply.status_code == 0) return { ok: false, error: "cloud_unreachable" };
		if (reply.status_code == 401) return { ok: false, error: "enroll_unauthorized" };
		if (reply.status_code == 409) return { ok: false, error: reply.payload?.error ?? "site_conflict" };
		const data = reply.payload;
		if (reply.status_code != 200 || data?.ok != true ||
			type(data.site_id) != "string" || !match(data.site_id, /^[a-z][a-z0-9-]{1,47}$/) ||
			type(data.device_token) != "string" || !match(data.device_token, /^[A-Za-z0-9_-]{43}$/)) {
			return { ok: false, error: data?.error ?? "enroll_rejected" };
		}

		const next = {
			enabled: true,
			origin,
			site_id: data.site_id,
			name: type(data.name) == "string" && length(trim(data.name)) ? trim(data.name) : site_name,
			device_id: dev_id,
			token: data.device_token,
			auto_sections: true,
			sections: existing?.site_id == data.site_id && existing?.origin == origin && type(existing?.sections) == "object"
				? existing.sections : {},
		};
		if (!files.atomic_json(config_file, next)) return { ok: false, error: "config_write_failed" };
		system("(ucode " + q(main) + " site-sync-heartbeat </dev/null >/dev/null 2>&1) &");
		return {
			ok: true,
			result: {
				connected: true,
				origin,
				site_id: next.site_id,
				name: next.name,
				revision: counter(data.revision) ? data.revision : 0,
				enrolled: type(data.enrolled) == "string" ? data.enrolled : "created",
			},
		};
	}

	function action_enroll(params) {
		return enroll_device(params);
	}

	function action_disconnect() {
		const config = configuration();
		if (config != null) {
			try { http_request(config.origin, "/api/v1/agent/unenroll", null, config.token); } catch (error) {}
		}
		fs.unlink(config_file);
		fs.unlink(state_file);
		fs.unlink(receipt_file);
		return { ok: true, result: { connected: false } };
	}

	function action_sync_now() {
		const hb = command_heartbeat(["site-sync-heartbeat"]);
		const st = action_status();
		if (hb?.ok != true) return { ok: false, error: hb?.error ?? "site_sync_failed" };
		return st;
	}

	function command_status() {
		return action_status();
	}

	function command_enroll() {
		let raw = "";
		for (let chunk = fs.stdin.read(4096); length(chunk) > 0; chunk = fs.stdin.read(4096)) {
			raw += chunk;
			if (length(raw) > 8192) return { ok: false, error: "enroll_input_too_large" };
		}
		let parsed = null;
		try { parsed = json(raw); } catch (error) {}
		if (type(parsed) != "object") return { ok: false, error: "invalid_enroll_json" };
		return enroll_device(parsed);
	}

	function command_disconnect() {
		return action_disconnect();
	}

	function schedule(state) {
		const now = int(time());
		if (now < (state.next_at ?? 0) || configuration() == null) return;
		state.next_at = now + 60;
		system("(ucode " + q(main) + " site-sync-heartbeat scheduled </dev/null >/dev/null 2>&1) &");
	}

	return {
		command_heartbeat,
		command_apply,
		command_status,
		command_enroll,
		command_disconnect,
		action_status,
		action_enroll,
		action_disconnect,
		action_sync_now,
		schedule,
	};
};
