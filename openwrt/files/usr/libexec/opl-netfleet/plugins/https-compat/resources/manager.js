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

function label(state) {
	if (!state) return '状态未读取';
	if (!state.installed) return '未安装';
	if (!state.requested) return state.active_connections > 0 ? '停止接管，仍有 ' + state.active_connections + ' 条连接' : '已关闭';
	return state.intercepting ? '已就绪' : '暂未生效';
}

function button(text, action, disabled) {
	return E('button', { 'class': 'btn cbi-button', 'type': 'button', 'disabled': disabled ? '' : null, 'click': action }, text);
}

function refresh(controller) {
	if (controller.compatibilityRead) return controller.compatibilityRead;
	if (controller.disposed?.()) return Promise.resolve();
	const diagnostics = !!controller.diagnosticsExpanded;
	controller.compatibilityRead = api.compatibilityGet({ diagnostics }).then(function(state) {
		if (controller.disposed?.()) return;
		controller.compatibility = state;
		controller.compatibilityLive = true;
		controller.compatibilityDiagnostics = diagnostics;
		controller.compatibilityAt = Date.now();
		controller.compatibilityError = null;
		controller.remember?.();
	}).catch(function(error) { controller.compatibilityError = error; controller.compatibilityLive = false; }).finally(function() {
		controller.compatibilityRead = null;
		if (!controller.disposed?.()) {
			controller.redraw(); controller.follow?.();
			// Opening diagnostics during a summary read needs one complete read next.
			if (controller.compatibilityLive && controller.diagnosticsExpanded && !diagnostics) void refresh(controller);
		}
	});
	controller.refreshing?.();
	return controller.compatibilityRead;
}

