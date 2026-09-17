return function(context) {
	return {
		POLICY_PATH: "/etc/opl-netfleet/policy.json",
		SUBSCRIPTION_HISTORY_PATH: "/etc/opl-netfleet/subscription-history.json",
		EVIDENCE_PATH: "/etc/opl-netfleet/evidence.json",
		RECOVERY_PATH: "/etc/opl-netfleet/recovery.json",
		POLICY_SOURCE_DIR: "/etc/opl-netfleet/policy-sources",
		EVENTS_PATH: "/var/lib/opl-netfleet/events.json",
		OPERATION_DIR: "/tmp",
		REFRESH_DIR: "/tmp/opl-netfleet-subscription-refresh",
		// 安装构建身份的读取位置：包内构建记录与部署器写入的已安装身份。
		PACKAGE_BUILD_PATH: "/usr/share/opl-netfleet/build.json",
		INSTALLED_IDENTITY_PATH: "/etc/opl-netfleet/installed.json"
	};
};
