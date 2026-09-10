return function(context) {
	return {
		POLICY_PATH: "/etc/opl-netfleet/policy.json",
		EVIDENCE_PATH: "/etc/opl-netfleet/evidence.json",
		RECOVERY_PATH: "/etc/opl-netfleet/recovery.json",
		POLICY_SOURCE_DIR: "/etc/opl-netfleet/policy-sources",
		EVENTS_PATH: "/var/lib/opl-netfleet/events.json",
		OPERATION_DIR: "/tmp",
		REFRESH_DIR: "/tmp/opl-netfleet-subscription-refresh"
	};
};
