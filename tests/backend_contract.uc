import { KIND, UCI_PACKAGE, ROOT_DIR, RUN_DIR, SERVICE, NFT_TABLE, STATE_DIR, LOG_PATH, metadata } from "../openwrt/files/usr/libexec/opl-netfleet/adapters/runtime.uc";
import { resolve_profile, provider_runtime_path, ARTIFACT_PATH, MANIFEST_PATH, PROFILE_ENTRY_PATH, COMPILED_PROFILE } from "../openwrt/files/usr/libexec/opl-netfleet/adapters/backend.uc";
import { resolve as resolve_policy_source } from "../openwrt/files/usr/libexec/opl-netfleet/adapters/policy_source.uc";

function check(value, reason) {
	if (!value) { print(`${reason}\n`); exit(1); }
};

const kind = ARGV[0] ?? "nikki-mihomo";
check(index(["nikki-mihomo", "native-mihomo"], kind) >= 0, "invalid_test_backend");
const native = kind == "native-mihomo";
const root = native ? "/etc/opl-netfleet/native" : "/etc/nikki";
const runtime_package = native ? "netfleet" : "nikki";
check(KIND == kind && metadata().id == kind, "backend_identity_mismatch");
check(ROOT_DIR == root && RUN_DIR == `${root}/run`, "backend_directory_mismatch");
check(UCI_PACKAGE == runtime_package && NFT_TABLE == runtime_package && STATE_DIR == `/var/run/${runtime_package}` &&
	LOG_PATH == `/var/log/${runtime_package}/core.log`, "backend_state_owner_mismatch");
check(SERVICE == (native ? "opl-netfleet-core" : "nikki"), "backend_service_mismatch");
check(resolve_profile("subscription:alpha") == `${root}/subscriptions/alpha.yaml`, "subscription_owner_mismatch");
check(resolve_profile("file:recovery.yaml") == `${root}/profiles/recovery.yaml`, "recovery_owner_mismatch");
check(resolve_policy_source({kind: "profile", ref: "subscription:alpha"}) == `${root}/subscriptions/alpha.yaml`,
	"policy_source_owner_mismatch");
check(resolve_policy_source({kind: "bundle", ref: "bundle:base-v1"}) == "/etc/opl-netfleet/policy-sources/base-v1.json",
	"bundle_owner_changed");
check(provider_runtime_path("alpha") == `${root}/run/providers/proxy/netfleet-alpha.yaml`, "provider_owner_mismatch");
check(ARTIFACT_PATH == `${root}/profiles/opl-netfleet/mvp.json` &&
	MANIFEST_PATH == `${root}/profiles/opl-netfleet/mvp.manifest.json` &&
	PROFILE_ENTRY_PATH == `${root}/profiles/OPL-NetFleet.json` && COMPILED_PROFILE == "file:OPL-NetFleet.json",
	"compiled_identity_mismatch");
for (let ref in ["file:../escape", "file:/tmp/escape", "subscription:../alpha", "subscription:alpha/child", "other:alpha"])
	check(resolve_profile(ref) == null, "profile_boundary_not_enforced");
print(`backend_contract ${kind} passed\n`);
