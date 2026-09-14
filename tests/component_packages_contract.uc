import { changes, validate } from '../plugins/components/lib/packages.uc';
function check(value, message) { if (!value) die(message); }
function rejects(action, code) {
	let actual; try { action(); } catch (error) { actual = error.message; }
	check(actual == code, 'expected ' + code + ', got ' + actual);
}
const name = 'opl-netfleet-plugin-example';
const request = { action: 'install', name, version: '1.1.0', before_version: null, confirm: true };
const installed = { 'opl-netfleet': '1.0.0', libc: '1.0' }, product = ['opl-netfleet-plugin-components'];
const output = '(1/2) Installing helper (1.0)\n(2/2) Installing ' + name + ' (1.1.0)\nOK: 2 packages';
const result = validate(changes(output), request, installed, product);
check(length(result.names) == 2 && result.candidates.helper == '1.0', 'missing dependencies join the exact transaction');
rejects(() => validate(changes(output), { ...request, confirm: false }, installed, product), 'invalid_plugin_package_request');
rejects(() => validate(changes(output), request, { ...installed, [name]: '1.0.0' }, product), 'installed_version_changed');
rejects(() => validate(changes('(1/2) Upgrading libc (1.0 -> 2.0)\n' + output), request, installed, product), 'plugin_dependency_change_required');
rejects(() => validate(changes(output), { ...request, name: product[0] }, installed, product), 'plugin_package_protected');
rejects(() => changes('(1/1) Changing example unexpectedly'), 'package_plan_unreadable');
const update = { ...request, action: 'update', before_version: '1.0.0' };
check(validate(changes('(1/1) Upgrading ' + name + ' (1.0.0 -> 1.1.0)'), update, { [name]: '1.0.0' }, []).candidates[name] == '1.1.0', 'exact update');
rejects(() => validate(changes('(1/1) Downgrading ' + name + ' (2.0.0 -> 1.1.0)'), { ...update, before_version: '2.0.0' }, { [name]: '2.0.0' }, []), 'candidate_changed');
const remove = { ...request, action: 'remove', before_version: '1.1.0' };
check(validate(changes('(1/1) Purging ' + name + ' (1.1.0)'), remove, { [name]: '1.1.0' }, []).candidates[name] == null, 'remove exact plugin');
rejects(() => validate(changes('(1/2) Purging downstream (1.0)\n(2/2) Purging ' + name + ' (1.1.0)'), remove, { [name]: '1.1.0' }, []), 'plugin_package_required');
print('component_packages_contract_ok\n');
