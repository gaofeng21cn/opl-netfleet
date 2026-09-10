import * as fs from 'fs';
import { sha256 } from 'digest';

return function(options) {
    const BASE = options.base, RUN = options.run, HELPER = options.helper;
    const TTL = 120, INTERVAL = 30, MAX_BODY = 2097152;
    const DEFAULT = {enabled: false, source: 'local', interfaces: []};
    const quote = value => `'${replace(`${value}`, "'", "'\\''")}'`;
    function read(path, fallback) {
        const info = fs.stat(path);
        if (info?.type != 'file' || info.size > MAX_BODY) return fallback;
        try { return json(fs.readfile(path)); } catch (_) { return fallback; }
    }
    function mkdir(path) {
        if (fs.stat(path)?.type == 'directory') return;
        const parent = replace(path, /\/[^/]+$/, '');
        if (parent && parent != path) mkdir(parent);
        if (!fs.mkdir(path, 0700)) die('identity_storage_unavailable');
    }
    function atomic(path, value) {
        mkdir(replace(path, /\/[^/]+$/, ''));
        const temporary = `${path}.new`, content = sprintf('%J', value);
        if (fs.lstat(temporary) != null) fs.unlink(temporary);
        const out = fs.open(temporary, 'w', 0600);
        if (!out) die('identity_storage_unavailable');
        const written = out.write(content), closed = out.close();
        const committed = written == length(content) && closed &&
            (index(path, BASE + '/') == 0
                ? system(`timeout -k 1 3 ${quote(replace(HELPER, /neighbor$/, 'atomic-replace'))} ${quote(fs.dirname(path))} ${quote(fs.basename(temporary))} ${quote(fs.basename(path))} >/dev/null 2>&1`) == 0
                : fs.rename(temporary, path));
        if (!committed) {
            fs.unlink(temporary); die('identity_storage_unavailable');
        }
    }
    function command(args, limit) {
        const pipe = fs.popen(`timeout -k 1 ${limit ?? 1} ${join(' ', map(args, quote))} 2>/dev/null`);
        if (!pipe) die('source_unavailable');
        const raw = pipe.read(MAX_BODY + 1), status = pipe.close();
        if (status == 124 || status == 137) die('source_timeout');
        if (status || raw == null) die('source_unavailable');
        if (length(raw) > MAX_BODY) die('local_response_too_large');
        return raw;
    }
    function canonical(value) {
        if (type(value) == 'object') return '{' + join(',', map(sort(keys(value)), key => sprintf('%J', key) + ':' + canonical(value[key]))) + '}';
        if (type(value) == 'array') return '[' + join(',', map(value, canonical)) + ']';
        return sprintf('%J', value);
    }
    function digest(value) {
        const result = sha256(canonical(value));
        if (!result) die('identity_digest_failed');
        return result;
    }
    function supported(config) { return config?.source == 'local'; }
    function binding(config) { return supported(config) ? digest({source: 'local', interfaces: config.interfaces}) : null; }
    function revision(config) { return digest(config); }
    function mac(value) {
        if (type(value) != 'string' || !match(value, /^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$/) ||
            int(substr(value, 0, 2), 16) & 1 || lc(value) == '00:00:00:00:00:00') die('invalid_device_mac');
        return lc(value);
    }
    function address(value) {
        if (type(value) != 'string' || index(value, '%') >= 0) return null;
        const bytes = iptoarr(value);
        if (!bytes || !length(filter(bytes, x => x != 0))) return null;
        if (length(bytes) == 4) {
            if (bytes[0] == 127 || bytes[0] >= 224 || bytes[0] == 169 && bytes[1] == 254) return null;
        } else if (bytes[0] == 255 || bytes[0] == 254 && (bytes[1] & 192) == 128 ||
            !length(filter(slice(bytes, 0, 15), x => x != 0)) && bytes[15] == 1 ||
            !length(filter(slice(bytes, 0, 10), x => x != 0)) && bytes[10] == 255 && bytes[11] == 255) return null;
        return arrtoip(bytes);
    }
    const monotonic = options.monotonic ?? (() => +split(fs.readfile('/proc/uptime'), ' ')[0]);
    function validate(value) {
        if (type(value) != 'object' || !supported(value) || type(value.enabled) != 'bool') die('invalid_source_config');
        const interfaces = value.interfaces ?? [];
        if (type(interfaces) != 'array' || length(interfaces) > 16 || length(filter(interfaces, x => type(x) != 'string' || !match(x, /^[A-Za-z0-9_.:-]{1,15}$/)))) die('invalid_source_interfaces');
        if (value.enabled && !length(interfaces)) die('source_interface_required');
        return {enabled: value.enabled, source: 'local', interfaces: sort(uniq(interfaces))};
    }
    function status(config) {
        const loaded = read(`${BASE}/loaded.json`, false) === true;
        const cache = read(`${RUN}/cache.json`, {}), rev = revision(config), same = cache.revision == rev;
        const now = monotonic(), age = now - (cache.monotonic ?? -TTL);
        const fresh = supported(config) && loaded && config.enabled && same && age >= 0 && age < TTL;
        const devices = map(same ? cache.devices ?? [] : [], row => {
            const remaining = {};
            for (let ip in row.addresses ?? []) {
                const expiry = row.address_expires?.[ip] ?? cache.monotonic + row.ttl;
                const maximum = cache.monotonic + TTL, deadline = min(expiry, maximum);
                // Accept JSON floating-point rounding, but keep the original TTL cap.
                if (deadline > now && expiry <= maximum + 0.000001) remaining[ip] = deadline - now;
            }
            return {mac: row.mac, name: row.name, addresses: fresh ? sort(keys(remaining)) : [], ttl: row.ttl,
                expires_in: fresh && length(remaining) ? int(min(...values(remaining)) + 0.999999) : 0,
                reason: fresh && (length(remaining) || row.reason) ? row.reason : 'address_evidence_expired'};
        });
        const attempt = read(`${RUN}/attempt.json`, {});
        return {loaded, ready: loaded, source_ready: !!fresh, config_revision: rev, binding: binding(config),
            config: {source: config.source, enabled: config.enabled, interfaces: config.interfaces ?? []},
            devices, reason: !supported(config) ? 'source_not_supported' : !loaded || !config.enabled ? 'source_disabled' :
                attempt.revision == rev && attempt.reason ? attempt.reason : fresh ? null : 'address_evidence_expired',
            last_attempt: attempt.revision == rev ? attempt.at : null, last_success: same ? cache.at : null};
    }
    function publish(config) {
        const current = status(config), cache = read(`${RUN}/cache.json`, {}), now = monotonic();
        const devices = [];
        if (current.source_ready) for (let row in cache.devices ?? []) {
            const expires = {};
            for (let ip in row.addresses ?? []) {
                const expiry = min(row.address_expires?.[ip] ?? cache.monotonic + row.ttl, cache.monotonic + TTL);
                if (now < expiry && expiry <= now + TTL) expires[ip] = expiry;
            }
            push(devices, {mac: row.mac, address_expires: expires});
        }
        atomic(`${RUN}/evidence.json`, {schema: 1, binding: current.binding, sampled_monotonic: cache.monotonic ?? now,
            source_ready: current.source_ready, devices});
    }
    function unique_devices(devices) {
        const owners = {}, ids = {};
        for (let row in devices) {
            ids[row.mac] = (ids[row.mac] ?? 0) + 1;
            for (let ip in row.addresses) { owners[ip] ??= {}; owners[ip][row.mac] = true; }
        }
        return map(devices, row => {
            const accepted = filter(row.addresses, ip => ids[row.mac] == 1 && length(owners[ip]) == 1);
            return {...row, addresses: accepted, reason: length(accepted) != length(row.addresses) || ids[row.mac] != 1 ? 'address_identity_conflict' : row.reason};
        });
    }
    const ip_command = options.ip_command ?? (args => json(command(['ip', '-j', ...args])));
    function connection_addresses() {
        const raw = command(['conntrack', '-L', '-f', 'ipv6', '-o', 'extended']);
        const result = [];
        for (let line in split(raw, '\n')) {
            // conntrack prints original tuple first. Never consume reply source.
            const source = match(line, /(^|\s)src=([^[:space:]]+)/);
            if (source) push(result, source[2]);
        }
        return result;
    }
    function local(config) {
        const devices = {}, now = monotonic(), neighbours = slice(ip_command(['neigh', 'show']), 0, 1024);
        function device(identity) {
            devices[identity] ??= {mac: identity, name: identity, addresses: [], address_expires: {}, ttl: TTL, reason: null};
            return devices[identity];
        }
        for (let row in neighbours) {
            if (index(config.interfaces, row.dev) < 0 || !length(filter(row.state ?? [], s => index(['REACHABLE','DELAY','PROBE'], s) >= 0))) continue;
            const ip = address(row.dst); let identity;
            try { identity = mac(row.lladdr); } catch (_) { continue; }
            if (!ip) continue;
            const routes = ip_command(['route', 'get', ip]);
            if (length(routes) != 1 || routes[0].gateway || routes[0].dev != row.dev || (routes[0].type ?? 'unicast') != 'unicast') continue;
            const item = device(identity); push(item.addresses, ip); item.address_expires[ip] = now + TTL;
        }
        const links = [];
        for (let row in ip_command(['address', 'show'])) {
            if (index(config.interfaces, row.ifname) < 0 || index(row.flags ?? [], 'UP') < 0) continue;
            const sources = filter(row.addr_info ?? [], ip => ip.family == 'inet6' && ip.scope == 'link' && !ip.tentative && !ip.dadfailed);
            if (length(sources) && row.address) push(links, [row.ifname, sources[0].local, mac(row.address)]);
        }
        if (!length(links)) die('local_observation_interface_unavailable');
        const current = read(`${RUN}/cache.json`, {});
        const previous = current.revision == revision(config) ? current.devices ?? [] : [];
        let candidates = map(neighbours, row => row.dst);
        for (let row in previous) push(candidates, ...row.addresses);
        push(candidates, ...(options.connections ? options.connections() : connection_addresses()));
        candidates = sort(uniq(filter(map(candidates, address), ip => ip && index(ip, ':') >= 0)));
        const cursor = read(`${RUN}/cursor.json`, 0) % max(1, length(candidates));
        const selected = slice([...slice(candidates, cursor), ...slice(candidates, 0, cursor)], 0, 64);
        let args = [HELPER]; for (let link in links) push(args, ...link);
        push(args, '--', ...selected);
        const confirmed = options.observe ? options.observe(links, selected) : json(command(args, 1));
        if (type(confirmed) != 'array' || length(confirmed) > 256) die('local_response_too_large');
        atomic(`${RUN}/cursor.json`, cursor + length(selected));
        for (let row in previous) for (let ip in row.addresses) {
            const expiry = row.address_expires?.[ip] ?? current.monotonic + row.ttl;
            if (index(selected, ip) >= 0 || !(now < expiry && expiry <= now + TTL)) continue;
            const item = device(row.mac);
            if (index(item.addresses, ip) < 0) { push(item.addresses, ip); item.address_expires[ip] = expiry; }
        }
        for (let item in values(devices)) item.addresses = filter(item.addresses, ip => index(selected, ip) < 0);
        for (let pair in confirmed) {
            if (type(pair) != 'array' || length(pair) != 2 || index(selected, pair[0]) < 0) die('local_response_invalid');
            const item = device(mac(pair[1])); push(item.addresses, pair[0]); item.address_expires[pair[0]] = now + TTL;
        }
        for (let item in values(devices)) {
            item.addresses = sort(uniq(item.addresses));
            for (let ip in keys(item.address_expires)) if (index(item.addresses, ip) < 0) delete item.address_expires[ip];
        }
        return unique_devices(values(devices));
    }
    function sync(config) {
        if (!supported(config)) { fs.unlink(`${RUN}/evidence.json`); return status(config); }
        if (!config.enabled) return status(config);
        const rev = revision(config), previous = read(`${RUN}/attempt.json`, {}), now = monotonic();
        if (previous.revision == rev && now >= previous.monotonic && now - previous.monotonic < INTERVAL) { publish(config); return status(config); }
        const attempt = {revision: rev, at: time(), monotonic: now, reason: null};
        atomic(`${RUN}/attempt.json`, attempt);
        try {
            const devices = local(config);
            if (length(devices) > 256) die('too_many_source_devices');
            atomic(`${RUN}/cache.json`, {...attempt, devices});
        } catch (error) { attempt.reason = match(error.message ?? '', /^[a-z_]+$/) ? error.message : 'source_unavailable'; }
        atomic(`${RUN}/attempt.json`, attempt); publish(config); return status(config);
    }
    function dispatch(action, params) {
        let config = read(`${BASE}/config.json`, DEFAULT);
        if (action == 'get' || action == 'resolve') return status(config);
        mkdir(RUN); const lock = fs.open(`${RUN}/lock`, 'ae', 0600);
        if (!lock || !lock.lock('xn')) { if (lock) lock.close(); if (action == 'sync') return status(config); die('identity_mutation_busy'); }
        function locked() {
            config = read(`${BASE}/config.json`, DEFAULT);
            if (action == 'load' || action == 'unload') {
                fs.unlink(`${RUN}/evidence.json`); atomic(`${BASE}/loaded.json`, action == 'load');
                if (action == 'unload') { fs.unlink(`${RUN}/cache.json`); fs.unlink(`${RUN}/session.json`); }
                return status(config);
            }
            if (read(`${BASE}/loaded.json`, false) !== true) die('identity_plugin_not_loaded');
            if (action == 'sync') return sync(config);
            if (action != 'configure') die('unknown_identity_action');
            if (params.config_revision != revision(config)) die('identity_revision_conflict');
            config = validate(params.config); fs.unlink(`${RUN}/evidence.json`); atomic(`${BASE}/config.json`, config);
            fs.unlink(`${RUN}/session.json`);
            return status(config);
        }
        let result, failure;
        try { result = locked(); } catch (error) { failure = error; }
        lock.lock('u'); lock.close();
        if (failure) die(failure.message);
        return result;
    }
    return {dispatch, validate, address, mac, local, unique_devices, revision, binding, status, atomic, read, sync, publish};
};