function mutate(controller, method, request, revision) {
	if (mutationBlocked(controller, method)) return Promise.resolve();
	const expected = revision === undefined ? controller.compatibility.revision : revision;
	if (request.operation !== 'trust_revoke')
		return executeMutation(controller, method, request, expected);
	return new Promise(function(resolve) {
		ui.showModal('撤销接入', [
			E('p', {}, '停止该范围的新连接转发。客户端的证书信任需在客户端另行移除。'),
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
		if (!controller.disposed?.()) managed.notify(null, E('p', {}, '操作失败：' + error.message), 'error');
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
	const website = collection === 'rules';
	const draft = item ? JSON.parse(JSON.stringify(item)) : website
		? { id: '', name: '', domain: '', match: 'exact', port: 443, strategy: 'h2', enabled: true,
			devices: config.devices.length === 1 ? [config.devices[0].id] : [] }
		: { id: '', name: '', addresses: [] };
	if (!item) draft.id = collection.slice(0, -1) + '-' + Array.from(crypto.getRandomValues(new Uint32Array(3)), value => value.toString(16)).join('');
	const controls = [];
	function field(key, title, type, required = true) {
		const input = E('input', {
			'class': 'cbi-input-text', 'value': Array.isArray(draft[key]) ? draft[key].join(', ') : draft[key],
			'type': type || 'text', 'required': required ? '' : null, 'min': type === 'number' ? 1 : null, 'max': type === 'number' ? 65535 : null,
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
	const rows = [];
	if (website) {
		rows.push(field('domain', '网站域名'));
		const advanced = E('details', { 'open': config.devices.length !== 1 || draft.match !== 'exact' || draft.port !== 443 || draft.strategy !== 'h2' ? '' : null }, [
			E('summary', {}, '高级选项'), field('name', '显示名称（可选）', 'text', false),
			select('match', '匹配范围', [['exact', '仅此域名'], ['suffix', '包括子域名']]),
			field('port', 'HTTPS 端口', 'number'), select('strategy', '转发方式', [['h2', 'HTTP/2'], ['bypass', '直接访问（例外）']]),
			E('div', { 'class': 'netfleet-config-row' }, [E('span', {}, '接入范围'), E('div', {}, config.devices.map(device =>
				E('label', { 'class': 'netfleet-check' }, [E('input', { 'type': 'checkbox', 'checked': draft.devices.includes(device.id) ? '' : null,
					'change': event => { draft.devices = draft.devices.filter(id => id !== device.id); if (event.target.checked) draft.devices.push(device.id); } }), device.name])))])
		]);
		rows.push(E('p', {}, '默认使用 HTTP/2 转发。接入范围：' + (draft.devices.map(id => config.devices.find(device => device.id === id)?.name || id).join('、') || '请在高级选项中选择')), advanced);
	} else {
		rows.push(field('name', '范围名称'));
		const source = state.address_source || {};
		const manual = field('addresses', '来源 IPv4 / IPv6 地址');
		const input = controls[controls.length - 1];
		function manualState() { manual.hidden = !!draft.identity; input.required = !draft.identity; }
		manualState();
		const selected = draft.identity?.mac || '';
		const candidates = source.source_ready ? source.devices || [] : [];
		// Existing dynamic identities remain editable without calling or loading their owner.
		if (selected || candidates.length) rows.push(E('label', { 'class': 'netfleet-config-row' }, [E('span', {}, '地址来源'), E('select', {
			'class': 'cbi-input-select', 'change': event => {
				if (event.target.value) { draft.identity = { binding: source.binding || draft.identity?.binding, mac: event.target.value }; draft.addresses = []; }
				else { delete draft.identity; draft.addresses = input.value.split(/[,\s]+/).filter(Boolean); }
				manualState();
			}
		}, [E('option', { 'value': '', 'selected': !selected ? '' : null }, '手工地址'),
			...(selected && !candidates.some(candidate => candidate.mac === selected) ? [E('option', { 'value': selected, 'selected': '' }, selected + ' · 当前绑定')] : []),
			...candidates.map(candidate => E('option', { 'value': candidate.mac, 'selected': selected === candidate.mac ? '' : null, 'disabled': !candidate.addresses.length ? '' : null }, candidate.name + ' · ' + candidate.mac))])]));
		rows.push(manual, E('p', {}, '填写路由器看到的客户端或共享出口地址。共享出口覆盖其后的客户端，每个客户端仍需信任证书。'));
	}
	rows.push(E('div', { 'class': 'right' }, [ button('取消', () => ui.hideModal()), button('保存', function() {
		for (const input of controls) {
			if (!input.checkValidity()) {
				const details = input.closest?.('details'); if (details) details.open = true;
				input.reportValidity(); return;
			}
		}
		if (website && !draft.devices.length) { managed.notify(null, E('p', {}, '请选择接入范围'), 'warning'); return; }
		if (website) {
			try {
				if (/[\s/:@?#\\]/.test(draft.domain)) throw new Error('invalid_domain');
				draft.domain = new URL('https://' + draft.domain).hostname.replace(/\.+$/, '');
			} catch (_) { managed.notify(null, E('p', {}, '请输入有效域名，不包含协议、路径或端口'), 'warning'); return; }
			if (!draft.name) draft.name = draft.domain;
		}
		const index = config[collection].findIndex(value => value.id === draft.id);
		if (item) config[collection][index] = draft; else config[collection].push(draft);
		ui.hideModal();
		return executeMutation(controller, 'compatibilityApply', { config }, state.revision);
	}) ]));
	ui.showModal((item ? '编辑' : '添加') + (website ? '网站' : '接入范围'), rows);
}

function remove(controller, collection, item) {
	if (mutationBlocked(controller, 'compatibilityApply')) return;
	const state = controller.compatibility;
	const config = JSON.parse(JSON.stringify(state.config));
	const affected = collection === 'devices' ? config.rules.filter(rule => rule.devices.includes(item.id)) : [];
	ui.showModal('删除' + (collection === 'rules' ? '网站' : '接入范围'), [
		E('p', {}, '删除“' + (item.domain || item.name) + '”？' + (affected.length
			? '关联网站将移除此范围；没有其他范围的网站也会删除：' + affected.map(rule => rule.domain).join('、')
			: '删除后将不再为其转发。')),
		E('div', { 'class': 'right' }, [button('取消', () => ui.hideModal()), button('删除', () => {
			config[collection] = config[collection].filter(value => value.id !== item.id);
			if (collection === 'devices') config.rules = config.rules.map(rule => ({ ...rule, devices: rule.devices.filter(id => id !== item.id) })).filter(rule => rule.devices.length);
			ui.hideModal();
			return executeMutation(controller, 'compatibilityApply', { config }, state.revision);
		})])
	]);
}

function download(name, value, type) {
	const url = URL.createObjectURL(new Blob([ value ], { type: type || 'application/json' }));
	const link = E('a', { 'href': url, 'download': name });
	document.body.appendChild(link); link.click(); link.remove();
	setTimeout(function() { URL.revokeObjectURL(url); }, 1000);
}

function render(controller) {
	const state = controller.compatibility;
	const heading = E('div', { 'class': 'netfleet-section-heading' }, [E('div', {}, [E('h3', {}, 'HTTP/2 转发'),
		E('small', {}, '让指定网站的上游请求使用 HTTP/2，应用继续使用原网址。')]),
		button('返回组件列表', () => controller.context.navigate('plugin:product-ui:components'))]);
	const refreshButton = button('刷新状态', () => refresh(controller), !!controller.compatibilityRead);
	const freshnessText = E('span');
	controller.refreshing = () => {
		refreshButton.disabled = !!controller.compatibilityRead;
		freshnessText.textContent = (controller.compatibilityAt ? '上次读取：' + new Date(controller.compatibilityAt).toLocaleString() : '尚未读取设备状态') +
			(controller.compatibilityRead ? ' · 正在刷新' : '') + (controller.compatibilityError ? ' · 刷新失败，保留上次内容' : '') +
			(controller.compatibilityLive === false && state ? ' · 历史摘要，待确认当前状态' : '');
	};
	controller.refreshing();
	const freshness = E('div', { 'class': 'netfleet-compat-freshness', 'role': 'status' }, [
		freshnessText, refreshButton]);
	if (!state) return E('section', {}, [heading, E('p', { 'role': 'status' }, controller.compatibilityError ? '暂时无法读取设备，请重试。' : '正在读取网站与转发状态…'), freshness]);
	const busy = mutationBlocked(controller, 'compatibilityApply');
	const toggleBusy = mutationBlocked(controller, state.requested ? 'compatibilityDisable' : 'compatibilityEnable');
	const config = state.config || { rules: [], devices: [] };
	const scopeName = ids => ids.map(id => config.devices.find(device => device.id === id)?.name || id).join('、');
	function table(headers, rows, empty) {
		rows.forEach(row => Array.from(row.children).forEach((cell, index) => cell.setAttribute('data-label', headers[index])));
		return E('div', { 'class': 'netfleet-config-table' }, E('table', {}, [
			E('thead', {}, E('tr', {}, headers.map(title => E('th', {}, title)))),
			E('tbody', {}, rows.length ? rows : E('tr', {}, E('td', { 'colspan': headers.length }, empty || '暂无记录')))]));
	}
	const rules = config.rules.map(rule => {
		const result = (state.rules || {})[rule.id] || {};
		const admitted = (state.rule_recovery || {})[rule.id]?.admitted;
		const ready = state.intercepting && admitted === true;
		const status = !rule.enabled ? '已停用' : !state.requested ? '已关闭' : rule.strategy === 'bypass' ? '直接访问' : ready ? '已就绪' : '暂未生效';
		return E('tr', { 'data-row-key': 'rule:' + rule.id }, [
			E('td', {}, [E('strong', {}, rule.domain + (rule.port !== 443 ? ':' + rule.port : '')),
				rule.match === 'suffix' ? E('small', {}, '包括子域名') : '',
				rule.strategy === 'bypass' ? E('small', {}, '直接访问例外') : '',
				config.devices.length > 1 ? E('small', {}, scopeName(rule.devices)) : '']),
			E('td', {}, E('input', { 'type': 'checkbox', 'aria-label': '启用 ' + rule.domain, 'checked': rule.enabled ? '' : null, 'disabled': busy ? '' : null,
				'change': event => {
					const changed = JSON.parse(JSON.stringify(config));
					changed.rules.find(value => value.id === rule.id).enabled = event.target.checked;
					return mutate(controller, 'compatibilityApply', { config: changed }, state.revision);
				} })),
			E('td', {}, [E('strong', {}, status), rule.strategy === 'h2' ? E('small', {}, result.upstream_protocol
				? '最近转发记录：' + (result.upstream_protocol === 'h2' ? 'HTTP/2' : result.upstream_protocol) + (result.at ? ' · ' + new Date(result.at * 1000).toLocaleString() : '')
				: ready ? '等待请求验证 HTTP/2' : '尚无转发记录') : '',
				rule.enabled && state.requested && rule.strategy === 'h2' && !ready && state.eligible_devices && !rule.devices.some(id => state.eligible_devices.includes(id))
					? E('small', {}, '请完成下方接入与证书设置') : '']),
			E('td', {}, [button('编辑', () => edit(controller, 'rules', rule), busy), button('删除', () => remove(controller, 'rules', rule), busy)])
		]);
	});
	const accessExpanded = controller.accessExpanded ?? !config.devices.length;
	const devices = accessExpanded ? config.devices.map(device => {
		const trust = (state.trust || {})[device.id] || {};
		const addresses = (state.device_addresses || {})[device.id] || device.addresses;
		return E('tr', { 'data-row-key': 'device:' + device.id }, [
			E('td', {}, [E('strong', {}, device.name), E('details', {}, [E('summary', {}, '接入详情'),
				E('small', {}, '接入标识：' + device.id), E('small', {}, addresses.join(', ') || '当前无可用地址'),
				device.identity ? E('small', {}, '自动跟随 · ' + device.identity.mac) : '']),
				device.identity && !addresses.length ? E('small', {}, sourceReason(state.address_source?.reason || 'address_evidence_expired')) : '']),
			E('td', {}, trust.verified ? '已有接入验证记录' : '待安装证书并验证'),
			E('td', {}, [button('编辑范围', () => edit(controller, 'devices', device), busy),
				button('撤销接入', () => mutate(controller, 'compatibilityProbe', { operation: 'trust_revoke', device: device.id }), busy || !trust.verified),
				button('删除范围', () => remove(controller, 'devices', device), busy)])
		]);
	}) : [];
	function diagnostics() {
		if (controller.compatibilityLive === false) return [E('p', {}, '诊断记录不缓存，请等待当前状态读取成功。')];
		if (controller.compatibilityDiagnostics === false) return [E('p', {}, '正在读取诊断记录…')];
		function probeTable(probes) {
			return table(['路径', '结果', '耗时 / 时限'], Object.entries(probes || {}).map(([name, probe]) => E('tr', {}, [
				E('td', {}, ({ processing: '协议转换', ipv4: 'IPv4 透明入口', ipv6: 'IPv6 透明入口' })[name] || name),
				E('td', {}, probe.ok ? '通过' : reason(probe.reason || '未通过')),
				E('td', {}, Number.isFinite(probe.duration_ms) ? probe.duration_ms + ' ms' + (Number.isFinite(probe.timeout_ms) ? ' / ' + probe.timeout_ms + ' ms' : '') : '未记录')])), '尚无本地验证记录');
		}
		const failure = state.last_failure || (state.events || []).slice().reverse().find(event => !event.rule && (event.failure || Object.values(event.local_probes || {}).some(probe => probe.ok === false)));
		const lastFailure = failure && (failure.failure || failure);
		return [
			button('导出诊断', () => download('netfleet-http2-diagnostic.json', JSON.stringify({
				requested: state.requested, intercepting: state.intercepting, reason: state.reason, active_connections: state.active_connections,
				recovery: state.recovery, last_failure: state.last_failure, engine_restart: state.engine_restart, local_probes: state.local_probes,
				events: state.events, results: state.rules, trust: state.trust }, null, 2))),
			state.engine ? E('p', {}, '转发引擎：' + state.engine.name + (state.engine.version ? ' ' + state.engine.version : '（当前未运行）')) : '',
			state.reason ? E('p', {}, '当前状态：' + reason(state.reason)) : '',
			E('h4', {}, '最近模块故障'),
			lastFailure ? E('p', {}, [reason(lastFailure.reason), lastFailure.health_error ? ' · ' + reason(lastFailure.health_error) : '',
				E('small', {}, lastFailure.at ? new Date(lastFailure.at * 1000).toLocaleString() : '发生时间未记录')]) : E('p', {}, '尚无故障记录'),
			lastFailure ? probeTable(lastFailure.local_probes) : '',
			E('p', {}, '故障窗口内记录 ' + (state.recovery?.faults || []).length + ' 次独立故障；本次恢复已尝试重启 ' + (state.engine_restart?.attempts || 0) + ' 次。'),
			E('h4', {}, '本地转发链 · 最近验证'), probeTable(state.local_probes),
			E('h4', {}, '事件'), table(['时间', '网站', '状态', '原因'], (state.events || []).slice().reverse().map(event => E('tr', {}, [
				E('td', {}, new Date(event.at * 1000).toLocaleString()), E('td', {}, config.rules.find(rule => rule.id === event.rule)?.domain || event.rule || '模块'),
				E('td', {}, event.intercepting ? '转发' : '直接访问'), E('td', {}, reason(event.reason))])))
		];
	}
	const needsRecovery = state.recovery?.latched || state.reason === 'maintenance';
	const help = !state.installed ? '请在组件列表安装 HTTP/2 转发引擎。'
		: !config.devices.length ? '先设置接入范围并安装证书，再添加网站。'
		: !config.rules.some(rule => rule.enabled && rule.strategy === 'h2') ? '添加并启用需要转发的网站。'
		: needsRecovery ? '转发已暂停，请恢复后重试。'
		: state.reason === 'no_verified_targets' ? '请完成接入与证书设置。'
		: state.requested && !state.intercepting ? '暂时直接访问，转发恢复后会自动生效。详情见技术诊断。' : '';
	return E('section', { 'class': 'netfleet-compatibility' }, [
		heading,
		E('div', { 'class': 'netfleet-config-row' }, [
			E('label', { 'class': 'netfleet-check' }, [E('input', { 'type': 'checkbox', 'checked': state.requested ? '' : null, 'disabled': toggleBusy ? '' : null,
				'change': event => mutate(controller, event.target.checked ? 'compatibilityEnable' : 'compatibilityDisable', {}) }), '开启 HTTP/2 转发']),
			E('div', { 'role': 'status' }, [E('strong', {}, (controller.compatibilityLive === false ? '上次状态：' : '') + label(state)),
				controller.compatibilityBusy ? E('small', {}, '正在应用…') : '', help ? E('small', {}, help) : '',
				needsRecovery ? button('恢复转发', () => mutate(controller, 'compatibilityProbe', { operation: 'recover' }), busy || !state.requested) : '',
				state.managed === false ? E('small', { 'class': 'is-warning' }, reason(state.management_reason || state.reason)) : ''])
		]),
		controller.compatibilityError ? E('p', { 'class': 'alert-message warning' }, '状态读取失败，操作已停用') : '',
		E('div', { 'class': 'netfleet-section-heading' }, [E('h4', {}, '网站'), button('添加网站', () => edit(controller, 'rules'), busy || !config.devices.length)]),
		config.devices.length === 1 ? E('p', { 'class': 'netfleet-scope' }, '接入范围：' + config.devices[0].name) : '',
		table(['网站', '启用', '生效结果', '操作'], rules, '尚未添加网站'),
		E('details', { 'open': accessExpanded ? '' : null, 'class': 'netfleet-compat-section',
			'toggle': event => { if (accessExpanded !== event.target.open) { controller.accessExpanded = event.target.open; controller.redraw(); } } }, [
			E('summary', {}, '接入与证书'),
			...(accessExpanded ? [
			E('p', {}, '首次使用：添加接入范围，在客户端安装并信任证书，然后完成接入验证。共享出口后的每个客户端都需要信任证书；已有验证记录不代表全部客户端已完成。'),
			table(['接入范围', '接入记录', '操作'], devices, '尚未设置接入范围'),
			E('div', { 'class': 'netfleet-inline-add' }, [
				button('添加接入范围', () => edit(controller, 'devices'), busy),
				button('下载证书', () => api.compatibilityCa().then(ca => download('netfleet-ca.pem', ca.pem, 'application/x-pem-file')).catch(error => managed.notify(null, E('p', {}, error.message), 'error')), busy || !state.ca_sha256),
				state.installed ? E('a', { 'href': '/netfleet/macos-trust.py', 'download': 'netfleet-macos-trust.py' }, 'macOS 接入工具') : ''
			]),
			E('details', {}, [E('summary', {}, '安装与验证说明'), E('p', {}, 'macOS：下载接入工具，以路由器 SSH 别名和上方接入标识运行。install 安装证书，verify 验证并登记接入。'),
				E('code', {}, 'python3 netfleet-macos-trust.py install --target <路由器 SSH 别名> --device <接入标识>'),
				E('code', {}, 'python3 netfleet-macos-trust.py verify --target <路由器 SSH 别名> --device <接入标识>'),
				E('p', {}, '其他客户端：下载证书并在系统或应用的证书库中信任；共享出口可沿用该范围的接入记录，但仍需在各客户端验证实际访问。')]),
			state.ca_sha256 ? E('details', {}, [E('summary', {}, '证书指纹'), E('code', { 'class': 'netfleet-compat-fingerprint' }, state.ca_sha256)]) : ''
			] : [])
		]),
		E('details', { 'class': 'netfleet-compat-section', 'open': controller.diagnosticsExpanded ? '' : null,
			'toggle': event => { if (!!controller.diagnosticsExpanded !== event.target.open) {
				controller.diagnosticsExpanded = event.target.open; controller.redraw();
				if (event.target.open) void refresh(controller);
			} } },
			[E('summary', {}, '技术诊断'), ...(controller.diagnosticsExpanded ? diagnostics() : [])]),
		freshness
	]);
}

return { render, refresh, label };
}
