'use strict';
'require baseclass';
'require ui';
'require netfleet.api as api';

function reason(value) {
	return ({ disabled: '已关闭', draining: '停止接管，正在排空', recovering: '健康观察中',
		rules_recovering: '规则恢复中', component_not_installed: '未安装可选组件',
		extension_component_not_installed: '未安装可选模块',
		extension_api_incompatible: '模块接口与当前 NetFleet 不兼容',
		extension_dependency_missing: '模块运行依赖缺失',
		extension_manifest_missing: '模块接口声明缺失',
		extension_manifest_invalid: '模块接口声明无效',
		extension_backend_unsupported: '当前后端不支持此模块',
		extension_owner_unavailable: '模块状态暂不可读取',
		extension_package_unknown: '模块安装版本尚未确认',
		ca_not_ready: 'CA 未就绪，当前旁路',
		lease_expired: '接管许可已到期', maintenance: '组件维护中，当前旁路', no_verified_targets: '没有已验证的接入目标',
		manual_recovery_required: '反复恢复后仍故障，等待人工恢复', rules_bypassed: '目标规则当前旁路，详见规则状态',
		historical_failure: '旧版本未记录具体原因', upstream_probe_timeout: '上游恢复探测超时', upstream_certificate_failed: '上游证书验证失败',
		upstream_h2_not_negotiated: '上游未协商 HTTP/2', upstream_connect_failed: '上游连接失败',
		upstream_tls_failed: '上游 TLS 握手失败', client_tls_failed: '客户端 TLS 握手失败',
		upstream_timeout: '上游传输超时', upstream_connection_reset: '上游连接被重置',
		upstream_transport_failed: '上游传输中断', client_cancelled: '客户端已取消', processing_chain_failed: '本地处理链异常',
		transparent_chain_failed: '透明接管入口异常，已旁路',
		engine_unavailable: '兼容引擎未就绪', engine_config_pending: '等待引擎载入配置',
		native_gateway_unavailable: '原生网关暂不可用', native_gateway_not_ready: '原生网关尚未就绪',
		native_ownership_guard_missing: '原生网关缺少连接归属保护',
		upstream_protocol_failed: '目标 TLS 或协议验证失败' })[value] || value || '正常';
}

function label(state) {
	if (!state) return '状态未读取';
	if (!state.installed) return '未安装';
	if (!state.requested) return state.active_connections > 0 ? '停止接管，仍有 ' + state.active_connections + ' 条连接' : '已关闭';
	return state.intercepting ? '正在接管' : '已开启，当前旁路';
}

function button(text, action, disabled) {
	return E('button', { 'class': 'btn cbi-button', 'type': 'button', 'disabled': disabled ? '' : null, 'click': action }, text);
}

function refresh(controller) {
	if (controller.compatibilityRead) return controller.compatibilityRead;
	controller.compatibilityRead = api.compatibilityGet().then(function(state) {
		controller.compatibility = state;
		controller.compatibilityError = null;
	}).catch(function(error) { controller.compatibilityError = error; }).finally(function() {
		controller.compatibilityRead = null;
		if (controller.currentView === 'components' && controller.componentDetail === 'https-compat') controller.redraw();
	});
	return controller.compatibilityRead;
}

function mutate(controller, method, request, revision) {
	if (mutationBlocked(controller, method)) return Promise.resolve();
	const expected = revision === undefined ? controller.compatibility.revision : revision;
	if (method === 'compatibilityDisable' || method === 'compatibilityProbe' && !request.operation)
		return executeMutation(controller, method, request, expected);
	return new Promise(function(resolve) {
		ui.showModal('确认 HTTPS 兼容变更', [
			E('p', {}, method === 'compatibilityDisable' ? '停止接管新连接，已有连接继续排空。' :
				request.operation === 'trust_revoke' ? '撤销该设备的新连接接管。本机 CA 信任由接入工具移除。' :
				request.config ? '保存 ' + request.config.rules.length + ' 条目标规则和 ' + request.config.devices.length + ' 台接入设备。' : '将更新兼容模块的接管状态。'),
			E('div', { 'class': 'right' }, [ button('取消', function() { ui.hideModal(); resolve(); }),
				button('确认', function() { ui.hideModal(); resolve(executeMutation(controller, method, request, expected)); }) ])
		]);
	});
}

