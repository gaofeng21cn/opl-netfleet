#!/usr/bin/ucode
import * as fs from 'fs';
import { use, release as release_services } from './services.uc';
import { create_history } from '../plugins/subscriptions/lib/history.uc';

function test_subscriptions_model() {
	const valid_id = use("models.subscriptions").valid_id;
	const valid_url = use("models.subscriptions").valid_url;
	const desired_source = use("models.subscriptions").desired_source;
	const userinfo = use("models.subscriptions").userinfo;
	const referenced = use("models.subscriptions").referenced;
	const public_source = use("models.subscriptions").public_source;
	const source_identity_input = use("models.subscriptions").source_identity_input;

	function check(value, label) { if (!value) die(label); }
	const source = { id: "Provider_1", name: "Example", url: "https://example.test/sub?token=private", user_agent: "clash.meta", info_url: "", prefer: "remote" };
	function desired(patch, previous) { return desired_source({ revision: "digest", source: { ...source, ...patch } }, previous); }
	check(valid_id("Provider_1") && !valid_id("../provider") && !valid_id("a-b"), "stable policy section ID");
	check(valid_url(source.url) && valid_url("http://example.test/sub"), "Nikki HTTP subscription compatibility");
	for (let url in ["file:///secret", "https://user@example.test/sub", "https://example.test/sub\nheader", "https://example.test/sub#fragment", "https://example.test/sub\u0000x"])
		check(!valid_url(url), "reject unsafe URL");
	check(desired({}, null).ok, "create subscription");
	check(desired({ url: "" }, source).source.url == source.url, "blank URL preserves private credential");
	check(!desired({ url: "" }, null).ok, "new subscription requires URL");
	check(desired({ name: "Renamed" }, source).source_changed == false, "display edit retains cache identity");
	check(desired({ alias: "主账号" }, source).ok && desired({ alias: "主账号" }, source).source.alias == "主账号", "local account alias is accepted");
	check(desired({ alias: "" }, { ...source, alias: "主账号" }).source.alias == "", "empty account alias clears metadata");
	check(desired({ alias: "主账号" }, source).source_changed == false, "account alias retains cache identity");
	check(public_source({ ...source, alias: "主账号" }, {}).display_name == "Example · 主账号", "same provider accounts receive distinct display names");
	check(public_source({ ...source, alias: "主账号" }, {}).alias == "主账号", "account alias is projected without credentials");
	for (let day in [1, 15, 31]) {
		const saved = desired({ quota_reset_day: day }, source);
		check(saved.ok && saved.source.quota_reset_day == day && !saved.source_changed, "valid monthly reset day is metadata only");
		check(sprintf("%J", source_identity_input(saved.source)) == sprintf("%J", source_identity_input(source)), "reset day does not alter cache identity");
	}
	for (let day in [0, 32, -1, 1.5, "13", "", true, []])
		check(desired({ quota_reset_day: day }, source).error == "invalid_quota_reset_day", "reject invalid monthly reset day");
	check(desired({ quota_reset_day: null }, { ...source, quota_reset_day: "15" }).source.quota_reset_day == null, "explicit clear removes manual date");
	check(desired({}, { ...source, quota_reset_day: "15" }).source.quota_reset_day == 15, "unrelated edits retain persisted UCI date");
	check(public_source({ ...source, quota_reset_day: "15" }, {}).quota_reset_day == 15, "editor reads normalized date");
	check(public_source({ ...source, quota_reset_day: "32" }, {}).quota_reset_day == null, "malformed stored date remains unset");
	check(desired({ url: "https://example.test/new" }, source).source_changed, "URL edit changes desired source identity");
	check(desired({ info_url: "https://example.test/quota" }, source).source_changed, "quota source edits also await refresh");
	check(sprintf("%J", source_identity_input(source)) == sprintf("%J", source_identity_input({ ...source, name: "Renamed" })),
		"display name does not change downloaded source identity");
	check(sprintf("%J", source_identity_input(source)) == sprintf("%J", source_identity_input({ ...source, alias: "主账号" })),
		"account alias does not change downloaded source identity");
	check(sprintf("%J", source_identity_input(source)) != sprintf("%J", source_identity_input({ ...source, url: "https://example.test/new" })),
		"new URL remains distinguishable from last accepted cache");
	check(!desired({ user_agent: "foo\r\nURL: bad" }, source).ok, "reject curl configuration injection");
	check(!desired({ unknown: true }, source).ok, "reject unknown input");
	check(desired_source({ revision: "digest", source: { id: "Provider_1" }, delete: true }, source).deleted, "explicit delete");
	const quota = userinfo("HTTP/2 200\r\nSubscription-Userinfo: upload=10; download=20; total=100; expire=0\r\n");
	check(quota.used == 30 && quota.avaliable == 70 && quota.expire == 0, "wire quota projection");
	check(userinfo("HTTP/1.1 302 Found\nsubscription-userinfo: total=100\nHTTP/2 200\ncontent-type: application/yaml\n") == null, "ignore redirect quota");
	check(userinfo("subscription-userinfo: expire=abc; total=100\n").expire == null, "malformed expiry remains unknown");
	check(referenced({ providers: { primary: { section: "Provider_1", enabled: false } } }, "Provider_1"), "disabled provider still references source");
	check(referenced({ recovery_profile: { ref: "subscription:Provider_1" } }, "Provider_1"), "recovery input cannot be removed");
	check(!referenced({ providers: { primary: { section: "other" } } }, "Provider_1"), "unreferenced source can be removed");
	const output = public_source({ ...source, last_attempt: "20", last_success: "10", last_result: "failed", last_error: "subscription_download_failed" }, { present: true, digest: "digest", node_count: 3 });
	check(output.last_success == 10 && output.last_attempt == 20 && output.cache_present, "failed update retains success and cache");
	check(index(sprintf("%J", output), source.url) < 0 && output.has_url, "credentials never projected");
	const pending = public_source({ ...source, last_success: "10", last_result: "pending", total: "100 B" },
		{ present: true, current: false, digest: "old-digest", node_count: 3 });
	check(pending.pending_update && pending.using_previous_cache && !pending.cache_current && pending.cache_present &&
		pending.last_success == 10 && pending.quota.total == "100 B", "source edit projects retained last good cache and quota");
	const pending_failure = public_source({ ...source, last_success: "10", last_attempt: "30", last_result: "failed" },
		{ present: true, current: false, digest: "old-digest", node_count: 3 });
	check(pending_failure.pending_update && pending_failure.using_previous_cache && pending_failure.last_success == 10,
		"failed new source leaves pending and last good cache");
	const current = public_source({ ...source, last_success: "40", last_result: "unchanged" },
		{ present: true, current: true, digest: "old-digest", node_count: 3 });
	check(current.cache_current && !current.pending_update && !current.using_previous_cache,
		"accepted new URL with identical bytes is current");
	check(public_source(source, { present: false }).pending_update, "new source needs explicit refresh");

	const shared_model = use("models.subscriptions");
	const normalized = shared_model.normalize_sources({ source_a: { name: "Source", url: "https://example.invalid/subscription" } }, {}, {});
	assert(normalized.ok && normalized.sources.source_a.user_agent == "clash.meta");
	assert(!shared_model.normalize_sources({ source_a: { name: "Source", url: "https://user:secret@example.invalid/subscription" } }, {}, {}).ok);
	assert(!shared_model.normalize_sources({ source_a: { name: "Source", imported: true } }, {}, {}).ok);
	assert(shared_model.normalize_sources({ source_a: { name: "Source" } }, {}, { source_a: true }).ok);
	const quota_wire = shared_model.userinfo("Subscription-Userinfo: upload=2; download=3; total=9");
	assert(shared_model.quota_state({ total: quota_wire.total, used: quota_wire.used }).remaining_bytes == 4);
	assert(shared_model.quota_state({ total: 9 }).state == "unknown");
	assert(shared_model.quota_state({ available: 0 }).state == "exhausted");
	assert(shared_model.quota_state({ total: 0, used: 0 }).state == "exhausted");
	assert(shared_model.quota_state({ available: -1, total: 9, used: 2 }).state == "exhausted");
	assert(shared_model.quota_state({ total: 9, used: 2, reset_day: "15" }).reset_day_source == "manual");
	const managed = shared_model.normalize_sources({ source_a: {
		name: "Source", alias: "主账号", url: "https://example.invalid/subscription",
		user_agent: "mihomo", info_url: "https://example.invalid/quota", quota_reset_day: 15,
	} }, {}, {});
	assert(managed.ok && managed.sources.source_a.alias == "主账号" &&
		managed.sources.source_a.info_url == "https://example.invalid/quota" &&
		managed.sources.source_a.quota_reset_day == 15 &&
		managed.sources.source_a.user_agent == "mihomo", "shared source normalization preserves metadata");
	print("subscriptions_contract_ok\n");
}

