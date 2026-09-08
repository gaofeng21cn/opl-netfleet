return function(context) {
	const backend = context.use("mihomo.backend");
	const controller = context.use("mihomo.controller");
	const readback = context.use("mihomo.readback");
	const profile = context.use("platform.profile");
	const storage = context.use("platform.storage");
	const credentials = context.use("platform.credentials");
	const service = context.use("platform.service");
	const documents = context.use("platform.documents");
	const model = context.use("models.activation");
	const recovery = context.use("recovery.control");
	const recovery_state = context.use("recovery.state");
	const output = context.use("events.output");
	function get() {
		const current = profile.current_profile(), running = backend.running();
		const state = running ? controller.proxies(credentials.api_secret(), 2) : null;
		const value = { profile: current, backend_enabled: profile.backend_enabled(), mihomo_running: running,
			active: model.is_active(current), controller_available: state?.proxies != null,
			netfleet_present: readback.state_has_netfleet(state, storage.read_json(backend.MANIFEST_PATH), current),
			cleanup: running ? null : backend.cleanup_state(), supervisor: service.service_state(),
			compatibility: service.service_state("opl-netfleet-compat") };
		return { ...value, mode: model.operating_mode(value) };
	};
	function failure(error, detail) { return { ok: false, error, result: { ...get(), detail: detail ?? null } }; };
	function pause() {
		return !service.service_state().installed || service.set_service_state({ enabled: false, running: false }).ok;
	};
	function direct() {
		const disabled = profile.set_backend_enabled(false);
		const stopped = backend.stop();
		return disabled && stopped.ok && get().mode == "openwrt";
	};
	function settle(policy, before) {
		const now = get();
		if (now.mode == "mihomo" || now.mode == "openwrt") return;
		const target = !model.is_active(before.profile) && backend.profile_exists(before.profile) ? before.profile : policy?.recovery_profile?.ref;
		if (target != null && profile.set_backend_enabled(true)) {
			const restored = recovery.restore_profile_with_probes(target, policy);
			if (restored.runtime_ok && get().mode == "mihomo") return;
		}
		direct();
	};
	function set(request) {
		if (context.instance != null && context.instance != "default") return failure("runtime_mode_host_only");
		if (type(request) != "object" || index(["openwrt", "mihomo", "netfleet"], request.mode) < 0 ||
			length(filter(keys(request), key => index(["mode", "expected_mode"], key) < 0)) ||
			!("expected_mode" in request)) return failure("runtime_mode_invalid");
		const before = get();
		if (request.expected_mode != before.mode) return failure("runtime_mode_changed");
		const policy = documents.load_policy();
		if (request.mode == "netfleet" && policy == null) return failure("policy_unreadable");
		const target = !model.is_active(before.profile) && backend.profile_exists(before.profile) ?
			before.profile : policy?.recovery_profile?.ref;
		if (request.mode == "mihomo" && target == null) return failure("native_profile_unavailable");
		if (!recovery_state.clear()) return failure("recovery_state_write_failed");
		if (request.mode == before.mode) return { ok: true, result: { ...get(), unchanged: true } };
		if (request.mode != "netfleet" && before.compatibility.installed &&
			!service.set_service_state({ enabled: false, running: false }, "opl-netfleet-compat").ok)
			return failure("compatibility_stop_failed");
		if (!pause()) return failure("supervisor_stop_failed");
		const attempt = output.capture(() => {
			if (request.mode == "openwrt") {
				if (!direct()) output.fail("set-mode", "runtime_mode_cleanup_failed");
				return;
			}
			// A healthy compiled runtime only needs its scheduler restored.
			if (request.mode == "netfleet" && before.active && before.netfleet_present && before.mihomo_running && before.controller_available) {
				if (!profile.set_backend_enabled(true) || !service.set_service_state({ enabled: true, running: true }).ok)
					output.fail("set-mode", "supervisor_start_failed");
				return;
			}
			const native_target = request.mode == "mihomo" ? target : policy.recovery_profile.ref;
			if (!profile.set_backend_enabled(true)) output.fail("set-mode", "backend_enable_failed");
			const same_native = before.profile == native_target && before.mihomo_running && before.controller_available && !before.netfleet_present;
			if (!same_native) {
				const restored = recovery.restore_profile_with_probes(native_target, policy);
				if (!restored.runtime_ok) output.fail("set-mode", "profile_restore_failed", restored);
			}
			if (request.mode == "netfleet") {
				const compiled = context.use("compilation.control").compile_result(policy, false);
				if (!compiled.ok) output.fail("set-mode", compiled.error, compiled.detail);
				context.use("activation.control").enable_action(policy, documents.load_evidence(), true);
				if (!service.set_service_state({ enabled: true, running: true }).ok) output.fail("set-mode", "supervisor_start_failed");
			}
			if (get().mode != request.mode) output.fail("set-mode", "runtime_mode_unconfirmed");
		});
		if (!attempt.ok) {
			const recovery_attempt = output.capture(() => {
				pause();
				if (request.mode == "openwrt") direct();
				else settle(policy, before);
			});
			return failure(attempt.error, { cause: attempt.detail, recovery_error: recovery_attempt.ok ? null : recovery_attempt.error });
		}
		return { ok: true, result: get() };
	};
	return { get: () => ({ ok: true, result: get() }), set };
};