function mutationBlocked(controller, method) {
	const state = controller.compatibility;
	return controller.compatibilityBusy || !state || !state.installed || !!controller.compatibilityError ||
		state.managed === false && method !== 'compatibilityDisable';
}

function executeMutation(controller, method, request, revision) {
	if (mutationBlocked(controller, method)) return Promise.resolve();
	controller.compatibilityBusy = true;
	controller.redraw();
	return api[method](Object.assign({ revision: revision }, request)).catch(function(error) {
		ui.addNotification(null, E('p', {}, 'HTTPS 兼容操作失败：' + error.message), 'error');
	}).then(async function() {
		await controller.compatibilityRead;
		return refresh(controller);
	}).finally(function() { controller.compatibilityBusy = false; controller.redraw(); });
}

function edit(controller, collection, item) {
	if (mutationBlocked(controller, 'compatibilityApply')) return;
	const state = controller.compatibility;
	const config = JSON.parse(JSON.stringify(state.config));
	const draft = item ? JSON.parse(JSON.stringify(item)) : collection === 'rules'
		? { id: '', name: '', domain: '', match: 'exact', port: 443, strategy: 'h2', enabled: true, devices: [] }
		: { id: '', name: '', addresses: [] };
	if (!item) draft.id = collection.slice(0, -1) + '-' + Array.from(crypto.getRandomValues(new Uint32Array(3)), value => value.toString(16)).join('');
	const controls = [];
	function field(key, title, type) {
		const input = E('input', {
			'class': 'cbi-input-text', 'value': Array.isArray(draft[key]) ? draft[key].join(', ') : draft[key],
			'type': type || 'text', 'required': true, 'min': type === 'number' ? 1 : null, 'max': type === 'number' ? 65535 : null,
			'input': function(event) { draft[key] = key === 'addresses' ? event.target.value.split(/[,\s]+/).filter(Boolean) : type === 'number' ? Number(event.target.value) : event.target.value.trim(); }
		});
		controls.push(input);
		return E('label', { 'class': 'netfleet-config-row' }, [ E('span', {}, title), input ]);
	}
	function select(key, title, choices) {
		return E('label', { 'class': 'netfleet-config-row' }, [ E('span', {}, title), E('select', {
			'class': 'cbi-input-select', 'change': function(event) { draft[key] = event.target.value; }
		}, choices.map(function(choice) { return E('option', { 'value': choice[0], 'selected': draft[key] === choice[0] ? '' : null }, choice[1]); })) ]);
	}
	const rows = [ field('name', '名称') ];
	if (collection === 'rules') rows.push(field('domain', '域名'), select('match', '匹配', [ [ 'exact', '精确域名' ], [ 'suffix', '域名后缀' ] ]),
		field('port', '端口', 'number'), select('strategy', '策略', [ [ 'h2', '上游 HTTP/2' ], [ 'bypass', '旁路' ] ]),
		E('div', { 'class': 'netfleet-config-row' }, [ E('span', {}, '接入设备'), E('div', {}, config.devices.map(function(device) {
			return E('label', { 'class': 'netfleet-check' }, [ E('input', { 'type': 'checkbox', 'checked': draft.devices.includes(device.id) ? '' : null, 'change': function(event) {
				draft.devices = draft.devices.filter(function(id) { return id !== device.id; });
				if (event.target.checked) draft.devices.push(device.id);
			} }), device.name ]);
		})) ]));
	else rows.push(field('addresses', 'IPv4 / IPv6 地址'));
	rows.push(E('div', { 'class': 'right' }, [ button('取消', function() { ui.hideModal(); }), button('保存', function() {
		if (controls.some(function(input) { return !input.reportValidity(); })) return;
		if (collection === 'rules' && !draft.devices.length) {
			ui.addNotification(null, E('p', {}, '请选择至少一台接入设备'), 'warning'); return;
		}
		const index = config[collection].findIndex(function(value) { return value.id === draft.id; });
		if (item) config[collection][index] = draft;
		else config[collection].push(draft);
		ui.hideModal();
		return executeMutation(controller, 'compatibilityApply', { config: config }, state.revision);
	}) ]));
	ui.showModal((item ? '编辑' : '新增') + (collection === 'rules' ? '目标规则' : '接入设备'), rows);
}

