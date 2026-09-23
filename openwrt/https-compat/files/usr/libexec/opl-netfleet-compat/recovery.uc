return function(previous, input) {
    const state = previous ?? {}, now = input.now;
    let faults = filter(state.faults ?? [], stamp => now - 600 <= stamp && stamp <= now);
    let latched = !!state.latched && !input.manual_reset, since = state.healthy_since;
    let hold_seconds = input.manual_reset ? 30 : state.hold_seconds ?? 30;
    if (input.manual_reset) { faults = []; since = null; }
    if (!input.requested) return {requested: false, intercepting: false, reason: 'disabled', faults, latched, healthy_since: null};
    if (!input.healthy) {
        const same_transient_fault=state.healthy===false&&state.reason=='transparent_chain_failed'&&
            input.reason=='transparent_chain_failed'&&state.hold_seconds==8;
        hold_seconds = input.transient_transparent_chain === true || same_transient_fault ? 8 : 30;
        if (input.count_failure !== false && state.healthy === true) push(faults, now);
        latched = latched || length(faults) >= 3;
        return {requested: true, intercepting: false, healthy: false, reason: latched ? 'manual_recovery_required' : input.reason,
            faults, latched, healthy_since: null, hold_seconds};
    }
    if (since == null || since > now) since = now;
    const admitted = !latched && now - since >= hold_seconds;
    return {requested: true, intercepting: admitted, healthy: true, reason: latched ? 'manual_recovery_required' : admitted ? null : 'recovering',
        faults, latched, healthy_since: since, hold_seconds};
};
