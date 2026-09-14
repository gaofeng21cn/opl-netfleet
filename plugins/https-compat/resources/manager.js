/* SPDX-License-Identifier: Apache-2.0 */
export function createManager({ api, ui, resourceUrl, readOnly }) {
const managed = { notify: (...args) => ui.addNotification(...args) };

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
		manual_recovery_required: '故障锁定，等待人工恢复', rules_bypassed: '目标规则当前旁路，详见规则状态',
		management_lease_expired: '管理循环中断，接管许可已到期', engine_restarted: '引擎已重启，健康观察中',
		health_socket_timeout: '本地健康接口超时', health_socket_unavailable: '本地健康接口不可达', health_response_invalid: '本地健康接口返回无效', local_conversion_failed: '本地协议转换验证失败', health_chain_unavailable: '本地转发链不可用',
		historical_failure: '旧版本未记录具体原因', upstream_probe_timeout: '上游恢复探测超时', upstream_certificate_failed: '上游证书验证失败',
		engine_probe_unavailable: '转发引擎暂未完成恢复探测',
		upstream_h2_not_negotiated: '上游未协商 HTTP/2',
		upstream_tls_failed: '上游 TLS 握手失败', client_tls_failed: '客户端 TLS 握手失败',
		upstream_timeout: '上游传输超时', upstream_connection_reset: '上游连接被重置',
		upstream_connect_failed: '上游连接建立失败', upstream_connection_refused: '上游拒绝连接',
		upstream_dns_failed: '上游地址解析失败', upstream_unreachable: '上游网络不可达',
		upstream_bind_failed: '上游连接的本地地址绑定失败',
		source_port_unavailable: '本次连接的源端口不可用', client_request_invalid: '客户端请求格式无效',
		source_port_rule_unsupported: '现有源端口规则暂不支持转换，当前旁路',
		egress_port_range_unavailable: '没有可保持原选路的出站端口范围，当前旁路',
		egress_port_range_unsupported: '内核不支持独立出站端口范围，当前旁路',
		upstream_transport_failed: '上游传输中断', client_cancelled: '客户端已取消', processing_chain_failed: '本地处理链异常',
		transparent_chain_failed: '透明接管入口异常，已旁路',
		engine_unavailable: '兼容引擎未就绪', engine_config_pending: '等待引擎载入配置',
		engine_starting: '兼容引擎启动中，当前旁路',
		lan_access_not_equivalent: '局域网访问策略与转发出站策略不等价，当前旁路',
		lease_service_timeout: '网关控制链超时，当前旁路', lease_service_unavailable: '网关控制链不可用，当前旁路',
		lease_response_too_large: '网关控制响应异常，当前旁路', compatibility_controller_failed: '兼容管理进程异常，当前旁路',
		native_gateway_unavailable: '原生网关暂不可用', native_gateway_not_ready: '原生网关尚未就绪',
		native_ownership_guard_missing: '原生网关缺少连接归属保护',
		upstream_protocol_failed: '目标 TLS 或协议验证失败' })[value] || value || '正常';
}

function sourceReason(value) {
	return ({ source_disabled: '地址同步已关闭', identity_source_unavailable: '地址来源不可用',
		address_evidence_expired: '地址证据已过期，当前旁路', source_not_supported: '请配置 NetFleet 本地地址来源',
		source_unavailable: '地址来源暂不可达', source_timeout: '本地地址观察超时',
		local_observation_interface_unavailable: '局域网观察接口未就绪', local_connections_invalid: '本机连接信息读取失败',
		address_identity_conflict: '地址归属冲突，冲突地址已旁路' })[value] || value || '同步正常';
}

function readSource(controller) {
	if (controller.identityRead) return controller.identityRead;
	controller.identityRead = api.pluginRead({ id: 'device-identity', action: 'get', params: {} }).then(source => {
		if (controller.disposed?.()) return;
		controller.identitySource = source; controller.identitySourceError = null;
	}).catch(error => { controller.identitySourceError = error; }).finally(() => {
		controller.identityRead = null;
		if (!controller.disposed?.()) controller.redraw();
	});
	return controller.identityRead;
}

