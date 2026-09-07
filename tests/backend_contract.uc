import { use, release as release_services } from "./services.uc";
const KIND = use("platform.runtime").KIND;
const UCI_PACKAGE = use("platform.runtime").UCI_PACKAGE;
const ROOT_DIR = use("platform.runtime").ROOT_DIR;
const RUN_DIR = use("platform.runtime").RUN_DIR;
const SERVICE = use("platform.runtime").SERVICE;
const NFT_TABLE = use("platform.runtime").NFT_TABLE;
const STATE_DIR = use("platform.runtime").STATE_DIR;
const LOG_PATH = use("platform.runtime").LOG_PATH;
const metadata = use("platform.runtime").metadata;
const resolve_profile = use("mihomo.backend").resolve_profile;
const provider_runtime_path = use("mihomo.backend").provider_runtime_path;
const ARTIFACT_PATH = use("mihomo.backend").ARTIFACT_PATH;
const MANIFEST_PATH = use("mihomo.backend").MANIFEST_PATH;
const PROFILE_ENTRY_PATH = use("mihomo.backend").PROFILE_ENTRY_PATH;
const COMPILED_PROFILE = use("mihomo.backend").COMPILED_PROFILE;
const resolve_policy_source = use("mihomo.policy-source").resolve;

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

release_services();
