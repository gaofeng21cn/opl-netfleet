return function(context) {
	const state = getenv('NETFLEET_STATE_DIR');
	return { POLICY_PATH: `${state}/policy.json`, EVIDENCE_PATH: `${state}/evidence.json`, RECOVERY_PATH: `${state}/recovery.json`,
		POLICY_SOURCE_DIR: `${state}/policy-sources`, EVENTS_PATH: `${state}/events.json`, OPERATION_DIR: state, REFRESH_DIR: `${state}/refresh` };
};
