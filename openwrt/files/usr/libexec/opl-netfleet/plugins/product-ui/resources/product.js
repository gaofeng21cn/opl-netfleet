/* SPDX-License-Identifier: Apache-2.0 */
'use strict';
'require baseclass';

function targetHost(input) {
	const value = input.trim();
	if (!value || value.length > 2048 || /\s/.test(value)) return null;
	try {
		const address = value.includes('://') ? value : 'https://' + (value.includes(':') && !value.includes('/') && !value.startsWith('[') && value.split(':').length > 2 ? '[' + value + ']' : value);
		const url = new URL(address);
		if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) return null;
		return url.hostname.toLowerCase().replace(/\.$/, '').replace(/^\[|\]$/g, '') || null;
	} catch (_) { return null; }
}

function diagnose(status, snapshot, query, error, stale) {
	const host = targetHost(query);
	const ip = host != null && (host.includes(':') || /^\d+\.\d+\.\d+\.\d+$/.test(host));
	const matches = host ? (snapshot.connections || []).filter(function(item) {
		const destination = targetHost(item.destination);
		return destination === host || (!ip && destination && destination.endsWith('.' + host));
	}) : [];
	const runtime = status.runtime;
	const lan = runtime.lan_runtime || {};
	function state(ready) { return stale ? '需要重新读取' : ready === true ? '已就绪' : ready === false ? '未就绪' : '未取得状态'; }
	const checks = [
		{ label: 'Mihomo', value: state(runtime.mihomo_running) },
		{ label: '控制接口', value: state(runtime.controller_available) },
		{ label: 'DNS 接入', value: state(lan.dns_ready) },
		{ label: '透明代理', value: state(lan.transparent_proxy_ready) }
	];
	let message = '输入目标域名或 IP，查看当前连接的实际命中结果。';
	if (query.trim() && !host) message = '请输入有效域名、IP 或 HTTP/HTTPS 地址，不包含账户凭据。';
	else if (stale) message = '设备状态不是最新读取结果，请先重新读取；以下连接不能作为当前网络结论。';
	else if (error) message = '当前连接读取失败，不能判断此网站的实际链路。';
	else if (host) message = matches.length ? '捕获到 ' + matches.length + ' 条相关连接；连接存在不代表请求成功或速度达标。'
		: '当前快照没有捕获到相关连接，不代表网站不可达。连接可能已结束、未进入代理，或仅记录了 IP。';
	const next = stale || error ? '重新读取状态；若仍失败，查看核心启动与运行日志。'
		: runtime.mihomo_running === false ? '核心未运行，先查看启动日志；不要通过反复更新订阅恢复。'
			: runtime.controller_available === false ? '核心控制接口不可读，先查看核心日志和监听配置。'
				: status.active && (lan.dns_ready === false || lan.transparent_proxy_ready === false)
					? '检查网络接入配置与接管状态；此处不能判断具体域名是否解析成功。'
					: host && !matches.length ? '在发生问题的设备上再次访问目标，然后重新读取；更多连接请打开 Zashboard。'
						: '对照下方实际规则与链路；涉及协议或长连接时，可继续查看 HTTPS 兼容诊断。';
	return { host: host, matches: matches, checks: checks, message: message, next: next, truncated: snapshot.truncated, readAt: snapshot.read_at };
}

function diagnosis(controller, displayName) {
	const result = diagnose(controller.status, controller.connections, controller.diagnosisQuery || '', controller.connectionsError, !controller.liveDataReady);
	const input = E('input', { id: 'netfleet-diagnosis-target', type: 'text', 'class': 'cbi-input-text', maxlength: 2048, value: controller.diagnosisQuery || '', placeholder: 'example.com' });
	const loading = controller.connectionsLoading || controller.refreshing;
	return E('section', { 'class': 'cbi-section netfleet-network-diagnosis', 'aria-label': '网站诊断' }, [
		E('div', { 'class': 'netfleet-section-heading' }, [ E('h3', {}, '网站诊断'), E('button', { 'class': 'btn cbi-button', disabled: loading || null, click: function() { return controller.refreshData(true); } }, loading ? '正在读取' : '重新读取') ]),
		E('form', { 'class': 'netfleet-diagnosis-query', submit: function(event) {
			event.preventDefault(); controller.diagnosisQuery = targetHost(input.value) || input.value; controller.redraw();
		} }, [ E('label', { for: 'netfleet-diagnosis-target' }, '目标网站或 IP'), input, E('button', { 'class': 'btn cbi-button', type: 'submit', disabled: loading || null }, '查看链路') ]),
		E('dl', { 'class': 'netfleet-diagnosis-checks' }, result.checks.map(function(check) { return E('div', {}, [ E('dt', {}, check.label), E('dd', {}, check.value) ]); })),
		E('p', { 'class': 'netfleet-connection-note' }, (controller.status.active ? '当前由 NetFleet 接管。' : 'NetFleet 当前未接管，连接由现有运行配置负责。') + ' DNS 接入就绪不等于此网站解析成功。'),
		E('div', { role: 'status' }, [ E('p', {}, loading ? '正在读取当前设备证据…' : result.message), E('p', {}, result.next) ]),
		result.host && result.matches.length ? E('div', { 'class': 'netfleet-table-wrap' }, E('table', { 'class': 'table' }, [
			E('thead', {}, E('tr', {}, ['目标', '协议 / 端口', '实际命中规则', '实际链路'].map(function(label) { return E('th', {}, label); }))),
			E('tbody', {}, result.matches.map(function(item) { return E('tr', {}, [
				E('td', {}, item.destination), E('td', {}, [item.network && item.network.toUpperCase(), item.destination_port].filter(Boolean).join(' / ') || '未记录'),
				E('td', {}, [item.rule, item.rule_payload].filter(Boolean).join(' / ') || '未记录'),
				E('td', {}, (item.chains || []).map(function(value) { return value === 'DIRECT' ? '直连' : displayName(value); }).join(' → ') || '未记录链路')
			]); }))
		])) : '',
		E('p', { 'class': 'netfleet-connection-note' }, '连接读取：' + (result.readAt ? new Date(result.readAt * 1000).toLocaleString() : '尚无读取时间') + (result.truncated ? '；快照最多包含 50 条连接，不是全部连接。' : ''))
	]);
}

function networkChanges(before, after) {
	return [['dns', 'DNS 解析'], ['lan', '局域网接入与设备规则'], ['router', '路由器本机代理'], ['listeners', '代理监听与认证']].filter(function(item) {
		return JSON.stringify(before[item[0]]) !== JSON.stringify(after[item[0]]);
	}).map(function(item) { return item[1]; });
}

function resultText(title, result) {
	if (result && result.state === 'unchanged') return title + '：配置未变化，未重载网络。';
	if (result && result.state === 'saved') return title + '：已保存，当前网络未改变。';
	return title + '已完成';
}

return baseclass.extend({ targetHost: targetHost, diagnose: diagnose, diagnosis: diagnosis, networkChanges: networkChanges, resultText: resultText });