function test_subscription_lifecycle_model() {
	const enabled_sections = use("models.subscription").enabled_sections;
	const referenced_sections = use("models.subscription").referenced_sections;
	const quota_config = use("models.subscription").quota_config;
	const cache_accepted = use("models.subscription").cache_accepted;
	const evaluate_entry = use("models.subscription").evaluate_entry;
	const summarize = use("models.subscription").summarize;
	const public_results = use("models.subscription").public_results;
	const unavailable_results = use("models.subscription").unavailable_results;
	const project = use("models.subscription").project;
	const history_update = use("models.subscription").history_update;
	function history(events) {
		let state = null;
		for (let event in events) state = history_update(state, event, true);
		return state;
	}

	const policy = {
		providers: {
			zeta: { section: "zeta", enabled: false, quota: { available_field: "available" } },
			beta: { section: "beta", enabled: true, quota: { available_field: "available" } },
			alpha: { section: "alpha", enabled: true, quota: { used_field: "used" } },
			alpha_alias: { section: "alpha", enabled: true }
		}
	};

	if (join(",", enabled_sections(policy)) != "alpha,beta" ||
		quota_config(policy, "alpha")?.used_field != "used" ||
		quota_config(policy, "beta")?.available_field != "available" ||
		quota_config(policy, "zeta") != null) {
		die("enabled_sections_failed");
	}

	policy.policy_source = { kind: "profile", ref: "subscription:zeta" };
	policy.recovery_profile = { ref: "subscription:recovery" };
	if (join(",", referenced_sections(policy, "subscription:current")) != "alpha,beta,zeta,recovery,current" ||
		join(",", referenced_sections(policy, "subscription:alpha")) != "alpha,beta,zeta,recovery" ||
		join(",", referenced_sections(null, "subscription:current")) != "current" ||
		length(referenced_sections(null, "file:current")) != 0 ||
		length(referenced_sections({ policy_source: { kind: "bundle", ref: "subscription:other" },
			recovery_profile: { ref: "file:recovery" } }, null)) != 0) {
		die("referenced_sections_failed");
	}

	if (cache_accepted({ proxies: [{ name: "node-a" }] }) != true ||
		cache_accepted({ proxies: [] }) != false ||
		cache_accepted({}) != false ||
		cache_accepted(null) != false ||
		cache_accepted("") != false ||
		cache_accepted([]) != false) {
		die("cache_accepted_failed");
	}

	const previous = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
	const next = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
	const valid = { proxies: [{ name: "node-a" }] };
	const success = evaluate_entry({ section: "alpha", updated: true, previous_digest: previous, digest: next, parsed: valid });
	const unchanged = evaluate_entry({ section: "alpha", updated: true, previous_digest: previous, digest: previous, parsed: valid });
	const download_failed = evaluate_entry({ section: "beta", updated: false, previous_digest: previous, digest: previous, parsed: valid });
	const malformed = evaluate_entry({ section: "beta", updated: true, previous_digest: previous, digest: next, parsed: null });
	const empty = evaluate_entry({ section: "beta", updated: true, previous_digest: previous, digest: next, parsed: { proxies: [] } });

	if (success.result != "updated" || success.restore != false || success.changed != true ||
		unchanged.result != "unchanged" || unchanged.restore != false || unchanged.changed != false ||
		download_failed.result != "failed" || download_failed.restore != true ||
		download_failed.digest != previous ||
		malformed.result != "failed" || malformed.restore != true || malformed.digest != previous ||
		empty.result != "failed" || empty.restore != true || empty.digest != previous) {
		die("evaluate_entry_failed");
	}

	const mixed = summarize([success, download_failed]);
	const all_unchanged = summarize([unchanged]);
	const all_failed = summarize([malformed, empty]);
	if (mixed.changed_count != 1 || mixed.failed_count != 1 || mixed.ok != false ||
		mixed.cache_reason != "partially_updated" || mixed.active_reason != "partially_updated" ||
		all_unchanged.cache_reason != "unchanged" || all_unchanged.ok != true ||
		all_failed.changed_count != 0 || all_failed.failed_count != 2 ||
		all_failed.cache_reason != "update_failed") {
		die("summarize_failed");
	}

	const retained = public_results([success, download_failed]);
	if (length(retained) != 2 || retained[0].section != "alpha" || retained[0].result != "updated" ||
		retained[0].digest != next || retained[1].section != "beta" || retained[1].result != "failed" ||
		retained[1].digest != previous || retained[0].parsed != null || retained[0].url != null) {
		die("public_results_failed");
	}

	const facts = [
		{
			section: "alpha", ref: "subscription:alpha", display_name: "Alpha", present: true, digest: previous,
			valid: true, node_count: 4, updated_at: 1699999800,
			quota: { state: "available", remaining_bytes: 1024, expires_at: "2026-12-31" },
			url: "https://secret.invalid/token", token: "secret-token", parsed: valid
		},
		{
			section: "beta", ref: "subscription:beta", display_name: "Beta", present: true, digest: previous,
			valid: true, node_count: 2, updated_at: 1699999700, quota: { state: "unknown" }
		}
	];
	const projected = project({
		subscription_refresh_enabled: true,
		subscription_refresh_interval_seconds: 43200
	}, facts, history([{
		at: 1699999900, action: "refresh", reason: "updated", ok: true, changed_count: 1, failed_count: 0,
		reloaded: false, initiator: "cli",
		subscriptions: [{ section: "alpha", result: "updated", digest: previous }, { section: "beta", result: "unchanged", digest: previous }]
	}, {
		at: 1700000000, action: "refresh", reason: "partially_updated", ok: false, changed_count: 1, failed_count: 1,
		reloaded: false, initiator: "luci",
		subscriptions: [{ section: "alpha", result: "updated", digest: next }, { section: "beta", result: "failed", digest: previous }]
	}]));
	const encoded = sprintf("%J", projected);
	if (projected.provider_count != 2 || projected.last_result != "partially_updated" ||
		projected.subscriptions[0].section != "alpha" || projected.subscriptions[0].ref != "subscription:alpha" ||
		projected.subscriptions[0].display_name != "Alpha" || projected.subscriptions[0].cache_present != true ||
		projected.subscriptions[0].cache_sha256 != previous || projected.subscriptions[0].node_count != 4 ||
		projected.subscriptions[0].quota.remaining_bytes != 1024 || projected.subscriptions[0].quota.expires_at != "2026-12-31" ||
		projected.subscriptions[0].last_attempt != 1700000000 || projected.subscriptions[0].last_success != 1700000000 ||
		projected.subscriptions[0].last_result != "updated" || projected.subscriptions[1].last_attempt != 1700000000 ||
		projected.subscriptions[1].last_success != 1699999900 || projected.subscriptions[1].last_result != "failed" ||
		projected.subscriptions[0].url != null || projected.subscriptions[0].token != null ||
		projected.subscriptions[0].parsed != null || projected.subscriptions[0].cache != null ||
		projected.subscriptions[0].last_refresh != null ||
		index(encoded, "secret.invalid") >= 0 || index(encoded, "secret-token") >= 0 ||
		index(encoded, "node-a") >= 0 || index(encoded, "last_refresh") >= 0) {
		die("metadata_projection_failed");
	}

	const unavailable = project({
		subscription_refresh_enabled: true,
		subscription_refresh_interval_seconds: 43200
	}, facts, history([{
		at: 1700000100, action: "refresh", reason: "upstream_unavailable", ok: false, changed_count: 0, failed_count: 2,
		reloaded: false, initiator: "supervisor", subscriptions: unavailable_results(["alpha", "beta"])
	}]));
	if (unavailable.last_result != "upstream_unavailable" ||
		unavailable.subscriptions[0].last_result != "failed" ||
		unavailable.subscriptions[0].last_success != 1699999800 ||
		unavailable.subscriptions[1].last_success != 1699999700 ||
		unavailable.subscriptions[1].cache_present != true) {
		die("unavailable_projection_failed");
	}
	print("subscription_contract_ok\n");
}