function download(name, value, type) {
	const url = URL.createObjectURL(new Blob([ value ], { type: type || 'application/json' }));
	const link = E('a', { 'href': url, 'download': name });
	document.body.appendChild(link); link.click(); link.remove();
	setTimeout(function() { URL.revokeObjectURL(url); }, 1000);
}

function render(controller) {
	const state = controller.compatibility;
	const back = button('返回组件列表', function() { controller.componentDetail = null; controller.redraw(); });
	const extension = ((controller.components || {}).extensions || []).find(item => item.id === 'https-compat');
	const heading = E('div', { 'class': 'netfleet-section-heading' }, [ E('div', {}, [ E('h3', {}, 'HTTPS 兼容'),
		extension ? E('small', {}, extension.installed_version || '未安装') : '' ]), E('div', { 'class': 'netfleet-inline-actions' }, [ back,
		E('a', { 'class': 'netfleet-dashboard-link', 'href': L.url('admin/system/package-manager'), 'target': '_blank', 'rel': 'noopener' }, '软件包管理') ]) ]);
	if (!state) return E('section', { 'class': 'netfleet-compatibility' }, [ heading, E('p', {}, controller.compatibilityError ? '状态读取失败' : '正在读取'), button('刷新', function() { return refresh(controller); }) ]);
	const busy = mutationBlocked(controller, 'compatibilityApply');
	const toggleBusy = mutationBlocked(controller, state.requested ? 'compatibilityDisable' : 'compatibilityEnable');
	function applyConfig(callback) {
		const config = JSON.parse(JSON.stringify(state.config)); callback(config);
		return mutate(controller, 'compatibilityApply', { config: config }, state.revision);
	}
	const config = state.config || { rules: [], devices: [] };
	const rules = config.rules.map(function(rule) {
		const result = (state.rules || {})[rule.id] || {};
		const recovery = (state.rule_recovery || {})[rule.id] || {};
		return E('tr', {}, [
			E('td', {}, E('input', { 'type': 'checkbox', 'aria-label': rule.name, 'checked': rule.enabled ? '' : null, 'disabled': busy ? '' : null, 'change': function(event) {
				return applyConfig(function(config) { config.rules.find(function(value) { return value.id === rule.id; }).enabled = event.target.checked; });
			} })), E('td', {}, [ E('strong', {}, rule.name), E('small', {}, rule.domain + ':' + rule.port) ]),
			E('td', {}, rule.devices.map(function(id) { return (state.config.devices.find(function(device) { return device.id === id; }) || {}).name || id; }).join('、')),
			E('td', {}, rule.strategy === 'h2' ? 'HTTP/2' : '旁路'),
			E('td', {}, [ E('strong', { 'class': recovery.latched ? 'is-warning' : '' }, !rule.enabled ? '规则已关闭' : !state.requested ? '模块已关闭' : rule.strategy === 'bypass' ? '旁路' : recovery.intercepting ? '正在接管' : '当前旁路'),
				state.requested && rule.enabled && recovery.reason ? E('small', {}, reason(recovery.reason)) : '',
				result.at ? E('small', {}, '最近 ' + (result.upstream_protocol || '协议未确认') + ' · ' + new Date(result.at * 1000).toLocaleString()) : E('small', {}, '尚无转发记录') ]),
			E('td', {}, [ button('编辑', function() { edit(controller, 'rules', rule); }, busy), button('删除', function() {
				return applyConfig(function(config) { config.rules = config.rules.filter(function(value) { return value.id !== rule.id; }); });
			}, busy), recovery.latched ? button('恢复', function() { return mutate(controller, 'compatibilityProbe', { operation: 'recover', rule: rule.id }); }, busy) : '' ]) ]);
	});
	const devices = config.devices.map(function(device) {
		const trust = (state.trust || {})[device.id] || {};
		const runtimes = trust.runtimes || {};
		return E('tr', {}, [ E('td', {}, [ E('strong', {}, device.name), E('small', {}, device.addresses.join(', ')) ]),
			E('td', {}, trust.verified ? '系统信任已验证' : '未验证'),
			E('td', {}, E('details', {}, [ E('summary', {}, '接入验证'), E('small', {}, [ '设备标识：', E('code', {}, device.id) ]), ...[ [ 'codex_app', 'Codex App' ], [ 'codex_cli', 'CLI' ], [ 'images', '图片调用' ] ].map(function(item) {
				return E('small', {}, item[1] + '：' + (runtimes[item[0]] === true ? '已验证' : runtimes[item[0]] === false ? '失败' : '待实际验证'));
			}) ])), E('td', {}, [ button('编辑', function() { edit(controller, 'devices', device); }, busy),
			button('撤销接入', function() { return mutate(controller, 'compatibilityProbe', { operation: 'trust_revoke', device: device.id }); }, busy),
			button('删除', function() { return applyConfig(function(config) {
				config.devices = config.devices.filter(function(value) { return value.id !== device.id; });
				config.rules = config.rules.map(function(rule) { rule.devices = rule.devices.filter(function(id) { return id !== device.id; }); return rule; }).filter(function(rule) { return rule.devices.length; });
			}); }, busy) ]) ]);
	});
	function table(headers, rows, empty) { return E('div', { 'class': 'table netfleet-config-table' }, E('table', {}, [ E('thead', {}, E('tr', {}, headers.map(function(title) { return E('th', {}, title); }))), E('tbody', {}, rows.length ? rows : E('tr', {}, E('td', { 'colspan': headers.length }, empty || '暂无记录'))) ])); }
	const tab = controller.compatibilityTab || 'rules';
	const diagnostics = [ E('div', { 'class': 'netfleet-section-heading' }, [ E('h4', {}, '诊断'), E('div', { 'class': 'netfleet-inline-actions' }, [
		button('连接验证', function() { return mutate(controller, 'compatibilityProbe', {}); }, busy),
		state.recovery && state.recovery.latched ? button('恢复模块', function() { return mutate(controller, 'compatibilityProbe', { operation: 'recover' }); }, busy || !state.requested) : '',
		button('导出诊断', function() { download('netfleet-compatibility-diagnostic.json', JSON.stringify({ requested: state.requested, intercepting: state.intercepting,
			reason: state.reason, active_connections: state.active_connections, recovery: state.recovery,
			rule_recovery: state.rule_recovery, events: state.events, results: Object.values(state.rules || {}) }, null, 2)); }) ]) ]),
		table([ '目标', '最近故障', '恢复探测', '操作' ], config.rules.map(function(rule) {
			const recovery = (state.rule_recovery || {})[rule.id] || {};
			const failure = recovery.last_failure;
			return E('tr', {}, [ E('td', {}, rule.name), E('td', {}, failure ? [ reason(failure.reason || 'historical_failure'), E('small', {}, failure.time ? new Date(failure.time * 1000).toLocaleString() : '') ] : '无记录'),
				E('td', {}, recovery.probe ? [ recovery.probe.ok ? '通过' : reason(recovery.probe.reason), E('small', {}, recovery.probe.duration_ms + ' ms') ] : '尚未探测'),
				E('td', {}, recovery.latched ? button('恢复规则', function() { return mutate(controller, 'compatibilityProbe', { operation: 'recover', rule: rule.id }); }, busy || !state.requested) : '') ]);
		})), E('h4', {}, '兼容事件'), table([ '时间', '目标', '状态', '原因' ], (state.events || []).slice().reverse().map(function(event) {
			const rule = config.rules.find(item => item.id === event.rule);
			return E('tr', {}, [ E('td', {}, new Date(event.at * 1000).toLocaleString()), E('td', {}, rule ? rule.name : event.rule || '模块'),
				E('td', {}, event.intercepting ? '接管' : '旁路'), E('td', {}, reason(event.reason)) ]);
		})) ];
	const panels = {
		rules: [ E('div', { 'class': 'netfleet-section-heading' }, [ E('h4', {}, '目标规则'), button('新增规则', function() { edit(controller, 'rules'); }, busy || !config.devices.length) ]),
			table([ '启用', '目标', '设备', '策略', '状态', '操作' ], rules, config.devices.length ? '暂无目标规则' : '尚无接入设备'),
			!config.devices.length ? button('添加接入设备', function() { controller.compatibilityTab = 'devices'; controller.redraw(); edit(controller, 'devices'); }, busy) : '' ],
		devices: [ E('div', { 'class': 'netfleet-section-heading' }, [ E('h4', {}, '设备与信任'), button('新增设备', function() { edit(controller, 'devices'); }, busy) ]),
			table([ '设备', '系统信任', '应用', '操作' ], devices, '暂无接入设备'),
			E('div', { 'class': 'netfleet-inline-add' }, [ button('下载公开 CA', function() { return api.compatibilityCa().then(function(ca) { download('netfleet-ca.pem', ca.pem, 'application/x-pem-file'); }).catch(function(error) { ui.addNotification(null, E('p', {}, error.message), 'error'); }); }, busy || !state.ca_sha256),
				state.installed ? E('a', { 'href': '/netfleet/macos-trust.py', 'download': 'netfleet-macos-trust.py' }, 'macOS 接入工具') : '' ]),
			state.ca_sha256 ? E('details', {}, [ E('summary', {}, 'CA 指纹'), E('code', { 'class': 'netfleet-compat-fingerprint' }, state.ca_sha256) ]) : '' ],
		diagnostics: diagnostics
	};
	const refreshButton = button('↻', function() { return refresh(controller); }, !!controller.compatibilityRead);
	refreshButton.setAttribute('aria-label', '刷新兼容状态'); refreshButton.setAttribute('title', '刷新兼容状态');
	return E('section', { 'class': 'netfleet-compatibility' }, [ heading,
		E('div', { 'class': 'netfleet-config-row' }, [ E('label', { 'class': 'netfleet-check' }, [ E('input', { 'type': 'checkbox', 'checked': state.requested ? '' : null, 'disabled': toggleBusy ? '' : null,
			'change': function(event) { return mutate(controller, event.target.checked ? 'compatibilityEnable' : 'compatibilityDisable', {}); } }), '启用 HTTPS 兼容' ]),
			E('div', { 'role': 'status' }, [ E('strong', {}, label(state)), E('small', {}, reason(state.reason)),
				controller.compatibilityBusy ? E('small', {}, '正在应用…') : '',
				state.managed === false && state.management_reason && state.management_reason !== state.reason ? E('small', { 'class': 'is-warning' }, reason(state.management_reason)) : '' ]), refreshButton ]),
		controller.compatibilityError ? E('p', { 'class': 'alert-message warning' }, '状态读取失败，操作已停用') : '',
		E('div', { 'class': 'netfleet-compat-tabs', 'role': 'tablist', 'aria-label': 'HTTPS 兼容管理' }, [ [ 'rules', '规则' ], [ 'devices', '设备与信任' ], [ 'diagnostics', '诊断' ] ].map(function(item) {
			return E('button', { 'type': 'button', 'role': 'tab', 'aria-selected': tab === item[0] ? 'true' : 'false', 'aria-controls': 'netfleet-compat-panel',
				'class': tab === item[0] ? 'is-active' : '', 'click': function() { controller.compatibilityTab = item[0]; controller.redraw(); } }, item[1]);
		})), E('div', { 'id': 'netfleet-compat-panel', 'role': 'tabpanel' }, panels[tab]) ]);
}

return baseclass.extend({ render: render, refresh: refresh, label: label });
