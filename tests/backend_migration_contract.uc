import { migrate_object, migrate_sections, profile_path, public_plan } from "../openwrt/files/usr/libexec/opl-netfleet/core/backend_migration.uc";

function check(value, label) { if (!value) die(label); };
const old = "/etc/nikki";
const native = "/etc/opl-netfleet/native";
check(profile_path("subscription:alpha", native) == `${native}/subscriptions/alpha.yaml`, "subscription stable ref");
check(profile_path("file:recovery.json", native) == `${native}/profiles/recovery.json`, "file stable ref");
for (let ref in ["file:../escape", "file:/escape", "file:OPL-NetFleet.json", "subscription:bad/name", "file:opl-netfleet/mvp.json"])
	check(profile_path(ref, native) == null, "derived or escaped profile rejected");
const profile = {
	"proxy-providers": { alpha: { type: "file", path: `${old}/subscriptions/alpha.yaml` } },
	"rule-providers": { rules: { type: "file", path: "rulesets/example.mrs" } },
	"nikki-rules": ["DOMAIN,private.example,DIRECT"],
	dns: { nameserver: ["https://resolver.example/dns-query"] },
	"external-ui": `${old}/run/ui`
};
const migrated = migrate_object(profile);
check(migrated["proxy-providers"].alpha.path == `${native}/subscriptions/alpha.yaml`, "owned paths rewritten");
check(migrated["rule-providers"].rules.path == "rulesets/example.mrs", "relative core paths preserved");
check(migrated["netfleet-rules"][0] == profile["nikki-rules"][0] && migrated["nikki-rules"] == null, "private mixin rule order retained");
check(sprintf("%J", migrated.dns) == sprintf("%J", profile.dns), "DNS untouched");
check(profile["external-ui"] == `${old}/run/ui`, "source object is not mutated");
for (let path in [`${old}/unknown/data`, `${old}/run/../../escape`, `${old}/run/config.yaml`, `prefix:${old}/run/ui`]) {
	let rejected = false;
	try { migrate_object({ path: path }); } catch (error) { rejected = true; }
	check(rejected, "unknown or generated old path rejected");
}
const sections = [
	{ ".name": "config", ".type": "config", profile: "file:OPL-NetFleet.json", enabled: "1" },
	{ ".name": "mixin", ".type": "mixin", api_secret: "secret-is-private", tun_enabled: "0", ui_path: "ui" },
	{ ".name": "proxy", ".type": "proxy", tcp_mode: "tproxy", udp_mode: "tproxy", lan_inbound_interface: ["lan"] },
	{ ".name": "routing", ".type": "routing", cgroup_name: "nikki", dummy_device: "nikki-dummy", tproxy_route_table: "80" },
	{ ".name": "alpha", ".type": "subscription", url: "https://example.test/sub?private=token", name: "private-name" },
	{ ".name": "cfg0001", ".type": "nameserver", type: "default-nameserver", nameserver: ["192.0.2.1"] }
];
const result = migrate_sections(sections, "subscription:alpha");
check(result.ok, "supported full UCI imports");
check(result.sections[0].options.profile == "subscription:alpha", "starts recovery not compiled artifact");
check(result.sections[1].options.api_secret == "secret-is-private", "controller authentication preserved privately");
check(result.sections[3].options.cgroup_name == "opl-netfleet-core" && result.sections[3].options.dummy_device == "netfleet-dummy", "new owner identities");
check(result.sections[3].options.tproxy_route_table == "80", "routing semantics preserved");
check(result.sections[4].options.url == sections[4].url, "subscription credential preserved privately");
check(result.sections[5].options.nameserver[0] == "192.0.2.1", "upstream DNS preserved");
const tun = map(sections, (value) => ({ ...value }));
tun[1].tun_enabled = "1";
check(!migrate_sections(tun, "subscription:alpha").ok, "TUN rejected not silently disabled");
const redirect = map(sections, (value) => ({ ...value }));
redirect[2].tcp_mode = "redirect";
check(!migrate_sections(redirect, "subscription:alpha").ok, "redirect rejected not silently converted");
const exposed = sprintf("%J", public_plan({ ready: true, revision: "digest", sections: result.sections, profiles: profile, resources: profile,
	subscription_count: 1, profile_count: 1, private_mixin: true, dashboard: true, policy_valid: true }));
for (let private_value in ["secret-is-private", "private-name", "private=token", "private.example", "192.0.2.1"])
	check(index(exposed, private_value) < 0, "migration preview redaction");
print("backend_migration_contract_ok\n");