async function sourceAction(controller, action, params) {
	const source = controller.identitySource;
	if (!source || controller.identitySourceError || mutationBlocked(controller, 'compatibilityApply')) return;
	controller.compatibilityBusy = true;
	controller.redraw();
	try {
		let revision = source.revision;
		if (!source.loaded && action === 'configure') {
			const loaded = await api.pluginCall({ id: 'device-identity', action: 'load', revision: revision, confirm: true, params: {} });
			revision = loaded.revision;
			params = Object.assign({}, params, { config_revision: loaded.config_revision });
		}
		await (action === 'sync' ? api.pluginRead : api.pluginCall)({ id: 'device-identity', action: action,
			revision: revision, confirm: action !== 'sync', params: params || {} });
		if (action === 'configure') await api.pluginRead({ id: 'device-identity', action: 'sync', params: {} });
	} catch (error) { managed.notify(null, E('p', {}, '地址来源操作失败：' + error.message), 'error'); }
	finally { controller.compatibilityBusy = false; await Promise.all([refresh(controller), readSource(controller)]); }
}

function editSource(controller) {
	const source = controller.identitySource;
	if (!source || controller.identitySourceError || mutationBlocked(controller, 'compatibilityApply')) return;
	const draft = { source: 'local', enabled: !!source.config.enabled, interfaces: source.config.interfaces || [] };
	const fields = [];
	const rows = E('div', {});
	function field(key, label, type) {
		const input = E('input', { 'class': 'cbi-input-text', 'type': type || 'text', 'autocomplete': 'off',
			'value': Array.isArray(draft[key]) ? draft[key].join(', ') : draft[key] || '',
			'input': function(event) { draft[key] = key === 'interfaces' ? event.target.value.split(/[,\s]+/).filter(Boolean) : event.target.value; } });
		fields.push(input);
		return E('label', { 'class': 'netfleet-config-row' }, [ E('span', {}, label), input ]);
	}
	function showFields() {
		fields.length = 0;
		rows.replaceChildren(field('interfaces', '局域网观察接口'));
	}
	showFields();
	ui.showModal('设备地址来源', [
		E('label', { 'class': 'netfleet-check' }, [ E('input', { 'type': 'checkbox', 'checked': draft.enabled ? '' : null,
			'change': function(event) { draft.enabled = event.target.checked; } }), '自动同步设备地址' ]),
		E('p', {}, '由 NetFleet 局域网观察接口确认设备地址，不连接其他设备的管理面。'),
		rows, E('div', { 'class': 'right' }, [ button('取消', ui.hideModal), button('保存并验证', function() {
			const config = Object.assign({}, draft);
			ui.hideModal();
			return sourceAction(controller, 'configure', { config_revision: source.config_revision, config: config });
		}) ]) ]);
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
	if (controller.disposed?.()) return Promise.resolve();
	controller.compatibilityRead = api.compatibilityGet().then(function(state) {
		if (controller.disposed?.()) return;
		controller.compatibility = state;
		controller.compatibilityLive = true;
		controller.compatibilityAt = Date.now();
		controller.compatibilityError = null;
		controller.remember?.();
	}).catch(function(error) { controller.compatibilityError = error; controller.compatibilityLive = false; }).finally(function() {
		controller.compatibilityRead = null;
		if (!controller.disposed?.()) { controller.redraw(); controller.follow?.(); }
	});
	controller.redraw();
	return controller.compatibilityRead;
}

function mutate(controller, method, request, revision) {
	if (mutationBlocked(controller, method)) return Promise.resolve();
	const expected = revision === undefined ? controller.compatibility.revision : revision;
	if (method === 'compatibilityDisable')
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
	return readOnly() || controller.disposed?.() || controller.compatibilityLive === false || controller.compatibilityBusy || !state || !state.installed || !!controller.compatibilityError ||
		state.managed === false && method !== 'compatibilityDisable';
}

