#!/usr/bin/python3
import sys
sys.dont_write_bytecode = True

import fcntl
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import time

import haproxy

import gateway
import isolation
import identity as device_identity
from policy import validate
from recovery import ENGINE_RESTART_GRACE_SECONDS, advance


BASE = Path("/etc/opl-netfleet/compatibility")
RUN = Path("/var/run/opl-netfleet-compat")
CONFIG = BASE / "config.json"
STATE = RUN / "state.json"
EFFECTIVE = RUN / "effective.json"
TRUST = BASE / "trust.json"
CA = BASE / "ca"
SERVICE = "/etc/init.d/opl-netfleet-compat"
OWNER = "/usr/libexec/opl-netfleet/main.uc"
DEFAULT = {"schema": 1, "enabled": False, "devices": [], "rules": []}
MUTATION_LOCK = Path("/var/lock/opl-netfleet-deploy.lock")


def ancestor_holds_lock(path):
    target = path.stat()
    parent = os.getppid()
    visited = set()
    for _ in range(64):
        if not parent or parent in visited:
            return False
        visited.add(parent)
        process = Path(f"/proc/{parent}")
        try:
            if process.stat().st_uid != 0:
                return False
            for info in (process / "fdinfo").iterdir():
                try:
                    descriptor = (process / "fd" / info.name).stat()
                    if ((descriptor.st_dev, descriptor.st_ino) == (target.st_dev, target.st_ino)
                            and re.search(r"lock:.*FLOCK\s+ADVISORY\s+WRITE\s", info.read_text())):
                        return True
                except OSError:
                    continue
            match = re.search(r"\nPPid:\s*(\d+)", (process / "status").read_text())
            parent = int(match[1]) if match else 0
        except OSError:
            return False
    return False


@contextmanager
def mutation_lock(wait_seconds=0):
    with MUTATION_LOCK.open("a") as lock:
        owned = True
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            if ancestor_holds_lock(MUTATION_LOCK):
                owned = False
            else:
                deadline = time.monotonic() + wait_seconds
                while True:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise ValueError("mutation_busy") from None
                    time.sleep(min(0.02, remaining))
                    try:
                        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        break
                    except BlockingIOError:
                        continue
        yield lock if owned else None


def read(path, fallback=None):
    try:
        return json.loads(path.read_bytes())
    except FileNotFoundError:
        return fallback


def atomic(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    data = json.dumps(value, sort_keys=True, separators=(",", ":")).encode() + b"\n"
    temporary = path.with_suffix(".new")
    with temporary.open("wb") as stream:
        os.chmod(temporary, 0o600)
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    if path == EFFECTIVE:
        try:
            os.chown(temporary, 0, isolation.account()[1])
            os.chmod(temporary, 0o640)
        except KeyError:
            pass
    temporary.replace(path)
    descriptor = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def revision():
    return hashlib.sha256(CONFIG.read_bytes() + b"\0" + (TRUST.read_bytes() if TRUST.exists() else b"")).hexdigest() if CONFIG.exists() else None


def ca_fingerprint():
    import ssl
    path = CA / "mitmproxy-ca-cert.pem"
    try:
        der = ssl.PEM_cert_to_DER_cert(path.read_text())
        # Parse X.509 with the system TLS library before trusting its fingerprint.
        # Status reads must not import the certificate-signing runtime.
        ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT).load_verify_locations(cadata=der)
        return hashlib.sha256(der).hexdigest()
    except (OSError, ValueError):
        return None


def prepare_ca():
    haproxy.prepare_ca(CA)


_verified_engine = None
_certificate_check = None


def certificate_refresh_required(health):
    global _certificate_check
    now = time.monotonic()
    identity = (health.get('pid'), (CA / 'probe-cert.pem').stat().st_mtime_ns)
    if _certificate_check is None or _certificate_check[0] != identity or now >= _certificate_check[1]:
        result = subprocess.run(['openssl', 'x509', '-in', str(CA / 'probe-cert.pem'),
                                 '-checkend', '604800', '-noout'], capture_output=True, timeout=2)
        _certificate_check = (identity, now + 3600, result.returncode != 0)
    return _certificate_check[2]


