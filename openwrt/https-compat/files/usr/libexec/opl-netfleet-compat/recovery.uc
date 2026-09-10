return function(previous, input) {
    const state = previous ?? {}, now = input.now;
    let faults = filter(state.faults ?? [], stamp => now - 600 <= stamp && stamp <= now);
    let latched = !!state.latched && !input.manual_reset, since = state.healthy_since;
    if (input.manual_reset) { faults = []; since = null; }
    if (!input.requested) return {requested: false, intercepting: false, reason: 'disabled', faults, latched, healthy_since: null};
    if (!input.healthy) {
        if (input.count_failure !== false && state.healthy === true) push(faults, now);
        latched = latched || length(faults) >= 3;
        return {requested: true, intercepting: false, healthy: false, reason: latched ? 'manual_recovery_required' : input.reason,
            faults, latched, healthy_since: null};
    }
    if (since == null || since > now) since = now;
    const admitted = !latched && now - since >= 30;
    return {requested: true, intercepting: admitted, healthy: true, reason: latched ? 'manual_recovery_required' : admitted ? null : 'recovering',
        faults, latched, healthy_since: since};
};
