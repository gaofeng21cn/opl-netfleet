return function() {
    function identifier(value) {
        if (type(value) != 'string' || !match(value, /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/)) die('invalid_id');
        return value;
    }
    function hostname(value) {
        if (type(value) != 'string') die('invalid_domain');
        value = lc(replace(value, /\.+$/, ''));
        if (length(value) > 253 || !length(value) || length(filter(split(value, '.'), label => !match(label, /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/)))) die('invalid_domain');
        if (iptoarr(value)) die('domain_required');
        return value;
    }
    function validate(config) {
        if (type(config) != 'object' || config.schema !== 1 || type(config.enabled) != 'bool' ||
            type(config.devices) != 'array' || type(config.rules) != 'array') die('invalid_config');
        if (length(config.devices) > 256 || length(config.rules) > 256) die('engine_configuration_limit');
        const ids = {}, addresses = {}, bindings = {}, targets = {}, rule_ids = {}, devices = [], rules = [];
        for (let device in config.devices) {
            if (type(device) != 'object') die('invalid_device');
            const id = identifier(device.id), binding = device.identity;
            if (ids[id] || type(device.name) != 'string' || !length(trim(device.name))) die('invalid_device');
            ids[id] = true;
            if (binding != null && (type(binding) != 'object' || length(keys(binding)) != 2 ||
                type(binding.binding) != 'string' || !match(binding.binding, /^[a-f0-9]{64}$/) ||
                type(binding.mac) != 'string' || !match(binding.mac, /^[a-f0-9]{2}(:[a-f0-9]{2}){5}$/) ||
                (int(substr(binding.mac, 0, 2), 16) & 1) || binding.mac == '00:00:00:00:00:00')) die('invalid_device_identity');
            if (type(device.addresses) != 'array' || !length(device.addresses) && binding == null) die('device_address_required');
            const parsed = [];
            for (let address in device.addresses) {
                if (type(address) != 'string' || index(address, '%') >= 0 || !iptoarr(address)) die('invalid_device_address');
                const normalized = arrtoip(iptoarr(address));
                if (addresses[normalized]) die('duplicate_device_address');
                addresses[normalized] = true; push(parsed, normalized);
            }
            if (binding) {
                const key = binding.binding + binding.mac;
                if (bindings[key]) die('duplicate_device_identity');
                bindings[key] = true;
            }
            push(devices, {id, name: device.name, addresses: parsed, ...(binding ? {identity: binding} : {})});
        }
        for (let rule in config.rules) {
            if (type(rule) != 'object') die('invalid_rule');
            const id = identifier(rule.id);
            if (rule_ids[id] || type(rule.name) != 'string' || !length(trim(rule.name)) || type(rule.enabled) != 'bool' ||
                index(['exact', 'suffix'], rule.match) < 0 || index(['h2', 'bypass'], rule.strategy) < 0) die('invalid_rule');
            rule_ids[id] = true;
            if (type(rule.port) != 'int' || rule.port < 1 || rule.port > 65535) die('invalid_port');
            if (type(rule.devices) != 'array' || !length(rule.devices) || length(uniq(rule.devices)) != length(rule.devices) ||
                length(filter(rule.devices, id => type(id) != 'string' || !ids[id]))) die('invalid_rule_devices');
            const domain = hostname(rule.domain);
            for (let device in rule.devices) {
                const key = sprintf('%J', [device, rule.port, rule.match, domain]);
                if (targets[key]) die('conflicting_rule');
                targets[key] = true;
            }
            push(rules, {id, name: rule.name, enabled: rule.enabled, devices: rule.devices, domain, match: rule.match, port: rule.port, strategy: rule.strategy});
        }
        return {schema: 1, enabled: config.enabled, devices, rules};
    }
    return {identifier, hostname, validate};
};
