return function(context) {
	const set_profile = context.use("platform.profile").set_profile;
	const restart = context.use("mihomo.backend").restart;
	const runtime_readback = context.use("mihomo.readback").runtime_readback;
	const protected_probes_after_restart = context.use("mihomo.probes").protected_probes_after_restart;

	function switch_profile(profile, manifest, policy) {
		if (!set_profile(profile) || !restart()) return { ok: false, error: "owner_switch_failed" };
		const readback = runtime_readback(profile, manifest);
		return { ok: readback?.mihomo_running == true && readback?.mihomo_config_valid == true &&
			readback?.state_available == true && readback?.runtime_identity_ok == true, readback: readback };
	}

	function verify(profile, manifest, policy) {
		const readback = runtime_readback(profile, manifest);
		const probes = policy == null ? null : protected_probes_after_restart(policy);
		return { ok: readback?.mihomo_running == true && readback?.mihomo_config_valid == true &&
			readback?.state_available == true && readback?.runtime_identity_ok == true &&
			(probes == null || probes.ok == true), readback: readback, protected_probes: probes };
	}
	return { switch_profile, verify };
};
