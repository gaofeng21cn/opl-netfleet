/* SPDX-License-Identifier: Apache-2.0 */
return function(context) {
	function copy(value) { return value == null ? null : json(sprintf('%J', value)); }
	// This registry is consumed by validation, persistence, provenance and both editors.
	const definitions = [
		['dns.enhanced-mode', 'DNS', '解析模式', 'dns_mode', ['redir-host', 'fake-ip']],
		['dns.ipv6', 'DNS', '返回 IPv6 地址', 'dns_ipv6', 'bool'],
		['dns.cache-algorithm', 'DNS', '缓存算法', 'dns_cache_algorithm', ['lru', 'arc']],
		['dns.respect-rules', 'DNS', 'DNS 连接遵循路由规则', 'dns_respect_rules', 'bool'],
		['dns.prefer-h3', 'DNS', 'DoH 优先 HTTP/3', 'dns_doh_prefer_http3', 'bool'],
		['dns.use-system-hosts', 'DNS', '读取系统 hosts', 'dns_system_hosts', 'bool'],
		['dns.use-hosts', 'DNS', '使用配置 hosts', 'dns_hosts', 'bool'],
		['dns.direct-nameserver-follow-policy', 'DNS', '直连 DNS 遵循域名策略', 'dns_direct_nameserver_follow_policy', 'bool'],
		['dns.fake-ip-range', 'DNS', 'Fake-IP IPv4 网段', 'fake_ip_range', 'cidr4'],
		['dns.fake-ip-range6', 'DNS', 'Fake-IP IPv6 网段', 'fake_ip6_range', 'cidr6'],
		['dns.fake-ip-ttl', 'DNS', 'Fake-IP TTL（秒）', 'fake_ip_ttl', 'int', 1, 86400],
		['dns.fake-ip-filter-mode', 'DNS', 'Fake-IP 过滤方式', 'fake_ip_filter_mode', ['blacklist', 'whitelist', 'rule']],
		['dns.fake-ip-filter', 'DNS', 'Fake-IP 过滤项', 'fake_ip_filter', 'list'],
		['profile.store-fake-ip', 'DNS', '保存 Fake-IP 缓存', 'fake_ip_cache', 'bool'],
		['sniffer.enable', '嗅探', '启用协议嗅探', 'sniffer', 'bool'],
		['sniffer.force-dns-mapping', '嗅探', '对 DNS 映射嗅探', 'sniffer_sniff_dns_mapping', 'bool'],
		['sniffer.parse-pure-ip', '嗅探', '对纯 IP 流量嗅探', 'sniffer_sniff_pure_ip', 'bool'],
		['sniffer.force-domain', '嗅探', '强制嗅探域名', 'sniffer_force_domain_name', 'list'],
		['sniffer.skip-domain', '嗅探', '跳过嗅探域名', 'sniffer_ignore_domain_name', 'list'],
		['sniffer.sniff', '嗅探', '协议与端口（JSON）', 'sniffer_sniff', 'sniff'],
		['tcp-concurrent', '连接', 'TCP 并发连接', 'tcp_concurrent', 'bool'],
		['unified-delay', '连接', '统一延迟测量', 'unify_delay', 'bool'],
		['disable-keep-alive', '连接', '禁用 TCP 保活', 'disable_tcp_keep_alive', 'bool'],
		['keep-alive-idle', '连接', 'TCP 空闲保活（秒）', 'tcp_keep_alive_idle', 'int', 1, 3600],
		['keep-alive-interval', '连接', 'TCP 保活间隔（秒）', 'tcp_keep_alive_interval', 'int', 1, 3600],
		['find-process-mode', '连接', '进程匹配', 'match_process', ['off', 'strict', 'always']],
		['log-level', '连接', '核心日志级别', 'log_level', ['silent', 'error', 'warning', 'info', 'debug']],
		['geodata-mode', '规则数据', '使用 GeoIP DAT 格式', 'geoip_format', 'bool'],
		['geodata-loader', '规则数据', 'GeoData 加载方式', 'geodata_loader', ['standard', 'memconservative']],
		['geo-auto-update', '规则数据', '自动更新 GeoData', 'geox_auto_update', 'bool'],
		['geo-update-interval', '规则数据', 'GeoData 更新间隔（小时）', 'geox_update_interval', 'int', 1, 720]
	];
	const registry = map(definitions, d => ({ id: d[0], path: split(d[0], '.'), group: d[1], label: d[2],
		uci: d[3], kind: type(d[4]) == 'array' ? 'enum' : d[4], options: type(d[4]) == 'array' ? d[4] : null, min: d[5], max: d[6] }));
	function value(profile, path) {
		let result = profile;
		for (let name in path) { if (type(result) != 'object') return null; result = result[name]; }
		return copy(result);
	}
	function assign(profile, path, next) {
		let node = profile;
		for (let i = 0; i < length(path)-1; i++) {
			if (type(node[path[i]]) != 'object') node[path[i]] = {};
			node = node[path[i]];
		}
		if (next == null) delete node[path[length(path)-1]];
		else node[path[length(path)-1]] = copy(next);
	}
	function project(profile) {
		const result = {};
		for (let field in registry) result[field.id] = value(profile, field.path);
		return result;
	}
	function fields() {
		return map(registry, field => { const result = copy(field); delete result.uci; return result; });
	}
	function changes(before, after) {
		return filter(registry, field => sprintf('%J', before?.[field.id]) != sprintf('%J', after?.[field.id]));
	}
	function validate(input, errors, valid_address) {
		if (type(input) != 'object' || length(sprintf('%J', input)) > 32768) {
			push(errors, { path: 'advanced', reason: 'bounded_object_required' }); return;
		}
		const ids = map(registry, field => field.id);
		for (let id in keys(input)) if (index(ids, id) < 0) push(errors, { path: `advanced.${id}`, reason: 'unknown_field' });
		function text(item) { return type(item) == 'string' && length(item) > 0 && length(item) <= 512 && !match(item, /[[:cntrl:]]/); }
		for (let field in registry) {
			const next = input[field.id];
			if (next == null) continue;
			let ok = false;
			if (field.kind == 'bool') ok = type(next) == 'bool';
			else if (field.kind == 'int') ok = type(next) == 'int' && next >= field.min && next <= field.max;
			else if (field.kind == 'enum') ok = index(field.options, next) >= 0;
			else if (field.kind == 'cidr4') ok = text(next) && index(next, '/') >= 0 && valid_address(next, 4);
			else if (field.kind == 'cidr6') ok = text(next) && index(next, '/') >= 0 && valid_address(next, 6);
			else if (field.kind == 'list') ok = type(next) == 'array' && length(next) <= 256 && length(filter(next, item => !text(item))) == 0;
			else if (field.kind == 'sniff') {
				ok = type(next) == 'object';
				for (let protocol, settings in type(next) == 'object' ? next : {}) {
					if (index(['HTTP','TLS','QUIC'], protocol) < 0 || type(settings) != 'object') { ok = false; continue; }
					for (let key in keys(settings)) if (index(['port','override-destination'], key) < 0) ok = false;
					if (settings['override-destination'] != null && type(settings['override-destination']) != 'bool') ok = false;
					if (type(settings.port) != 'array' || length(settings.port) > 64) ok = false;
					else for (let port in settings.port) {
						const ends = split(`${port}`, '-');
						if ((type(port) != 'int' && type(port) != 'string') || !match(`${port}`, /^[0-9]+(-[0-9]+)?$/) ||
							int(ends[0]) < 1 || int(ends[length(ends)-1]) > 65535 || int(ends[0]) > int(ends[length(ends)-1])) ok = false;
					}
				}
			}
			if (!ok) push(errors, { path: `advanced.${field.id}`, reason: 'invalid_value' });
		}
	}
	function render(original, before, after, inherited) {
		const result = copy(original);
		for (let field in changes(before, after)) assign(result, field.path, after[field.id] ?? value(inherited, field.path));
		return result;
	}
	function persist(extra, uci, before, after) {
		for (let field in changes(before, after)) {
			assign(extra, field.path, after[field.id]);
			uci.delete('netfleet', 'mixin', field.uci);
			if (field.id == 'sniffer.sniff') {
				if (after[field.id] == null) delete extra['netfleet-replace-sniff'];
				else extra['netfleet-replace-sniff'] = true;
			}
		}
	}
	function explain(profile, source, extra, sections, running) {
		const mixin = filter(sections, section => section['.name'] == 'mixin')[0] ?? {};
		return map(registry, field => ({ id: field.id, label: field.label, configured: value(profile, field.path),
			source: (field.kind == 'list' || field.kind == 'sniff' ? `${mixin[field.uci] ?? '0'}` == '1' : mixin[field.uci] != null) ? 'platform' : value(extra, field.path) != null ? 'override' :
				value(source, field.path) != null ? 'profile' : 'core_default',
			running: running == null ? null : value(running, field.path), active: running != null }));
	}
	function difference(before, after, profile, inherited) {
		const rendered = render(profile, before, after, inherited);
		return map(changes(before, after), field => ({ id: field.id, label: field.label, before: value(profile, field.path),
			after: value(rendered, field.path), inherited: after[field.id] == null }));
	}
	return { fields, project, validate, render, persist, explain, difference };
};
