import * as fs from 'fs';
const rpc = global.__netfleetDesktopOwner.rpc;
return function(context) {
	const runtime = context.use('platform.runtime');
	const storage = context.use('platform.storage');
	const model = context.use('models.subscriptions');
	const profile_storage = context.use('mihomo.profile-storage');
	const state = getenv('NETFLEET_STATE_DIR'), owner = fs.stat(state).uid;
	// 应用包身份由构建器写入 Resources/build.json；源码运行没有该文件时不伪造身份。
	const app = getenv('NETFLEET_APP_ROOT');
	function private_file(path) { const info = fs.lstat(path); return info?.type == 'file' && info.uid == owner && !(info.mode & 077); }
	function private_directory(path) { const info = fs.lstat(path); return info?.type == 'directory' && info.uid == owner && !(info.mode & 077); }
	function write_private(path, content) {
		if (fs.lstat(path) != null && !private_file(path)) return false;
		const file = fs.open(path, 'w', 0600);
		if (file == null) return false;
		const written = file.write(content); return file.close() && written == length(content) && fs.chmod(path, 0600);
	}
	function atomic_json(path, value) {
		const temporary = `${path}.tmp`;
		if (!write_private(temporary, sprintf('%J', value)) || storage.read_json(temporary) == null) { fs.unlink(temporary); return false; }
		return fs.rename(temporary, path);
	}
	function subscription_exists(id) { return rpc('state.get').subscriptions?.[id] != null; }
	function subscription_display_name(id) { return rpc('state.get').subscriptions?.[id]?.name ?? id; }
	function subscription_options() {
		const sources = rpc('state.get').subscriptions ?? {};
		return map(sort(keys(sources)), id => ({ ref: `subscription:${id}`, display_name: sources[id].name ?? id }));
	}
	function subscription_quota(id) {
		const source = rpc('state.get').subscriptions?.[id];
		// Existing caches retain their last known quota until the next real refresh.
		if (!exists(source ?? {}, 'subscriptionUserinfo')) return source?.quota ?? { state: 'unknown' };
		const values = model.userinfo(`Subscription-Userinfo: ${source.subscriptionUserinfo ?? ''}`);
		let expires_at = null;
		if (values?.expire > 0 && values.expire <= 253402300799) {
			const date = gmtime(values.expire);
			expires_at = sprintf('%04d-%02d-%02dT%02d:%02d:%02d.000Z', date.year, date.mon, date.mday, date.hour, date.min, date.sec);
		}
		return model.quota_state({ available: values?.avaliable, total: values?.total, used: values?.used,
			expires_at, reset_day: source?.quota_reset_day });
	}
	function update_result(id) { return rpc('subscription.update', { id }); }
	function running() { return rpc('core.status').running == true; }
	function cleanup_state() {
		const core = rpc('core.status'), network = rpc('network.status');
		return { ok: core.running == false && network.clean == true, mihomo_stopped: core.running == false,
			service_stopped: core.running == false, network_restored: network.clean == true };
	}
	function stop() { const result = rpc('core.stop'); const readback = cleanup_state(); return { ok: result.ok == true && readback.ok, requested: true, readback }; }
	function lan_runtime_state() {
		const state = rpc('network.status');
		return { scope: 'local-mac', mode: state.mode, transparent_proxy_ready: state.ready == true,
			dns_ready: state.dns_ready == true, dashboard_lan_ready: false, allow_lan: false,
			interception_active: state.mode == 'tun' && state.ready == true };
	}
	return {
		...profile_storage,
		ROOT: state, CONFIG_PATH: `${state}/config.json`, BACKEND_PATH: `${state}/backend.json`, NATIVE_ROOT: `${state}/backend`, NATIVE_STATE_DIR: state,
		NATIVE_MIXIN_PATH: `${state}/backend/mixin.json`, CORE_INIT_PATH: `${state}/core`, SUPERVISOR_INIT_PATH: `${state}/scheduler`, MAIN_PATH: `${getenv('NETFLEET_SOURCE_ROOT') ?? ''}/main.uc`, SYSTEM_PATH: `${state}/system.json`,
		COMPAT_ROOT: `${state}/compat`, COMPAT_CONTROL_PATH: `${state}/compat/control.uc`, COMPAT_EXTENSION_PATH: `${state}/compat/extension.json`, COMPAT_LAUNCHER_PATH: `${state}/compat/launcher`, COMPAT_PORT_RANGE_PATH: `${state}/compat/port-range`, COMPAT_STATE_PATH: `${state}/compat/state.json`,
		PACKAGE_TRANSACTIONS: `${state}/package-transactions`, APK_REPOSITORY: null, UPGRADE_STATE: `${state}/upgrade-state`, RULE_DATA_ROOT: `${state}/backend/run/rule-data`, RULE_LOCK_PATH: `${state}/rulesets.lock.json`, CONFIG_APPLY_WORK_DIR: `${state}/config-apply`,
		ROOT_DIR: state, BACKEND_ROOT: runtime.ROOT_DIR, BACKEND_RUN_DIR: runtime.RUN_DIR,
		POLICY_PATH: `${state}/policy.json`, SUBSCRIPTION_HISTORY_PATH: `${state}/subscription-history.json`, EVIDENCE_PATH: `${state}/evidence.json`, RECOVERY_PATH: `${state}/recovery.json`,
		POLICY_SOURCE_DIR: `${state}/policy-sources`, EVENTS_PATH: `${state}/events.json`, OPERATION_DIR: state, REFRESH_DIR: `${state}/refresh`,
		PACKAGE_BUILD_PATH: app == null || length(app) == 0 ? null : `${app}/build.json`,
		INSTALLED_IDENTITY_PATH: null,
		BASE: `${state}/backend`, SERVICE: 'opl-netfleet-desktop', private_file, private_directory, write_private, atomic_json,
		core_service: () => ({ ok: true, service: rpc('core.status').running ? { running: true } : null }),
		subscription_exists, subscription_display_name, subscription_options, subscription_quota, update_result,
		running, cleanup_state, stop, lan_runtime_state,
		restart: () => rpc('core.start').ok == true, update_subscription: id => rpc('subscription.update', { id }).ok == true
	};
};
