"""Recovery decisions consumed by the native gateway under its mutation lock."""


HEALTH_INTERVAL = 2
LEASE_SECONDS = 10
RECOVERY_SECONDS = 30
FAULT_WINDOW = 600
FAULT_LIMIT = 3


def advance(previous, *, requested, healthy, reason, now, manual_reset=False):
    state = dict(previous or {})
    faults = [stamp for stamp in state.get("faults", []) if now - FAULT_WINDOW <= stamp <= now]
    latched = state.get("latched", False) and not manual_reset
    since = state.get("healthy_since")
    if manual_reset:
        faults, since = [], None
    if not requested:
        return {"requested": False, "intercepting": False, "reason": "disabled",
                "faults": faults, "latched": latched, "healthy_since": None}
    if not healthy:
        if state.get("healthy") is True:
            faults.append(now)
        latched = latched or len(faults) >= FAULT_LIMIT
        return {"requested": True, "intercepting": False, "healthy": False,
                "reason": "manual_recovery_required" if latched else reason,
                "faults": faults, "latched": latched, "healthy_since": None}
    if since is None or since > now:
        since = now
    admitted = not latched and now - since >= RECOVERY_SECONDS
    return {"requested": True, "intercepting": admitted, "healthy": True,
            "reason": "manual_recovery_required" if latched else (None if admitted else "recovering"),
            "faults": faults, "latched": latched, "healthy_since": since}
