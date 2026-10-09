import * as fs from 'fs';
import { execute } from './kernel/host.uc';
import { create } from './adapters/macos.uc';
import { set_executor, invoke } from './bridge.uc';

const root = sourcepath(0, true);
const adapter = create(root);
set_executor(argv => execute(argv, root, { adapter }));
// Read commands share the lock.  Writes still use the exclusive mutation lock,
// while status/diagnostic calls no longer serialize behind one another at the
// process boundary.  Reserved plugin reads are classified by the kernel again
// after inspecting the manifest, so this list only selects the outer lock mode.
const READ_ONLY_COMMANDS = {
	"status": true, "events": true, "config-get": true, "config-validate": true,
	"network-get": true, "network-validate": true, "maintenance-get": true,
	"profile-get": true, "backup-export": true, "diagnostics-get": true,
	"dashboard-get": true, "components-get": true, "components-plugin-plan": true,
	"components-operation": true, "plugins-list": true, "plugins-system-get": true,
	"plugins-system-validate": true, "plugin-read": true, "plugin-package-ready": true,
	"probe": true, "native-gateway-preview": true, "native-gateway-status": true,
	"migration-get": true, "native-setup-get": true, "subscriptions-get": true,
	"onboarding-get": true, "desktop-discover": true, "desktop-sources": true,
	"compatibility-get": true, "public-ca": true
};
// One actual flock covers command entry, all recursive owner calls and readback.
const lock = adapter.network_lock(adapter.paths.network_lock, READ_ONLY_COMMANDS[ARGV[0]] == true ? false : true);
if (lock == null) { printf('%J\n', { ok: false, error: 'mutation_busy' }); exit(1); }
const result = invoke(ARGV);
lock.close();
if (result != null) printf('%J\n', result);
if (result?.ok == false) exit(1);
