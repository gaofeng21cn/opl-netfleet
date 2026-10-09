return function(context) {
	const state = getenv('NETFLEET_STATE_DIR');
	const runtime = context.use('platform.runtime');
	// 应用包身份由构建器写入 Resources/build.json；源码运行没有该文件时不伪造身份。
	const app = getenv('NETFLEET_APP_ROOT');
	return { ROOT: state, CONFIG_PATH: `${state}/config.json`, BACKEND_PATH: `${state}/backend.json`, NATIVE_ROOT: `${state}/backend`, NATIVE_STATE_DIR: state,
		NATIVE_MIXIN_PATH: `${state}/backend/mixin.json`, CORE_INIT_PATH: `${state}/core`, SUPERVISOR_INIT_PATH: `${state}/scheduler`, MAIN_PATH: `${getenv('NETFLEET_SOURCE_ROOT') ?? ''}/main.uc`, SYSTEM_PATH: `${state}/system.json`,
		COMPAT_ROOT: `${state}/compat`, COMPAT_CONTROL_PATH: `${state}/compat/control.uc`, COMPAT_EXTENSION_PATH: `${state}/compat/extension.json`, COMPAT_LAUNCHER_PATH: `${state}/compat/launcher`, COMPAT_PORT_RANGE_PATH: `${state}/compat/port-range`, COMPAT_STATE_PATH: `${state}/compat/state.json`,
		PACKAGE_TRANSACTIONS: `${state}/package-transactions`, APK_REPOSITORY: null, UPGRADE_STATE: `${state}/upgrade-state`, RULE_DATA_ROOT: `${state}/backend/run/rule-data`, RULE_LOCK_PATH: `${state}/rulesets.lock.json`,
		ROOT_DIR: state, BACKEND_ROOT: runtime.ROOT_DIR, BACKEND_RUN_DIR: runtime.RUN_DIR,
		POLICY_PATH: `${state}/policy.json`, SUBSCRIPTION_HISTORY_PATH: `${state}/subscription-history.json`, EVIDENCE_PATH: `${state}/evidence.json`, RECOVERY_PATH: `${state}/recovery.json`,
		POLICY_SOURCE_DIR: `${state}/policy-sources`, EVENTS_PATH: `${state}/events.json`, OPERATION_DIR: state, REFRESH_DIR: `${state}/refresh`,
		PACKAGE_BUILD_PATH: app == null || length(app) == 0 ? null : `${app}/build.json`,
		INSTALLED_IDENTITY_PATH: null };
};
