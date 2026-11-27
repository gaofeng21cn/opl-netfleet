#!/usr/bin/ucode

import { default_site_name, project, selected_sources } from "../plugins/site-sync/lib/projection.uc";

function check(value, message) {
	if (!value) die(message);
}

check(default_site_name("router-edge\n") == "router-edge", "default site name trims newline");
check(default_site_name("   \n") == "OpenWrt", "default site name falls back on empty hostname");

const digest = value => sprintf("%064x", length(value));
const status = {
	operating_mode: "netfleet",
	capabilities: [{
		id: "cap-a",
		enabled: true,
		region_id: "region-a",
		provider_id: "provider-a",
		leaf: "private-node-name",
		selected_group: "group-a",
		preferred_group: "group-a",
		preferred_leaf: "private-node-name",
		reason: {
			kind: "automatic_decision",
			selected_group: "group-a",
			preferred_group: "group-a",
			leaf: "private-node-name",
			preferred_leaf: "private-node-name",
			delay_ms: 123
		}
	}],
	providers: [{ id: "provider-a", quota: { remaining_bytes: 100, total_bytes: 200 } }],
	recovery: false
};

const body = project("site-a", 4, status, { upload_bytes: 1000, download_bytes: 2000 }, null, 1000, digest, "updated");
check(body.site_id == "site-a" && body.applied_revision == 4 && body.mode == "netfleet", "projection identity failed");
check(body.capabilities[0].node == "node-000000000000" && body.capabilities[0].rtt_ms == 123, "projection summary failed");
check(body.traffic.upload_bytes == 1000 && body.traffic.download_bytes == 2000, "traffic projection failed");
check(body.quotas[0].provider == "provider-a" && body.quotas[0].remaining_bytes == 100, "quota projection failed");
check(index(sprintf("%J", body), "private-node-name") < 0, "projection leaked node identity");

const selected = selected_sources({
	revision: 8,
	subscriptions: [
		{ id: "provider-a", name: "Provider A", url: "https://provider.example.invalid/a" },
		{ id: "provider-b", name: "Provider B", url: "https://provider.example.invalid/b" }
	]
}, 8, { "provider-a": "source_a", "provider-b": "source_b" });
check(length(selected) == 2 && selected[0].id == "source_a" && selected[1].id == "source_b", "authorized source mapping failed");

const auto_selected = selected_sources({
	revision: 9,
	subscriptions: [
		{ id: "provider-a", name: "Provider A", url: "https://provider.example.invalid/a" },
		{ id: "provider-b", name: "Provider B", url: "https://provider.example.invalid/b" }
	]
}, 9, {}, true);
check(length(auto_selected) == 2 && auto_selected[0].id == "provider_a" && auto_selected[1].id == "provider_b", "auto section derivation failed");

check(selected_sources({
	revision: 9,
	subscriptions: [
		{ id: "a-b", name: "Sub 1", url: "https://provider.example.invalid/1" },
		{ id: "a_b", name: "Sub 2", url: "https://provider.example.invalid/2" }
	]
}, 9, {}, true) == null, "colliding normalized auto sections accepted");

check(selected_sources({ revision: 7, subscriptions: [] }, 8, {}) == null, "stale revision accepted");
check(selected_sources({ revision: 8, subscriptions: [] }, 8, {}) == null, "empty source set accepted");
check(selected_sources({ revision: 8, subscriptions: [{ id: "provider-a", name: "Provider A", url: "http://insecure.example.invalid/a" }] }, 8,
	{ "provider-a": "source_a" }) == null, "insecure source accepted");
check(selected_sources({ revision: 8, subscriptions: [{ id: "provider-a", name: "Provider A", url: "https://provider.example.invalid/a" }] }, 8, {}) == null,
	"unmapped source accepted");
print("site_sync_contract_ok\n");
