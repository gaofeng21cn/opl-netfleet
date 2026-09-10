return function() {
    function source_ports(profile) {
        const ports = [];
        for (let rule in profile.rules ?? []) if (type(rule) == 'string' && index(rule,'SRC-PORT,') == 0) {
            const fields=split(rule,',');
            if (length(fields)!=3 || !match(fields[1],/^[0-9]{1,5}$/) || +fields[1]<1 || +fields[1]>65535) die('source_port_rule_unsupported');
            push(ports,+fields[1]);
        }
        return sort(uniq(ports),(a,b)=>a-b);
    }
    function egress_policy(profile, ephemeral) {
        const excluded=source_ports(profile);
        if (!length(excluded)) return {excluded_ports:[],port_range:null};
        const lower=ephemeral[0],upper=ephemeral[1];
        if (!(lower>=1 && lower<upper && upper<=65535)) die('egress_port_range_unavailable');
        const bounds=[lower-1,...filter(excluded,p=>p>=lower && p<=upper),upper+1];
        let best=null;
        for (let i=1;i<length(bounds);i++) {
            const pair=[bounds[i-1]+1,bounds[i]-1];
            if (bounds[i]-bounds[i-1]>2 && (best==null || pair[1]-pair[0]>best[1]-best[0])) best=pair;
        }
        if (!best) die('egress_port_range_unavailable');
        return {excluded_ports:excluded,port_range:best};
    }
    function admission(profile,gateway) {
        if (gateway.backend!='native-mihomo' || !gateway.ready) return 'native_gateway_not_ready';
        if (gateway.compatibility_ownership_guard!==true) return 'native_ownership_guard_missing';
        if (!gateway.router_proxy || !gateway.lan_proxy) return 'router_lan_paths_differ';
        if (gateway.source_bypass) return 'source_bypass_not_equivalent';
        if (gateway.custom_lan_access) return 'lan_access_not_equivalent';
        if (length(profile.listeners ?? []) || length(profile['sub-rules'] ?? {})) return 'custom_listeners_or_subrules';
        const safe=['DOMAIN','DOMAIN-SUFFIX','DOMAIN-KEYWORD','DOMAIN-REGEX','GEOSITE','IP-CIDR','IP-CIDR6','IP-SUFFIX','IP-ASN','GEOIP','DST-PORT','NETWORK','MATCH'];
        for (let rule in profile.rules ?? []) {
            if (type(rule)!='string') return 'routing_rule_unreadable';
            const fields=split(rule,','),kind=fields[0];
            if (kind=='SRC-PORT') { try { source_ports({rules:[rule]}); } catch (error) { return error.message; } }
            else if (kind=='RULE-SET') {
                const provider=profile['rule-providers']?.[fields[1]];
                if (index(['domain','ipcidr'],provider?.behavior)<0) return 'rule_provider_not_equivalent';
            } else if (index(safe,kind)<0) return 'source_or_unsupported_routing_rule';
        }
        return null;
    }
    return {source_ports,egress_policy,admission};
};