function test_refresh_history() {
	const plugins_root = fs.realpath(replace(sourcepath(), /[^/]+$/, '../plugins'));
	const workspace = fs.mkdtemp('/tmp/netfleet-refresh-history.XXXXXX');
	const path = `${workspace}/subscription-history.json`;
	const model = use('models.subscription');
	const events = use('events.model');
	let log = { schema_version: 1, events: [] }, assertions = 0;
	function check(ok, message) { if (!ok) die(message); assertions++; }
	const ports = {
		'platform.paths': { SUBSCRIPTION_HISTORY_PATH: path },
		'platform.storage': use('platform.storage'),
		'platform.files': use('platform.files'),
		'events.store': { read_events: () => log },
		'events.model': events,
		'models.subscription': model
	};
	const history_factory = create_history;
	function reopen() { return history_factory({ use: name => ports[name] }); }
	function event(at, ok, reason) {
		return {
			at, action: 'refresh', ok, reason: reason ?? (ok ? 'unchanged' : 'upstream_unavailable'),
			initiator: 'supervisor', subscriptions: [{ section: 'alpha', result: ok ? 'unchanged' : 'failed' }]
		};
	}
	const now = int(time());
	let history = reopen();
	try {
		check(history.read() == null && model.refresh_due_at(history.read(), 86400) == null, 'no trustworthy baseline is due immediately');
		log = events.append(log, [event(now - 172800, true)]);
		check(history.read().subscriptions.alpha.last_success == now - 172800 && history.read().last_success_at == null,
			'legacy evidence preserves known success without inventing full-refresh scope');
		check(history.record(event(now - 86000, true), true), 'actual atomic history write succeeds');
		const filler = [];
		for (let i = 0; i < events.EVENT_LIMIT + 128; i++) push(filler, { at: now, action: 'select', reason: 'fixture' });
		log = events.append(log, filler);
		history = reopen();
		check(length(log.events) == events.EVENT_LIMIT && history.read().last_success_at == now - 86000,
			'reopened owner retains success after all refresh events have rolled out');
		check(model.refresh_due_at(history.read(), 86400) == now + 400, 'restart retains the original daily deadline');
		check(model.refresh_due_at(history.read(), 3600) == now - 82400, 'changed interval uses the same success baseline');
		check(history.record(event(now - 100, false), true), 'failed attempt persists');
		history = reopen();
		check(history.read().last_success_at == now - 86000 && history.read().subscriptions.alpha.last_success == now - 86000,
			'failure does not overwrite global or source success');
		check(model.refresh_due_at(history.read(), 86400) == now + 200, 'failure retry deadline survives restart');
		const rollback = event(now - 50, false, 'rollback_restored');
		rollback.subscriptions[0].result = 'updated';
		check(history.record(rollback, true) && history.read().subscriptions.alpha.last_success == now - 86000,
			'download followed by rollback is not an accepted source update');
		check(history.record(event(now, true), false), 'single-source manual success persists');
		check(history.read().subscriptions.alpha.last_success == now && history.read().last_success_at == now - 86000 &&
			model.refresh_due_at(history.read(), 86400) == now + 850, 'manual source refresh does not postpone the fleet schedule');
		const projection = model.project({ subscription_refresh_enabled: true, subscription_refresh_interval_seconds: 86400 }, [], history.read());
		check(projection.last_success_at == now - 86000 && projection.last_run_at == now - 50 && projection.next_run_at == now + 850,
			'status uses persisted success, attempt, and the same scheduling deadline');

		// Verify exponential failure backoff ladder and per-source due filtering.
		check(model.failure_backoff_seconds(1, 86400) == 300 &&
			model.failure_backoff_seconds(2, 86400) == 900 &&
			model.failure_backoff_seconds(3, 86400) == 3600 &&
			model.failure_backoff_seconds(4, 86400) == 14400 &&
			model.failure_backoff_seconds(5, 86400) == 43200 &&
			model.failure_backoff_seconds(6, 86400) == 43200 &&
			model.failure_backoff_seconds(5, 1800) == 1800,
			'exponential failure backoff ladder respects cap and interval');
		let per_source = model.history_update(null, {
			at: now - 1000, action: 'refresh', ok: false, reason: 'partially_updated',
			subscriptions: [{ section: 'alpha', result: 'updated' }, { section: 'beta', result: 'failed' }]
		}, true);
		per_source = model.history_update(per_source, {
			at: now - 500, action: 'refresh', ok: false, reason: 'update_failed',
			subscriptions: [{ section: 'beta', result: 'failed' }]
		}, true);
		check(join(',', model.due_sections(['alpha', 'beta'], per_source, 86400, now)) == '', 'both healthy and backed-off sections wait');
		check(model.refresh_due_at(per_source, 86400, ['alpha', 'beta']) == now + 400, 'per-section due timestamp tracks earliest retry');
		check(join(',', model.due_sections(['alpha', 'beta'], per_source, 86400, now + 400)) == 'beta',
			'only the backed-off section runs when its retry window expires while healthy source stays idle');

		// Exercise the shipped scheduler through a fresh factory, using persisted owner state.
		let commands = [], locked = false;
		const config = {
			subscription_refresh_enabled: true, subscription_refresh_interval_seconds: 86400,
			enabled: false, selection_interval_seconds: 1800, poll_interval_seconds: 15, runtime_grace_seconds: 45
		};
		ports['subscriptions.facts'] = { read_history: () => reopen().read() };
		ports['platform.documents'] = { load_policy: () => ({ main: { enabled: true } }) };
		ports['platform.profile'] = { current_profile: () => 'active', backend_enabled: () => true };
		ports['platform.credentials'] = { api_secret: () => 'fixture' };
		ports['platform.process'] = { run_owner: (action, trigger) => {
			if (locked) return false;
			push(commands, action);
			if (action == 'refresh') history.record(event(int(time()), true), true);
			return true;
		} };
		ports['mihomo.backend'] = { running: () => true, lan_runtime_state: () => ({ transparent_proxy_ready: true, dns_ready: true }) };
		ports['mihomo.controller'] = { controller_ready: () => true };
		ports['models.policy'] = { automation: () => config, guard_probe_url: () => 'fixture' };
		ports['models.activation'] = { is_active: () => true };
		ports['recovery.state'] = { pending: () => null };
		const scheduler_factory = loadfile(`${plugins_root}/scheduler/lib/control.uc`)();
		function restart_scheduler() { return scheduler_factory({ use: name => ports[name] }).tick(null); }
		restart_scheduler();
		check(length(commands) == 0, 'process restart before persisted deadline does not refresh early');
		history.record(event(now - 90000, true), true);
		locked = true;
		restart_scheduler();
		check(length(commands) == 0 && history.read().last_success_at == now - 90000, 'busy writer does not advance the deadline');
		locked = false;
		restart_scheduler();
		check(join(',', commands) == 'refresh', 'overdue restart invokes the real refresh owner once');
		restart_scheduler();
		check(length(commands) == 1, 'another restart uses the committed completion time');
		history.record(event(now - 90000, true), true);
		history.record(event(now - 600, false), true);
		restart_scheduler();
		check(length(commands) == 2, 'failed full refresh retries after its persisted backoff');

		// Follow the shipped refresh transaction's real early-failure path.
		ports['subscriptions.facts'] = { read_history: history.read, record_history: history.record };
		ports['platform.runtime'] = { KIND: 'native-mihomo' };
		ports['platform.device'] = { upstream_ready: () => false };
		ports['events.operation'] = { begin: () => {}, update: () => {} };
		ports['events.store'].write_events = value => { log = value; return true; };
		ports['events.record'] = loadfile(`${plugins_root}/events/lib/record.uc`)()({ use: name => ports[name] });
		let output;
		ports['events.output'] = { ok: (action, result) => { output = result; }, fail: (action, error) => die(error) };
		const refresh = loadfile(`${plugins_root}/refresh/lib/control.uc`)()({ use: name => ports[name] ?? {} });
		history.record(event(now - 90000, true), true);
		const success_before = history.read().last_success_at;
		refresh.refresh_action({ providers: { alpha: { enabled: true, section: 'alpha' } } }, null, 'scheduled');
		check(output?.state == 'failed' && reopen().read().latest.reason == 'upstream_unavailable' &&
			reopen().read().last_success_at == success_before, 'actual refresh command records failure while preserving accepted update');
		check(model.refresh_due_at(reopen().read(), 86400) == reopen().read().latest.at + 300,
			'failure in the same second as success still uses retry backoff');
		let backed_off_upstream_called = false;
		ports['platform.device'] = { upstream_ready: () => { backed_off_upstream_called = true; return false; } };
		const scheduled_backed_off = loadfile(`${plugins_root}/refresh/lib/control.uc`)()({ use: name => ports[name] ?? {} });
		scheduled_backed_off.refresh_action({ providers: { alpha: { enabled: true, section: 'alpha' } } }, null, 'scheduled');
		check(output?.state == 'not_due' && !backed_off_upstream_called,
			'scheduled refresh skips sections still inside failure backoff');
		ports['platform.device'] = { upstream_ready: () => false };

		// A full disk must not interrupt recovery after a failed rollback.
		let recovered = false;
		ports['platform.paths'].REFRESH_DIR = `${workspace}/snapshot`;
		ports['platform.process'].shell_quote = use('platform.process').shell_quote;
		ports['recovery.control'] = { restore_recovery_with_probes: () => { recovered = true; return { ok: true }; } };
		ports['subscriptions.facts'] = { read_history: () => history.read(), record_history: () => false };
		const failing_writer = loadfile(`${plugins_root}/refresh/lib/control.uc`)()({ use: name => ports[name] ?? {} });
		let write_rejected = false;
		try {
			failing_writer.fail_refresh({ active: false, entries: [], backend_config: {
				backup: `${workspace}/missing-backup`, path: `${workspace}/missing-cache`, digest: ''
			} }, {}, {}, 'scheduled', 'fixture_failure', {});
		} catch (error) { write_rejected = error.message == 'subscription_history_write_failed'; }
		check(recovered && write_rejected, 'history write failure cannot bypass rollback recovery');
		ports['subscriptions.facts'] = { read_history: history.read, record_history: history.record };

		const file = fs.open(path, 'w'); file.write('{broken'); file.close();
		let rejected = false;
		try { history.record(event(now, true), true); } catch (error) { rejected = true; }
		check(rejected && fs.readfile(path) == '{broken', 'unreadable history is not silently erased');
		ports['mihomo.backend'].running = () => false;
		scheduler_factory({ use: name => ports[name] }).tick({ unhealthy_since: now - 600 });
		check(commands[-1] == 'recover', 'unreadable subscription state cannot suppress network recovery');
	} catch (error) {
		fs.unlink(path); fs.unlink(`${path}.tmp`); fs.rmdir(workspace); die(error.message);
	}
	fs.unlink(path); fs.rmdir(workspace);
	printf('refresh history: %d assertions passed\n', assertions);
}

try {
	test_subscriptions_model();
	test_subscription_lifecycle_model();
	test_refresh_history();
} catch (error) {
	release_services();
	die(error.message);
}
release_services();
