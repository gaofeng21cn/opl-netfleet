#!/usr/bin/ucode

import { selection_snapshot, validate, MEASUREMENT_MODEL } from "../openwrt/files/usr/libexec/opl-netfleet/core/evidence.uc";

function candidate(group, region, delay, capability) {
	return {
		group: group,
		available: true,
		latency: { status: "ok", delay_ms: delay },
		provider_id: "provider",
		region_id: region,
		role: "primary",
		candidate_id: `node-${group}`,
		capability: capability,
		quota: { state: "unknown" }
	};
};

function decision(group, region, delay, reason, preferred_region) {
	return {
		group: group,
		provider_id: "provider",
		region_id: region,
		candidate_id: `node-${group}`,
		delay_ms: delay,
		layer: "primary",
		changed_region: false,
		reason: reason ?? "fastest_eligible",
		preferred_region: preferred_region ?? null
	};
};

const identity = {
	artifact_sha256: "artifact",
	policy_source_sha256: "source",
	policy_sha256: "policy",
	measurement_model: MEASUREMENT_MODEL,
	measurement_contract: "latency-v1"
};
const standard = [
	candidate("standard-one", "near", 40, "standard"),
	candidate("standard-far", "far", 80, "standard")
];
const first = selection_snapshot(null, standard, "standard",
	decision("standard-one", "near", 40), { ok: true, count: 2 }, identity);
if (first.schema_version != 3 || first.capabilities.standard?.regions?.near?.sample_count != 1 ||
    first.capabilities.standard?.regions?.near?.total_best_delay_ms != 40 ||
	first.capabilities.standard?.providers?.provider?.last_best_delay_ms != 40 ||
	first.capabilities.standard?.providers?.provider?.total_best_delay_ms != 40 ||
	first.capabilities.standard?.providers?.provider?.sample_count != 1 ||
	first.capabilities.standard?.decision?.reason != "fastest_eligible" || !validate(first).ok) {
	print("evidence_first_capability_failed\n");
	exit(1);
}

const ai = [candidate("ai-one", "near", 60, "ai-compatible")];
const second = selection_snapshot(first, ai, "ai-compatible",
	decision("ai-one", "near", 60, "followed_capability_region", "near"),
	{ ok: true, count: 2 }, identity);
if (second.capabilities.standard?.regions?.near?.sample_count != 1 ||
	second.capabilities["ai-compatible"]?.decision?.preferred_region != "near" ||
	second.capabilities["ai-compatible"]?.decision?.reason != "followed_capability_region" ||
	length(second.capabilities["ai-compatible"]?.entries ?? []) != 1 || !validate(second).ok) {
	print("evidence_multi_capability_failed\n");
	exit(1);
}

const third = selection_snapshot(second, [candidate("standard-two", "near", 50, "standard")],
	"standard", decision("standard-two", "near", 50), { ok: true, count: 2 }, identity);
if (third.capabilities.standard?.regions?.near?.last_best_delay_ms != 50 ||
    third.capabilities.standard?.regions?.near?.total_best_delay_ms != 90 ||
	third.capabilities.standard?.regions?.near?.sample_count != 2 ||
	third.capabilities.standard?.providers?.provider?.last_best_delay_ms != 50 ||
	third.capabilities.standard?.providers?.provider?.total_best_delay_ms != 90 ||
	third.capabilities.standard?.providers?.provider?.sample_count != 2 ||
	third.capabilities.standard?.regions?.far != null ||
	third.capabilities["ai-compatible"]?.regions?.near?.sample_count != 1) {
	print("evidence_capability_aggregate_failed\n");
	exit(1);
}

const catalog = [{ region: "near", provider: "provider" }, { region: "far", provider: "provider" }];
const interrupted = selection_snapshot(first, [], "standard", null, { ok: true }, identity, catalog);
if (interrupted.capabilities.standard.regions.far.sample_count != 1 ||
	interrupted.capabilities.standard.regions.far.sampled_at != first.capabilities.standard.regions.far.sampled_at ||
	interrupted.capabilities.standard.providers.provider.sample_count != 1 ||
	length(interrupted.capabilities.standard.entries) != 0) {
	print("transient_candidate_loss_erased_history\n");
	exit(1);
}
const resumed = selection_snapshot(interrupted, [candidate("far-again", "far", 100, "standard")],
	"standard", decision("far-again", "far", 100), { ok: true }, identity, catalog);