function executeMutation(controller, method, request, revision) {
	if (mutationBlocked(controller, method)) return Promise.resolve();
	controller.compatibilityBusy = true;
	controller.redraw();
	controller.compatibilityLive = false;
	let applied = false;
	return api[method](Object.assign({ revision: revision }, request)).then(function() { applied = true; }).catch(function(error) {
		if (!controller.disposed?.()) managed.notify(null, E('p', {}, 'HTTPS 兼容操作失败：' + error.message), 'error');
	}).then(async function() {
		await controller.compatibilityRead;
		await refresh(controller);
		if (applied && !controller.disposed?.()) managed.notify(null, E('p', {}, controller.compatibilityError ? '操作已提交，当前状态待确认，请刷新；无需重复提交。' : '已保存，当前状态：' + label(controller.compatibility)), controller.compatibilityError ? 'warning' : 'info');
	}).finally(function() { controller.compatibilityBusy = false; if (!controller.disposed?.()) controller.redraw(); });
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
	else {
		const source = controller.identitySourceError ? state.address_source || {} : controller.identitySource || state.address_source || {};
		const manual = field('addresses', 'IPv4 / IPv6 地址');
		const input = controls[controls.length - 1];
		function manualState() { manual.hidden = !!draft.identity; input.required = !draft.identity; }
		manualState();
		const selected = draft.identity ? draft.identity.mac : '';
		const candidates = source.source_ready ? source.devices || [] : [];
		rows.push(E('label', { 'class': 'netfleet-config-row' }, [ E('span', {}, '地址来源'), E('select', {
			'class': 'cbi-input-select', 'change': function(event) {
				if (event.target.value) { draft.identity = { binding: source.binding, mac: event.target.value }; draft.addresses = []; }
				else { delete draft.identity; draft.addresses = input.value.split(/[,\s]+/).filter(Boolean); }
				manualState();
			}
		}, [ E('option', { 'value': '', 'selected': !selected ? '' : null }, '手工地址'),
			...(selected && !candidates.some(item => item.mac === selected) ? [ E('option', { 'value': selected, 'selected': '' }, selected + ' · 当前无新鲜地址') ] : []),
			...candidates.map(item => E('option', { 'value': item.mac, 'selected': selected === item.mac ? '' : null,
				'disabled': !item.addresses.length ? '' : null }, item.name + ' · ' + item.mac)) ]) ]), manual);
	}
	rows.push(E('div', { 'class': 'right' }, [ button('取消', function() { ui.hideModal(); }), button('保存', function() {
		if (controls.some(function(input) { return !input.reportValidity(); })) return;
		if (collection === 'rules' && !draft.devices.length) {
			managed.notify(null, E('p', {}, '请选择至少一台接入设备'), 'warning'); return;
		}
		if (collection === 'rules') {
            try {
                if (/[\s/:@?#\\]/.test(draft.domain)) throw new Error('invalid_domain');
                draft.domain = new URL('https://' + draft.domain).hostname.replace(/\.+$/, '');
            } catch (_) { managed.notify(null, E('p', {}, '请输入有效域名，不包含 URL 路径或端口'), 'warning'); return; }
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
	const back = button('返回组件列表', function() { controller.context.navigate('plugin:product-ui:components'); });
	const heading = E('div', { 'class': 'netfleet-section-heading' }, [ E('div', {}, [ E('h3', {}, 'HTTPS 兼容'),
		E('small', {}, '为选定设备和网站转换 HTTP/1.1 → HTTP/2；应用继续使用原网址。') ]), back ]);
	const tab = ['rules', 'devices', 'diagnostics'].includes(controller.compatibilityTab) ? controller.compatibilityTab : 'rules';
	function tabs() {
		return E('div', { 'class': 'netfleet-compat-tabs', 'role': 'tablist', 'aria-label': 'HTTPS 兼容管理' }, [ [ 'rules', '规则' ], [ 'devices', '设备与信任' ], [ 'diagnostics', '诊断' ] ].map(function(item) {
			return E('button', { 'type': 'button', 'role': 'tab', 'id': 'netfleet-compat-tab-' + item[0],
				'aria-selected': tab === item[0] ? 'true' : 'false', 'aria-controls': 'netfleet-compat-panel',
				'class': tab === item[0] ? 'is-active' : '', 'click': function() {
					controller.compatibilityTab = item[0]; controller.remember?.(); controller.redraw();
				} }, item[1]);
		}));
	}
	const refreshButton = button('刷新状态', function() { return refresh(controller); }, !!controller.compatibilityRead);
	refreshButton.setAttribute('aria-label', '刷新兼容状态');
	const freshness = E('div', { 'class': 'netfleet-compat-freshness', 'role': 'status' }, [
		E('span', {}, [ controller.compatibilityAt ? '上次读取：' + new Date(controller.compatibilityAt).toLocaleString() : '尚未读取设备状态',
			controller.compatibilityRead ? ' · 正在刷新' : controller.compatibilityError ? ' · 刷新失败，保留上次内容' : '',
			controller.compatibilityLive === false && state ? ' · 历史摘要，待确认当前状态' : '' ]), refreshButton ]);
	if (!state) return E('section', { 'class': 'netfleet-compatibility' }, [ heading, tabs(),
		E('p', { 'role': 'status' }, controller.compatibilityError ? '暂时无法读取设备，请重试。' : '正在读取已保存的规则和设备…'), freshness ]);
	const busy = mutationBlocked(controller, 'compatibilityApply');
	const toggleBusy = mutationBlocked(controller, state.requested ? 'compatibilityDisable' : 'compatibilityEnable');
	function applyConfig(callback) {
		const config = JSON.parse(JSON.stringify(state.config)); callback(config);
		return mutate(controller, 'compatibilityApply', { config: config }, state.revision);
	}
	const config = state.config || { rules: [], devices: [] };
	const rules = tab === 'rules' ? config.rules.map(function(rule) {
		const result = (state.rules || {})[rule.id] || {};
		const recovery = (state.rule_recovery || {})[rule.id] || {};
		return E('tr', { 'data-row-key': 'rule:' + rule.id }, [
			E('td', {}, E('input', { 'type': 'checkbox', 'aria-label': rule.name, 'checked': rule.enabled ? '' : null, 'disabled': busy ? '' : null, 'change': function(event) {
				return applyConfig(function(config) { config.rules.find(function(value) { return value.id === rule.id; }).enabled = event.target.checked; });
			} })), E('td', {}, [ E('strong', {}, rule.name), E('small', {}, rule.domain + ':' + rule.port) ]),
			E('td', {}, rule.devices.map(function(id) { return (state.config.devices.find(function(device) { return device.id === id; }) || {}).name || id; }).join('、')),
			E('td', {}, rule.strategy === 'h2' ? 'HTTP/2' : '旁路'),
			E('td', {}, [ E('strong', { 'class': recovery.latched ? 'is-warning' : '' }, !rule.enabled ? '规则已关闭' : !state.requested ? '模块已关闭' : rule.strategy === 'bypass' ? '旁路' :
				state.eligible_devices && !rule.devices.some(id => state.eligible_devices.includes(id)) ? '无可接管设备' : state.intercepting && recovery.admitted ? '正在接管' : '当前旁路'),
				state.requested && rule.enabled && (state.reason || recovery.reason) ? E('small', {}, reason(state.reason || recovery.reason)) : '',
				result.upstream_protocol || result.at ? E('small', {}, '最近上游：' + (result.upstream_protocol || '协议未确认') + (result.at ? ' · ' + new Date(result.at * 1000).toLocaleString() : '')) : E('small', {}, '尚无转发记录') ]),
			E('td', {}, [ button('编辑', function() { edit(controller, 'rules', rule); }, busy), button('删除', function() {
				return applyConfig(function(config) { config.rules = config.rules.filter(function(value) { return value.id !== rule.id; }); });
			}, busy), recovery.latched ? button('恢复', function() { return mutate(controller, 'compatibilityProbe', { operation: 'recover', rule: rule.id }); }, busy) : '' ]) ]);
	}) : [];
	const devices = tab === 'devices' ? config.devices.map(function(device) {
		const trust = (state.trust || {})[device.id] || {};
		const runtimes = trust.runtimes || {};
		const addresses = (state.device_addresses || {})[device.id] || device.addresses;
		const observation = ((state.address_source || {}).devices || []).find(item => device.identity && item.mac === device.identity.mac) || {};
		return E('tr', { 'data-row-key': 'device:' + device.id }, [ E('td', {}, [ E('strong', {}, device.name),
			E('details', {}, [ E('summary', {}, addresses.length + ' 个地址'), E('small', {}, addresses.join(', ') || '当前无可用地址'),
				E('small', {}, controller.compatibilityLive === false ? '上次设备地址' : device.identity ? '自动跟随 · ' + device.identity.mac : '手工地址') ]),
			device.identity && !addresses.length ? E('small', {}, sourceReason(observation.reason || (state.address_source || {}).reason || 'address_evidence_expired')) : '' ]),
			E('td', {}, trust.verified ? '系统信任已验证' : '未验证'),
			E('td', {}, E('details', {}, [ E('summary', {}, '接入验证'), E('small', {}, [ '设备标识：', E('code', {}, device.id) ]), ...[ [ 'codex_app', 'Codex App' ], [ 'codex_cli', 'CLI' ], [ 'images', '图片调用' ] ].map(function(item) {
				return E('small', {}, item[1] + '：' + (runtimes[item[0]] === true ? '已验证' : runtimes[item[0]] === false ? '失败' : '待实际验证'));
			}) ])), E('td', {}, [ button('编辑', function() { edit(controller, 'devices', device); }, busy),
			button('撤销接入', function() { return mutate(controller, 'compatibilityProbe', { operation: 'trust_revoke', device: device.id }); }, busy),
			button('删除', function() { return applyConfig(function(config) {
				config.devices = config.devices.filter(function(value) { return value.id !== device.id; });
				config.rules = config.rules.map(function(rule) { rule.devices = rule.devices.filter(function(id) { return id !== device.id; }); return rule; }).filter(function(rule) { return rule.devices.length; });
			}); }, busy) ]) ]);
	}) : [];
	function table(headers, rows, empty) {
		rows.forEach(row => Array.from(row.children).forEach((cell, index) => cell.setAttribute('data-label', headers[index])));
		return E('div', { 'class': 'netfleet-config-table' }, E('table', {}, [ E('thead', {}, E('tr', {}, headers.map(function(title) { return E('th', {}, title); }))), E('tbody', {}, rows.length ? rows : E('tr', {}, E('td', { 'colspan': headers.length }, empty || '暂无记录'))) ]));
	}
	function probeTable(probes) {
		return table([ '路径', '结果', '阶段', '耗时 / 时限' ], Object.entries(probes || {}).map(function([name, probe]) {
			return E('tr', {}, [ E('td', {}, ({ processing: '协议转换', ipv4: 'IPv4 透明入口', ipv6: 'IPv6 透明入口' })[name] || name),
				E('td', {}, probe.ok ? '通过' : probe.reason === 'timeout' ? '超时' : reason(probe.reason || '未通过')),
				E('td', {}, ({ connect: '建立连接', tls: 'TLS 握手', http: 'HTTP 往返' })[probe.stage] || probe.stage || '未知'),
				E('td', {}, Number.isFinite(probe.duration_ms) ? probe.duration_ms + ' ms' + (Number.isFinite(probe.timeout_ms) ? ' / ' + probe.timeout_ms + ' ms' : '') : '未知') ]);
		}), '尚无本地验证记录');
	}
	const failure = state.last_failure || (state.events || []).slice().reverse().find(event => !event.rule &&
		(event.failure || Object.values(event.local_probes || {}).some(probe => probe.ok === false)));
	const lastFailure = failure && (failure.failure || failure);
	const diagnostics = () => controller.compatibilityLive === false ? [ E('p', {}, '诊断记录不缓存，请等待当前状态读取成功。') ] : [ E('div', { 'class': 'netfleet-section-heading' }, [ E('h4', {}, '诊断'), E('div', { 'class': 'netfleet-inline-actions' }, [
		(state.recovery && state.recovery.latched || state.reason === 'maintenance') ? button('恢复模块', function() { return mutate(controller, 'compatibilityProbe', { operation: 'recover' }); }, busy || !state.requested) : '',
		button('导出诊断', function() { download('netfleet-compatibility-diagnostic.json', JSON.stringify({ requested: state.requested, intercepting: state.intercepting,
			reason: state.reason, active_connections: state.active_connections, recovery: state.recovery, last_failure: state.last_failure, engine_restart: state.engine_restart,
			local_probes: state.local_probes, rule_recovery: state.rule_recovery, events: state.events, results: Object.values(state.rules || {}) }, null, 2)); }) ]) ]),
		state.engine ? E('p', {}, '转发引擎：' + state.engine.name + (state.engine.version ? ' ' + state.engine.version : '（当前未运行）')) : '',
		E('h4', {}, '最近模块故障'),
		lastFailure ? E('p', {}, [ reason(lastFailure.reason), lastFailure.health_error ? ' · ' + reason(lastFailure.health_error) : '',
			E('small', {}, lastFailure.at ? new Date(lastFailure.at * 1000).toLocaleString() : '发生时间未记录') ]) : E('p', {}, '尚无具体故障记录'),
		lastFailure ? probeTable(lastFailure.local_probes) : '',
		E('p', {}, '故障窗口内记录 ' + ((state.recovery || {}).faults || []).length + ' 次独立故障；本次恢复已尝试重启 ' + ((state.engine_restart || {}).attempts || 0) + ' 次。重启尝试不计作新故障。'),
		state.recovery && state.recovery.latched ? E('p', {}, '模块已停止自动恢复；下方验证结果仅为最近记录，不能表示当前正在接管。') : '',
		E('h4', {}, '本地转发链 · 最近验证'), probeTable(state.local_probes),
		E('h4', {}, '目标恢复'),
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
		})), E('a', { 'href': L.url('admin/system/package-manager'), 'target': '_blank', 'rel': 'noopener' }, '软件包管理 ↗') ];
	const panels = {
		rules: () => [ E('div', { 'class': 'netfleet-section-heading' }, [ E('h4', {}, '目标规则 · ' + config.rules.length), button('新增规则', function() { edit(controller, 'rules'); }, busy || !config.devices.length) ]),
			table([ '启用', '目标', '设备', '策略', '状态', '操作' ], rules, config.devices.length ? '暂无目标规则' : '尚无接入设备'),
			!config.devices.length ? button('添加接入设备', function() { controller.compatibilityTab = 'devices'; controller.redraw(); edit(controller, 'devices'); }, busy) : '' ],
		devices: () => [ E('div', { 'class': 'netfleet-section-heading' }, [ E('h4', {}, '设备与信任 · ' + config.devices.length), button('新增设备', function() { edit(controller, 'devices'); }, busy) ]),
			E('details', { 'class': 'netfleet-compat-source', 'open': controller.sourceExpanded ? '' : null, 'toggle': function(event) {
				controller.sourceExpanded = event.target.open;
				if (event.target.open && !controller.identitySource && !controller.identitySourceError) void readSource(controller);
			} }, [ E('summary', {}, '高级：设备地址来源'), E('div', { 'class': 'netfleet-section-heading' }, [
			E('div', { 'role': 'status' }, controller.identitySource ? [ E('strong', {}, 'NetFleet 本机网络'),
					E('small', {}, sourceReason(controller.identitySource.reason)),
					(controller.identitySource.devices || []).some(item => !item.addresses.length) ? E('small', {}, (controller.identitySource.devices || []).filter(item => !item.addresses.length).length + ' 台设备无可用地址') : '',
					controller.identitySource.last_success ? E('small', {}, '最近同步 ' + new Date(controller.identitySource.last_success * 1000).toLocaleString()) : '' ] : controller.identitySourceError ? '设备地址插件未安装或不可读取；手工地址仍可使用' : '按需读取地址来源'),
				E('div', { 'class': 'netfleet-inline-actions' }, [ button('读取来源', function() { return readSource(controller); }, !!controller.identityRead),
					button('管理来源', function() { editSource(controller); }, busy || !controller.identitySource || !!controller.identitySourceError),
					button('同步', function() { return sourceAction(controller, 'sync'); }, busy || !controller.identitySource || !controller.identitySource.loaded || !!controller.identitySourceError) ]) ]) ]),
			table([ '设备', '系统信任', '应用', '操作' ], devices, '暂无接入设备'),
			E('div', { 'class': 'netfleet-inline-add' }, [ button('下载公开 CA', function() { return api.compatibilityCa().then(function(ca) { download('netfleet-ca.pem', ca.pem, 'application/x-pem-file'); }).catch(function(error) { managed.notify(null, E('p', {}, error.message), 'error'); }); }, busy || !state.ca_sha256),
				state.installed ? E('a', { 'href': '/netfleet/macos-trust.py', 'download': 'netfleet-macos-trust.py' }, 'macOS 接入工具') : '' ]),
			state.ca_sha256 ? E('details', {}, [ E('summary', {}, 'CA 指纹'), E('code', { 'class': 'netfleet-compat-fingerprint' }, state.ca_sha256) ]) : '' ],
		diagnostics: diagnostics
	};
	return E('section', { 'class': 'netfleet-compatibility' }, [ heading,
		E('div', { 'class': 'netfleet-config-row' }, [ E('label', { 'class': 'netfleet-check' }, [ E('input', { 'type': 'checkbox', 'checked': state.requested ? '' : null, 'disabled': toggleBusy ? '' : null,
			'change': function(event) { return mutate(controller, event.target.checked ? 'compatibilityEnable' : 'compatibilityDisable', {}); } }), '启用 HTTPS 兼容' ]),
			E('div', { 'role': 'status' }, [ E('strong', {}, (controller.compatibilityLive === false ? '上次状态：' : '') + label(state)), state.reason ? E('small', {}, reason(state.reason)) : '',
				controller.compatibilityBusy ? E('small', {}, '正在应用…') : '',
				state.managed === false && state.management_reason && state.management_reason !== state.reason ? E('small', { 'class': 'is-warning' }, reason(state.management_reason)) : '' ]) ]),
		controller.compatibilityError ? E('p', { 'class': 'alert-message warning' }, '状态读取失败，操作已停用') : '',
		tabs(), E('div', { 'id': 'netfleet-compat-panel', 'role': 'tabpanel', 'aria-labelledby': 'netfleet-compat-tab-' + tab }, panels[tab]()), freshness ]);
}

return { render, refresh, label };
}
