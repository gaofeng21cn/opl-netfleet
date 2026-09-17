return function(context) {
	const state = getenv('NETFLEET_STATE_DIR');
	// 应用包身份由构建器写入 Resources/build.json；源码运行没有该文件时不伪造身份。
	const app = getenv('NETFLEET_APP_ROOT');
	return { POLICY_PATH: `${state}/policy.json`, SUBSCRIPTION_HISTORY_PATH: `${state}/subscription-history.json`, EVIDENCE_PATH: `${state}/evidence.json`, RECOVERY_PATH: `${state}/recovery.json`,
		POLICY_SOURCE_DIR: `${state}/policy-sources`, EVENTS_PATH: `${state}/events.json`, OPERATION_DIR: state, REFRESH_DIR: `${state}/refresh`,
		PACKAGE_BUILD_PATH: app == null || length(app) == 0 ? null : `${app}/build.json`,
		INSTALLED_IDENTITY_PATH: null };
};