const removed = selection_snapshot(resumed, [], "standard", null, { ok: true }, identity,
	[{ region: "near", provider: "other" }]);
if (resumed.capabilities.standard.regions.far.sample_count != 2 ||
	resumed.capabilities.standard.regions.far.total_best_delay_ms != 180 ||
	removed.capabilities.standard.regions.far != null ||
	removed.capabilities.standard.providers.provider != null) {
	print("catalog_history_retention_failed\n");
	exit(1);
}

const invalid_provider_aggregate = json(sprintf("%J", third));
invalid_provider_aggregate.capabilities.standard.providers.provider.sample_count = 0;
if (validate(invalid_provider_aggregate).ok) {
	print("invalid_provider_aggregate_accepted\n");
	exit(1);
}

const legacy_identity = {
	artifact_sha256: "artifact",
	policy_source_sha256: "source",
	policy_sha256: "policy",
	measurement_model: MEASUREMENT_MODEL
};
const legacy_v3 = json(sprintf("%J", third));
legacy_v3.identity = legacy_identity;
const migrated_v3 = selection_snapshot(legacy_v3,
	[candidate("standard-three", "near", 60, "standard")], "standard",
	decision("standard-three", "near", 60), { ok: true, count: 2 }, identity);
if (migrated_v3.capabilities.standard?.providers?.provider?.sample_count != 3 ||
	migrated_v3.capabilities.standard?.providers?.provider?.total_best_delay_ms != 150 ||
	migrated_v3.identity?.measurement_contract != "latency-v1") {
	print("legacy_identity_upgrade_failed\n");
	exit(1);
}

const source_update = selection_snapshot(migrated_v3,
	[candidate("standard-four", "near", 65, "standard")], "standard",
	decision("standard-four", "near", 65), { ok: true, count: 2 }, {
		artifact_sha256: "next",
		policy_source_sha256: "next-source",
		policy_sha256: "next-policy",
		measurement_model: MEASUREMENT_MODEL,
		measurement_contract: "latency-v1"
	});
if (source_update.capabilities.standard?.providers?.provider?.sample_count != 4 ||
	source_update.capabilities.standard?.providers?.provider?.total_best_delay_ms != 215) {
	print("unrelated_source_update_reset_evidence\n");
	exit(1);
}

const reset = selection_snapshot(source_update, [candidate("reset", "near", 70, "standard")],
	"standard", decision("reset", "near", 70), { ok: true, count: 2 }, {
		artifact_sha256: "next",
		policy_source_sha256: "next-source",
		policy_sha256: "next-policy",
		measurement_model: MEASUREMENT_MODEL,
		measurement_contract: "latency-v2"
	});
if (reset.capabilities.standard?.regions?.near?.last_best_delay_ms != 70 ||
    reset.capabilities.standard?.regions?.near?.total_best_delay_ms != 70 ||
    reset.capabilities.standard?.regions?.near?.sample_count != 1 ||
	reset.capabilities.standard?.providers?.provider?.total_best_delay_ms != 70 ||
	reset.capabilities.standard?.providers?.provider?.sample_count != 1 ||
	reset.capabilities["ai-compatible"] != null || !validate(reset).ok) {
	print("evidence_identity_reset_failed\n");
	exit(1);
}

const legacy = {
	schema_version: 2,
	identity: legacy_identity,
	sampled_at: 1,
	decision: decision("legacy", "near", 10),
	entries: [],
	regions: {}
};
legacy.decision.capability = "standard";
const migrated = selection_snapshot(legacy, standard, "standard",
	decision("standard-one", "near", 40), { ok: true, count: 2 }, identity);
if (migrated.schema_version != 3 || migrated.capabilities.standard?.regions?.near?.sample_count != 1 ||
	!validate(legacy).ok || validate({ schema_version: 3, identity: {}, capabilities: {} }).ok) {
	print("evidence_legacy_or_validation_failed\n");
	exit(1);
}

print("evidence_contract_ok\n");
