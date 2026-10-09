import { manifest, composition } from '../openwrt/files/usr/libexec/opl-netfleet/plugins/components/lib/retained.uc';
function check(value, message) { if (!value) die(message); }
const before = { id: 'mihomo', version: '0.9.10', api_version: 1,
	services: { gateway: { version: 1, module: 'gateway.uc', requires: { storage: 1 } } },
	lifecycle: { drain: { service: 'gateway', method: 'drain' } } };
const after = { ...before, version: '0.9.11', services: {
	...before.services, profile: { version: 1, module: 'profile.uc', requires: {} },
	gateway: { ...before.services.gateway, requires: { storage: 1, profile: 1 } } } };
check(manifest(before, after), 'additive services preserve the existing runtime contract');
check(!manifest(before, { ...after, lifecycle: {} }), 'runtime resources cannot change');
check(!manifest(before, { ...after, services: {} }), 'existing services cannot disappear');
check(!manifest(before, { ...after, services: { gateway: { version: 2, module: 'gateway.uc' } } }), 'service ABI cannot change');
check(!manifest(before, { ...after, services: { gateway: { ...before.services.gateway, requires: {} } } }), 'existing dependencies cannot disappear');
const defaults = { schema: 'opl-netfleet-system.v1', bindings: { gateway: 'mihomo' }, enabled: { mihomo: true, 'https-compat': false }, product_packages: ['mihomo'], scheduler: { service: 'scheduler', method: 'tick' } };
check(composition(defaults, { ...defaults, bindings: { ...defaults.bindings, profile: 'mihomo' } }), 'new bindings can enter the reviewed cohort');
check(!composition(defaults, { ...defaults, enabled: { mihomo: true, 'https-compat': true } }), 'plugin defaults cannot change');
check(!composition(defaults, { ...defaults, bindings: { gateway: 'other' } }), 'existing owners cannot change');
check(!composition(defaults, { ...defaults, product_packages: ['mihomo', 'other'] }), 'package composition cannot change');
print('component_retained_contract_ok\n');