def reconcile_engine(health):
    """Only replace a configuration after removing admission and draining its connections."""
    effective = read(EFFECTIVE)
    expected = haproxy.configuration_revision(effective)
    if health.get('revision') == expected and not certificate_refresh_required(health):
        haproxy.sync_rule_switches(RUN, effective, health)
        return False
    gateway.bypass()
    if health.get('ready') and health.get('active_connections') == 0:
        # procd owns the replacement. This signal targets only the confirmed engine instance.
        subprocess.run(['ubus', 'call', 'service', 'signal', json.dumps({
            'name': 'opl-netfleet-compat', 'instance': 'engine', 'signal': 15})],
            check=True, capture_output=True, timeout=1)
    return True


def engine_health(probe=False):
    global _verified_engine
    health_error = 'health_socket_unavailable'
    try:
        value = haproxy.health(RUN)
        identity = (value['pid'], value['revision'])
        now = time.monotonic()
        full_due = _verified_engine is None or _verified_engine[:2] != identity or now - _verified_engine[2] >= 60
        proofs = dict(_verified_engine[3]) if not full_due else {}
        def check(name, work):
            try:
                proofs[name] = work()
            except (OSError, ValueError):
                proofs[name] = {'ok': False, 'reason': 'local_conversion_failed'}
        if probe:
            if full_due:
                check('processing', lambda: haproxy.probe(RUN))
            uid = isolation.account()[0]
            for family in (4, 6):
                check('ipv' + str(family), lambda family=family: haproxy.probe(RUN, family, socket_uid=uid))
            if all(item.get('ok') for item in proofs.values()):
                _verified_engine = (*identity, now if full_due else _verified_engine[2], proofs)
            else:
                _verified_engine = None
        return {**value, 'processing_chain': proofs.get('processing', {}).get('ok') is True,
                'transparent_chain': all(proofs.get('ipv' + str(family), {}).get('ok') is True for family in (4, 6)),
                'local_probes': proofs}
    except (OSError, ValueError, KeyError, StopIteration, subprocess.SubprocessError) as error:
        health_error = str(error) if isinstance(error, ValueError) and re.fullmatch(r'[a-z_]+', str(error)) else (
            'health_socket_timeout' if isinstance(error, TimeoutError) else 'health_chain_unavailable')
        _verified_engine = None
    def with_diagnostic(value):
        return value
    connections, pid, starting = None, None, False
    try:
        result = subprocess.run(["ubus", "call", "service", "list", '{"name":"opl-netfleet-compat"}'],
                                capture_output=True, text=True, timeout=0.4)
        if result.returncode == 0:
            instances = json.loads(result.stdout).get("opl-netfleet-compat", {}).get("instances", {})
            engine = instances.get("engine", {})
            if not engine.get("running"):
                connections = 0
            elif type(engine.get('pid')) is int:
                pid = engine['pid']
                fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
                age = time.monotonic() - int(fields[19]) / os.sysconf('SC_CLK_TCK')
                starting = 0 <= age < 60
    except (OSError, ValueError, IndexError, subprocess.SubprocessError):
        pass
    return with_diagnostic({"ready": False, "active_requests": None, "active_connections": connections, "rules": {},
                   "pid": pid, "starting": starting, "health_error": health_error})


def snapshot():
    return gateway.snapshot()


def verified_trust(config, trust, fingerprint):
    return {device["id"]: trust[device["id"]] for device in config["devices"]
            if fingerprint and trust.get(device["id"], {}).get("ca_sha256") == fingerprint
            and device_identity.trust_matches(device, trust[device["id"]])
            and trust[device["id"]].get("verified") is True}


def effective(config, trust, fingerprint, source=None):
    devices = verified_trust(config, trust, fingerprint)
    source = device_identity.resolve(config)[0] if source is None else source
    resolved = [{**device, "addresses": device_identity.addresses(device, source)} for device in config["devices"]]
    owners = {}
    for device in resolved:
        for address in device["addresses"]:
            owners.setdefault(address, set()).add(device["id"])
    for device in resolved:
        device["addresses"] = sorted({address for address in device["addresses"] if len(owners[address]) == 1})
    eligible = {device["id"] for device in resolved if device["id"] in devices and device["addresses"]}
    # Empty manual devices are not valid engine configuration, and cannot match rules.
    return {**config, "devices": [device for device in resolved if device["addresses"] or device.get("identity")],
            "rules": [{**rule, "devices": [device for device in rule["devices"] if device in eligible]}
                      for rule in config["rules"] if any(device in eligible for device in rule["devices"])]}


