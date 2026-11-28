return function(context) {
	const runtime = context.use("platform.runtime");
	const root = "/etc/opl-netfleet";
	const backend = runtime.ROOT_DIR;
	return {
		ROOT: root,
		CONFIG_PATH: "/etc/config/netfleet",
		BACKEND_PATH: "/etc/opl-netfleet/backend.json",
		SYSTEM_PATH: "/etc/opl-netfleet/system.json",
		NATIVE_ROOT: "/etc/opl-netfleet/native",
		NATIVE_STATE_DIR: "/var/run/opl-netfleet-core",
		NATIVE_MIXIN_PATH: "/etc/opl-netfleet/native/mixin.json",
		CORE_INIT_PATH: "/etc/init.d/opl-netfleet-core",
		SUPERVISOR_INIT_PATH: "/etc/init.d/opl-netfleet",
		MAIN_PATH: "/usr/libexec/opl-netfleet/main.uc",
		PACKAGE_TRANSACTIONS: "/etc/opl-netfleet/package-transactions",
		APK_REPOSITORY: "/etc/apk/repositories.d/opl-netfleet.list",
		UPGRADE_STATE: "/tmp/opl-netfleet-package-upgrade-state",
		CONFIG_APPLY_WORK_DIR: "/tmp/opl-netfleet-config-apply",
		RULE_DATA_ROOT: `${backend}/run/rule-data`,
		RULE_LOCK_PATH: `${root}/rulesets.lock.json`,
		ROOT_DIR: root,
		BACKEND_ROOT: backend,
		BACKEND_RUN_DIR: runtime.RUN_DIR,
		POLICY_PATH: "/etc/opl-netfleet/policy.json",
		SUBSCRIPTION_HISTORY_PATH: "/etc/opl-netfleet/subscription-history.json",
		EVIDENCE_PATH: "/etc/opl-netfleet/evidence.json",
		RECOVERY_PATH: "/etc/opl-netfleet/recovery.json",
		POLICY_SOURCE_DIR: "/etc/opl-netfleet/policy-sources",
		EVENTS_PATH: "/var/lib/opl-netfleet/events.json",
		OPERATION_DIR: "/tmp",
		REFRESH_DIR: "/tmp/opl-netfleet-subscription-refresh",
		// 安装构建身份与 Release Bundle 的读取位置：包内构建记录与部署器写入的已安装身份。
		PACKAGE_BUILD_PATH: "/usr/share/opl-netfleet/build.json",
		INSTALLED_IDENTITY_PATH: "/etc/opl-netfleet/installed.json",
		BUNDLE_ROOT: "/usr/share/opl-netfleet",
		BUNDLE_CURRENT: "/usr/share/opl-netfleet/current",
		BUNDLE_PREVIOUS: "/usr/share/opl-netfleet/previous",
		BUNDLE_RELEASES: "/usr/share/opl-netfleet/releases",
		BUNDLE_KEY_PATH: "/usr/share/opl-netfleet/keys/release-bundle.pub",
		SHELL_META_PATH: "/usr/share/opl-netfleet/shell.json",
		OPKG_FEEDS_PATH: "/etc/opkg/customfeeds.conf",
		RELEASE_FEED_PATH: "/etc/opl-netfleet/release-feed.json"
	};
};