async def probe_rules(rules):
    import asyncio
    request = RUN / 'probe-request.json'
    atomic(request, {'rules': rules, 'egress': read(EFFECTIVE, {}).get('egress')})
    try:
        process = await asyncio.create_subprocess_exec(sys.executable, '-B', str(Path(haproxy.__file__)),
            'upstreams', str(request), stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
        try:
            output, _ = await asyncio.wait_for(process.communicate(), timeout=2)
            if process.returncode == 0:
                return json.loads(output)
        finally:
            if process.returncode is None:
                process.kill()
                await process.wait()
    finally:
        request.unlink(missing_ok=True)
    return {rule['id']: {'ok': False, 'at': int(time.time()), 'reason': 'engine_probe_unavailable'} for rule in rules}


async def resolve_targets(rules):
    import asyncio
    async def resolve(rule):
        if rule["match"] == "suffix":
            return rule["id"], ["0.0.0.0/0", "::/0"]
        try:
            async with asyncio.timeout(0.7):
                records = await asyncio.get_running_loop().getaddrinfo(
                    rule["domain"], rule["port"], type=socket.SOCK_STREAM)
                return rule["id"], sorted({record[4][0] for record in records})
        except (OSError, asyncio.TimeoutError):
            return rule["id"], []
    return dict(await asyncio.gather(*(resolve(rule) for rule in rules)))


def status():
    config = validate(read(CONFIG, DEFAULT))
    state = read(STATE, {})
    health = engine_health()
    kernel = gateway.status()
    fingerprint = ca_fingerprint()
    source = device_identity.resolve(config)[0]
    active = effective(config, read(TRUST, {}), fingerprint, source)
    reason = state.get("reason", "disabled" if not config["enabled"] else "not_ready")
    if not kernel["intercepting"] and state.get("intercepting"):
        reason = "lease_expired"
    if not config["enabled"]:
        reason = "draining" if health.get("active_connections") else "disabled"
    elif not fingerprint:
        reason = "ca_not_ready"
    return {"installed": True, "engine": {"name": "HAProxy", "version": health.get("engine_version")}, "revision": revision(), "config": config, "requested": config["enabled"],
            **kernel, "isolation": isolation.status(), "reason": reason, "active_connections": health.get("active_connections"),
            "address_source": source,
            "device_addresses": {device["id"]: next((item["addresses"] for item in active["devices"] if item["id"] == device["id"]), [])
                                 for device in config["devices"]},
            "eligible_devices": sorted({device for rule in active["rules"] for device in rule["devices"]}),
            "device_connections": {device["id"]: health.get("clients_by_device", {}).get(device["id"], 0)
                                   if health.get("unassigned_connections") == 0 else
                                   0 if health.get("active_connections") == 0 else None for device in config["devices"]},
            "active_requests": health.get("active_requests"), "rules": health.get("rules", {}),
            "recovery": state.get("recovery", {}), "ca_sha256": fingerprint,
            "last_failure": state.get("last_failure"), "engine_restart": state.get("engine_restart", {}),
            "rule_recovery": state.get("rule_recovery", {}),
            "local_probes": state.get("local_probes", {}),
            "trust": verified_trust(config, read(TRUST, {}), fingerprint), "events": state.get("events", [])[-100:]}


def save_state(state, previous):
    events = previous.get("events", [])
    if (state.get("reason"), state.get("intercepting")) != (previous.get("reason"), previous.get("intercepting")):
        events = [*events, {"at": int(time.time()), "reason": state.get("reason"), "intercepting": state.get("intercepting", False),
                           "local_probes": state.get("local_probes", {}), "failure": state.get("last_failure"),
                           "engine_restart": state.get("engine_restart", {})}][-100:]
    for identity, current in state.get("rule_recovery", {}).items():
        old = previous.get("rule_recovery", {}).get(identity, {})
        if (current.get("reason"), current.get("intercepting")) != (old.get("reason"), old.get("intercepting")):
            events = [*events, {"at": int(time.time()), "rule": identity, "reason": current.get("reason"), "intercepting": current.get("intercepting", False),
                                "failure": current.get("last_failure"), "probe": current.get("probe")}][-100:]
    atomic(STATE, {**state, "events": events, "last_tick": time.monotonic()})


def probe_without_network_lock(lock, work):
    if lock is None:
        raise ValueError("compatibility_probe_requires_independent_lock")
    paths = (CONFIG, TRUST, STATE, EFFECTIVE, CA / "mitmproxy-ca-cert.pem",
             Path("/etc/opl-netfleet/native/run/config.yaml"), Path("/etc/config/netfleet"),
             Path("/var/run/opl-netfleet-core/ownership.json"))
    def identity():
        return tuple(path.read_bytes() if path.exists() else None for path in paths)
    before = identity()
    fcntl.flock(lock, fcntl.LOCK_UN)
    try:
        result = work()
    finally:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError("mutation_busy") from None
    if identity() != before:
        raise ValueError("compatibility_probe_stale")
    return result


def tick(lock=None, delayed_by_mutation=False):
    import asyncio
    config = validate(read(CONFIG, DEFAULT))
    previous = read(STATE, {})
    now = time.monotonic()
    if now - previous.get("last_tick", now) > 10 and not delayed_by_mutation:
        if previous.get("recovery", {}).get("intercepting") is True:
            previous["last_failure"] = {"at": int(time.time()), "reason": "management_lease_expired"}
        previous["recovery"] = advance(previous.get("recovery"), requested=config["enabled"],
                                        healthy=False, reason="management_lease_expired", now=now,
                                        count_failure=previous.get("recovery", {}).get("intercepting") is True)
    if not config["enabled"]:
        gateway.bypass()
        health = engine_health()
        if health.get("active_connections") == 0:
            # The owner has already bypassed and drained while holding the mutation lock.
            subprocess.run(["ubus", "call", "service", "delete", '{"name":"opl-netfleet-compat"}'],
                           capture_output=True, timeout=2)
        save_state({**previous, "intercepting": False, "reason": "disabled"}, previous)
        return
    if previous.get("maintenance"):
        gateway.bypass()
        save_state({**previous, "intercepting": False, "reason": "maintenance"}, previous)
        return
    if previous.get("recovery", {}).get("latched"):
        # Manual recovery is required: no recurring full network/handshake work.
        gateway.bypass()
        save_state({**previous, "intercepting": False, "reason": "manual_recovery_required"}, previous)
        return
    source, previous["identity_sync"] = probe_without_network_lock(lock,
        lambda: device_identity.resolve(config, previous.get("identity_sync"), schedule=True))
    network = {}
    try:
        network = snapshot()
        reason = network.get("reason", "native_gateway_unavailable")
        if not reason:
            current = read(EFFECTIVE, {})
            if current.get("egress") != network.get("egress"):
                gateway.bypass()
                atomic(EFFECTIVE, {**current, "egress": network.get("egress")})
            gateway.prepare(network)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        reason = str(error) if isinstance(error, ValueError) and re.fullmatch(r'[a-z_]+', str(error)) else "native_gateway_unavailable"
    health = probe_without_network_lock(lock, lambda: engine_health(probe=True))
    if health.get('ready') and reconcile_engine(health):
        save_state({**previous, 'intercepting': False, 'reason': 'engine_config_pending'}, previous)
        return
    starting = health.get('starting') and health.get('pid') != previous.get('ready_engine_pid')
    expected = haproxy.configuration_revision(read(EFFECTIVE)) if EFFECTIVE.exists() else None
    healthy = (not reason and health.get("ready") and health.get("processing_chain") is True
               and health.get("transparent_chain") is True and health.get("revision") == expected)
    if not reason:
        reason = ("engine_unavailable" if not health.get("ready") else
                  "processing_chain_failed" if health.get("processing_chain") is not True else
                  "transparent_chain_failed" if health.get("transparent_chain") is not True else
                  "engine_config_pending" if health.get("revision") != expected else None)
    if starting:
        reason = 'engine_starting'
    recovery = advance(previous.get("recovery"), requested=True, healthy=bool(healthy), reason=reason, now=now,
                       count_failure=previous.get("recovery", {}).get("intercepting") is True
                       and not starting and network.get("ready") is True and not network.get("reason") and reason != "engine_config_pending")
    last_pid = previous.get("engine_pid")
    if health.get("pid") and last_pid and health["pid"] != last_pid:
        if previous.get("recovery", {}).get("intercepting") is True and (not recovery["faults"] or recovery["faults"][-1] != now):
            recovery["faults"] = [stamp for stamp in recovery.get("faults", []) if now - 600 <= stamp <= now] + [now]
        recovery["latched"] = recovery.get("latched", False) or len(recovery["faults"]) >= 3
        recovery["intercepting"] = False
        recovery["healthy_since"] = now if healthy else None
        recovery["reason"] = "manual_recovery_required" if recovery["latched"] else "engine_restarted"
    state = {**previous, "recovery": recovery, "reason": recovery["reason"], "intercepting": False,
             "local_probes": health.get("local_probes", {})}
    if not healthy and not starting:
        state["last_failure"] = {"at": int(time.time()), "reason": reason, "health_error": health.get("health_error"),
                                 "local_probes": health.get("local_probes", {}), "engine_pid": health.get("pid"),
                                 "health_diagnostic": health.get("health_diagnostic")}
    state["engine_pid"] = health.get("pid", last_pid)
    if health.get('ready') and health.get('pid'):
        state['ready_engine_pid'] = health['pid']
    if not recovery["intercepting"]:
        gateway.bypass()
        if (not health.get("ready") or health.get("processing_chain") is not True
                or health.get("transparent_chain") is not True):
            since = previous.get("unhealthy_since", now)
            state["unhealthy_since"] = since
            restart = previous.get("engine_restart", {})
            if (now - since >= ENGINE_RESTART_GRACE_SECONDS and not starting
                    and not recovery["latched"] and network.get("ready")
                    and now >= restart.get("next_at", 0)):
                # Recovery attempts belong to the existing outage, not a new fault.
                attempts = min(restart.get("attempts", 0) + 1, 1000000)
                delay = min(60, ENGINE_RESTART_GRACE_SECONDS * 2 ** min(attempts - 1, 3))
                state["engine_restart"] = {"attempts": attempts, "next_at": now + delay}
                state["unhealthy_since"] = now
                save_state(state, previous)
                subprocess.run(["ubus", "call", "service", "signal", json.dumps({"name": "opl-netfleet-compat", "instance": "engine", "signal": 9})],
                               capture_output=True, timeout=1)
                subprocess.run([SERVICE, "start"], capture_output=True, timeout=2)
        else:
            state.pop("unhealthy_since", None)
        save_state(state, previous)
        return
    state.pop("engine_restart", None)
    active = effective(config, read(TRUST, {}), ca_fingerprint(), source)
    if network.get("egress") is not None:
        active["egress"] = network["egress"]
    rule_states = dict(previous.get("rule_recovery", {}))
    if previous.get('engine_pid') != health.get('pid'):
        rule_states = {key: {**value, 'last_error': 0} for key, value in rule_states.items()}
    seen = {**previous.get("observed", {}), **health.get("observed", {})}
    # A retained observation cannot override an edited rule's target or port.
    observed = {rule['id']: {'domain': seen[rule['id']]['domain']} for rule in active['rules']
                if rule['match'] == 'suffix' and isinstance(seen.get(rule['id'], {}).get('domain'), str)
                and (seen[rule['id']]['domain'] == rule['domain']
                     or seen[rule['id']]['domain'].endswith('.' + rule['domain']))}
    state["observed"] = observed
    pending = [{**rule, **observed.get(rule["id"], {})} for rule in active["rules"] if rule["enabled"] and rule["strategy"] == "h2"
               and (rule["match"] == "exact" or rule["id"] in observed)
               and rule_states.get(rule["id"], {}).get("intercepting") is not True
               and now - rule_states.get(rule["id"], {}).get("last_probe", -100) >= 10]
    probes = probe_without_network_lock(lock, lambda: asyncio.run(probe_rules(pending))) if pending else {}
    for rule in active["rules"]:
        if not rule["enabled"] or rule["strategy"] != "h2":
            continue
        old = rule_states.get(rule["id"], {})
        errors = [event for event in health.get("failure_events", []) if event["rule"] == rule["id"]
                  and event["id"] > old.get("last_error", 0)]
        new_error = bool(errors)
        probe = probes.get(rule["id"], old.get("probe", {}))
        probe_ok = probe.get("ok", old.get("probe_ok", rule["match"] == "suffix"))
        failure = errors[-1] if errors else old.get("last_failure")
        reason = failure.get("reason", "upstream_transport_failed") if new_error else probe.get("reason", "upstream_protocol_failed")
        # Only a failure after admission starts another incident. A burst of failed
        # streams and unsuccessful recovery probes all belong to the same outage.
        current = advance(old, requested=True, healthy=probe_ok and not new_error, reason=reason, now=now,
                          count_failure=old.get("intercepting") is True)
        current.update({"probe": probe, "last_failure": failure, "probe_ok": probe_ok, "last_probe": now if rule["id"] in probes else old.get("last_probe", -100),
                        "last_error": max(event["id"] for event in errors) if new_error else old.get("last_error", 0)})
        if new_error:
            current["probe_ok"] = False
            current["last_probe"] = -100
        rule_states[rule["id"]] = current
        if not current["intercepting"]:
            active.setdefault("blocked_rules", []).append(rule["id"])
    state["rule_recovery"] = rule_states
    if read(EFFECTIVE) != active:
        gateway.bypass()
        atomic(EFFECTIVE, active)
        state["reason"] = "rules_recovering"
        save_state(state, previous)
        return
    target_rules = [rule for rule in active["rules"] if rule["enabled"] and rule["strategy"] == "h2" and rule["id"] not in active.get("blocked_rules", [])]
    targets = probe_without_network_lock(lock, lambda: asyncio.run(resolve_targets(target_rules)))
    pairs = {(device, rule["port"], destination) for rule in target_rules
             for device in rule["devices"] for destination in targets[rule["id"]]}
    candidates = []
    for device in active["devices"]:
        for identity, port, destination in pairs:
            if identity != device["id"]:
                continue
            for address in device["addresses"]:
                family = 6 if ":" in address else 4
                if network.get(f"ipv{family}_proxy") and (":" in destination) == (family == 6):
                    candidates.append((address, destination, port))
    if candidates:
        gateway.renew(candidates)
    else:
        gateway.bypass()
        state["reason"] = "rules_bypassed" if target_rules == [] and active["rules"] else "no_verified_targets"
    state["intercepting"] = bool(candidates)
    save_state(state, previous)


def apply(action, request):
    if request.get("revision") != revision():
        raise ValueError("compatibility_revision_conflict")
    config = validate(read(CONFIG, DEFAULT))
    original = config
    trust = read(TRUST, {})
    original_enabled = config["enabled"]
    if action == "apply":
        config = validate(request.get("config"))
    elif action in ("enable", "disable"):
        config["enabled"] = action == "enable"
    source = device_identity.resolve(config)[0]
    if action == "apply":
        verified = verified_trust(original, trust, ca_fingerprint())
        for device in config["devices"]:
            old = next((item for item in original["devices"] if item["id"] == device["id"]), None)
            if old and not old.get("identity") and device.get("identity") and device["id"] in verified:
                if not set(old["addresses"]) & set(device_identity.addresses(device, source)):
                    raise ValueError("device_identity_not_confirmed")
                trust[device["id"]] = {**trust[device["id"]], "identity": device["identity"]}
    gateway.bypass()
    if action != "disable" and (config["enabled"] or config["devices"]):
        prepare_ca()
    atomic(CONFIG, config)
    atomic(TRUST, {key: value for key, value in trust.items() if any(device["id"] == key for device in config["devices"])})
    atomic(EFFECTIVE, effective(config, trust, ca_fingerprint(), source))
    previous = read(STATE, {})
    kept = previous if original_enabled and config["enabled"] and action == "apply" else {}
    save_state({**kept, "intercepting": False, "reason": "recovering" if config["enabled"] else "disabled"}, previous)
    if config["enabled"]:
        subprocess.run([SERVICE, "enable"], check=True, capture_output=True, timeout=2)
        subprocess.run([SERVICE, "start"], check=True, capture_output=True, timeout=3)
    else:
        subprocess.run([SERVICE, "disable"], check=True, capture_output=True, timeout=2)
    return status()


def trust_action(request):
    if request.get("revision") != revision():
        raise ValueError("compatibility_revision_conflict")
    config = validate(read(CONFIG, DEFAULT))
    device = next((item for item in config["devices"] if item["id"] == request.get("device")), None)
    if device is None:
        raise ValueError("unknown_device")
    trust = read(TRUST, {})
    gateway.bypass()
    if request["operation"] == "trust_revoke":
        trust.pop(device["id"], None)
    else:
        report = request.get("report", {})
        if report.get("ca_sha256") != ca_fingerprint() or report.get("system") is not True:
            raise ValueError("device_trust_not_verified")
        # Only the authenticated enrollment tool records verification; UI has no ready toggle.
        if device.get("identity") and not device_identity.addresses(device, device_identity.resolve(config)[0]):
            raise ValueError("device_identity_not_confirmed")
        trust[device["id"]] = {"verified": True, "ca_sha256": ca_fingerprint(), "addresses": device["addresses"],
                                **({"identity": device["identity"]} if device.get("identity") else {}),
                                "verified_at": int(time.time()), "runtimes": {"system": True,
                                **{name: report.get(name) if type(report.get(name)) is bool else None
                                   for name in ("codex_app", "codex_cli", "images")}}}
    atomic(TRUST, trust)
    atomic(EFFECTIVE, effective(config, trust, ca_fingerprint()))
    return status()


def drain(timeout=30):
    gateway.bypass()
    deadline = time.monotonic() + timeout if timeout is not None else None
    while True:
        health = engine_health()
        if health.get("active_connections") == 0 or not health.get("ready"):
            return {"drained": True}
        if deadline is not None and time.monotonic() >= deadline:
            raise ValueError("healthy_connections_still_draining")
        time.sleep(0.2)


def main():
    os.umask(0o077)
    action = sys.argv[1]
    if action == "watch":
        isolation.constrain_manager()
        import signal
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
        mutation_wait_at = None
        while True:
            started = time.monotonic()
            try:
                device_identity.reap_sync()
                gateway.start_worker()
                with mutation_lock() as lock:
                    tick(lock, delayed_by_mutation=mutation_wait_at is not None and 0 <= started - mutation_wait_at < 10)
                    mutation_wait_at = None
            except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
                reason = str(error) if isinstance(error, ValueError) and re.fullmatch(r'[a-z_]+', str(error)) else 'compatibility_controller_failed'
                mutation_wait_at = time.monotonic() if reason == 'mutation_busy' else None
                if reason not in ('mutation_busy', 'compatibility_probe_stale'):
                    try:
                        with mutation_lock():
                            try:
                                gateway.bypass()
                            except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
                                pass
                            previous = read(STATE, {})
                            save_state({**previous, 'intercepting': False, 'reason': reason}, previous)
                    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
                        # No renewal on failure; the kernel remains the expiry owner.
                        pass
                time.sleep(2)
            else:
                time.sleep(max(0.05, 2 - (time.monotonic() - started)))
    if action == "run":
        prepare_ca()
        isolation.prepare(BASE, RUN)
        config = haproxy.prepare(EFFECTIVE, RUN)
        os.chown(RUN / 'rules.map', 0, isolation.account()[1])
        os.chmod(RUN / 'rules.map', 0o640)
        os.chown(config, 0, isolation.account()[1])
        os.chmod(config, 0o640)
        isolation.constrain()
        os.execv(haproxy.BINARY, [haproxy.BINARY, '-db', '-f', str(config)])
    if action == "get":
        return status()
    if action == "ca":
        return {"pem": (CA / "mitmproxy-ca-cert.pem").read_text(), "sha256": ca_fingerprint()}
    with mutation_lock(wait_seconds=2) as lock:
        RUN.mkdir(parents=True, exist_ok=True, mode=0o700)
        if action == "tick":
            tick(lock)
            return {"reconciled": True}
        if action == "prepare":
            prepare_ca()
            atomic(EFFECTIVE, effective(validate(read(CONFIG, DEFAULT)), read(TRUST, {}), ca_fingerprint()))
            return {"prepared": True}
        if action == "private-backup":
            destination = Path(sys.argv[2])
            if not destination.is_absolute() or destination.parent.stat().st_mode & 0o077:
                raise ValueError("private_backup_directory_required")
            if not (CA / "mitmproxy-ca.pem").is_file():
                raise ValueError("ca_not_prepared")
            with destination.open("xb") as output:
                os.chmod(destination, 0o600)
                import tarfile
                with tarfile.open(fileobj=output, mode="w:gz") as archive:
                    for path in (CONFIG, TRUST, CA):
                        if path.exists():
                            archive.add(path, arcname=str(path.relative_to(BASE)))
                output.flush()
                os.fsync(output.fileno())
            return {"private_backup_created": True, "ca_sha256": ca_fingerprint()}
        if action == "bypass":
            gateway.bypass()
            return {"intercepting": False}
        if action == "suspend":
            previous = read(STATE, {})
            request = read(Path(sys.argv[2]), {}).get("request", {}) if len(sys.argv) > 2 else {}
            service = subprocess.run(["ubus", "call", "service", "list", '{"name":"opl-netfleet-compat"}'],
                                     check=True, capture_output=True, text=True, timeout=1)
            instances = json.loads(service.stdout).get("opl-netfleet-compat", {}).get("instances", {})
            saved = previous.get("suspended")
            if saved:
                saved = {**saved, "keep_maintenance": saved.get("keep_maintenance", True) or request.get("lifecycle") is not True}
            else:
                saved = {"revision": revision(), "requested": read(CONFIG, DEFAULT)["enabled"],
                         "running": any(item.get("running") for item in instances.values()),
                         "keep_maintenance": bool(previous.get("maintenance")) or request.get("lifecycle") is not True}
            recovery = {**previous.get("recovery", {}), "intercepting": False, "healthy_since": None}
            save_state({**previous, "recovery": recovery, "suspended": saved, "maintenance": True,
                        "intercepting": False, "reason": "maintenance"}, previous)
            drain()
            gateway.remove()
            if instances:
                subprocess.run(["ubus", "call", "service", "delete", '{"name":"opl-netfleet-compat"}'], check=True, capture_output=True, timeout=2)
            return saved
        if action == "resume":
            saved = read(Path(sys.argv[2]), {}).get("request", {})
            previous = read(STATE, {})
            if saved.get("running") and saved.get("requested") and saved.get("revision") == revision() and read(CONFIG, DEFAULT)["enabled"]:
                keep_maintenance = saved.get("keep_maintenance", True)
                if keep_maintenance:
                    previous["maintenance"] = True
                else:
                    previous.pop("maintenance", None)
                previous.pop("suspended", None)
                recovery = {**previous.get("recovery", {}), "intercepting": False, "healthy_since": None}
                reason = "maintenance" if keep_maintenance else "manual_recovery_required" if recovery.get("latched") else "recovering"
                save_state({**previous, "recovery": recovery, "intercepting": False, "reason": reason}, previous)
                subprocess.run([SERVICE, "start"], check=True, capture_output=True, timeout=3)
            return {"intercepting": False}
        if action in ("drain", "remove"):
            previous = read(STATE, {})
            recovery = {**previous.get("recovery", {}), "intercepting": False, "healthy_since": None}
            save_state({**previous, "recovery": recovery, "maintenance": True, "intercepting": False, "reason": "maintenance"}, previous)
            result = drain(None if sys.argv[2:] == ["--wait"] else 30)
            if action == "remove":
                gateway.remove()
            return result
        request = read(Path(sys.argv[2]), {}).get("request", {})
        if action in ("apply", "enable", "disable"):
            return apply(action, request)
        if action == "probe":
            if request.get("revision") != revision():
                raise ValueError("compatibility_revision_conflict")
            if request.get("operation") in ("trust_record", "trust_revoke"):
                return trust_action(request)
            if request.get("operation") == "recover":
                state = read(STATE, {})
                if request.get("rule"):
                    identity = request["rule"]
                    old = state.setdefault("rule_recovery", {}).get(identity, {})
                    last_error = max([old.get("last_error", 0), *[event["id"] for event in engine_health().get("failure_events", []) if event["rule"] == identity]])
                    state["rule_recovery"][identity] = {"last_error": last_error}
                else:
                    state.pop("recovery", None)
                    state.pop("unhealthy_since", None)
                    state.pop("engine_restart", None)
                    state.pop("maintenance", None)
                atomic(STATE, state)
            return status()
        raise ValueError("unknown_compatibility_action")


if __name__ == "__main__":
    try:
        print(json.dumps({"ok": True, "result": main()}))
    except (OSError, ValueError, RuntimeError, KeyError, subprocess.SubprocessError) as error:
        code = str(error) if isinstance(error, ValueError) and str(error).replace("_", "").isalnum() else "compatibility_operation_failed"
        print(json.dumps({"ok": False, "error": code}))
        sys.exit(1)
