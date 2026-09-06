/* SPDX-License-Identifier: MIT */
'use strict';
'require baseclass';
'require ui';
'require netfleet.api as api';

function clone(value) { return JSON.parse(JSON.stringify(value)); }
function disabled(controller) { return controller.busy || !controller.liveDataReady; }
function button(label, click, inactive, danger) {
	return E('button', { 'class': 'btn cbi-button' + (danger ? ' cbi-button-negative' : ''), 'type': 'button', 'disabled': !!inactive, 'click': click }, label);
}
function row(label, control, help) {
	return E('div', { 'class': 'netfleet-config-row' }, [ E('div', {}, [ E('strong', {}, label), help ? E('p', {}, help) : '' ]), E('div', { 'class': 'netfleet-config-control' }, control) ]);
}
function input(value, onchange, type, attrs) {
	return E('input', Object.assign({ 'class': 'cbi-input-text', 'type': type || 'text', 'value': value == null ? '' : value, 'input': function(event) { onchange(event.target.value); } }, attrs || {}));
}
function lines(value, onchange, label) {
	return E('textarea', { 'class': 'cbi-input-textarea netfleet-list-input', 'rows': 3, 'aria-label': label, 'input': function(event) {
		onchange(event.target.value.split(/\r?\n/).map(function(item) { return item.trim(); }).filter(Boolean));
	} }, (value || []).join('\n'));
}
function toggle(value, onchange, label) {
	return E('label', { 'class': 'netfleet-check' }, [ E('input', { 'type': 'checkbox', 'checked': !!value, 'change': function(event) { onchange(event.target.checked); } }), E('span', {}, label || (value ? '已开启' : '已关闭')) ]);
}
function time(value) { return value ? new Date(value * 1000).toLocaleString() : '未提供'; }
function errorText(error) {
	const code = String(error && error.message || error || 'operation_failed');
	const known = {
		mutation_busy: '设备正在执行其他操作，请稍后重试', network_revision_conflict: '网络配置已变化，请重新读取后修改',
		network_validation_timeout: '核心配置校验超时，当前网络配置未修改',
		maintenance_revision_changed: '设备配置已变化，请重新读取后操作', profile_referenced: '此文件仍被使用，请先切换配置',
		profile_is_referenced: '此文件仍被使用，不能编辑或删除', invalid_profile_id: '文件名无效', profile_validation_failed: '配置未通过 Mihomo 校验',
		backup_invalid: '备份格式无效', backup_confirmation_required: '请先确认恢复备份', native_backend_required: '此操作需要 NetFleet 原生后端'
	};
	let message = known[code] || '设备未完成操作（' + code + '）';
	if (error && error.detail && error.detail.rollback) message += error.detail.rollback.ok ? '；已恢复操作前状态' : '；恢复尚未确认，请检查设备状态';
	return message;
}
function notice(error) { ui.addNotification(null, E('p', {}, errorText(error)), 'error'); }
function confirm(title, description, action) {
	ui.showModal(title, [ E('p', {}, description), E('div', { 'class': 'right' }, [ button('取消', ui.hideModal), ' ', button('确认', function() { ui.hideModal(); return action(); }) ]) ]);
}
function run(controller, title, request, refresh) {
	if (disabled(controller)) return Promise.resolve();
	controller.busy = true;
	controller.redraw();
	ui.showModal(title, [ E('p', { 'class': 'spinning', 'role': 'status' }, '正在执行并确认设备状态…') ]);
	return Promise.resolve().then(request).then(function(result) {
		ui.hideModal();
		ui.addNotification(null, E('p', {}, title + '已完成'), 'info');
		return refresh ? Promise.resolve(refresh(result)).then(function() { return result; }) : result;
	}).catch(function(error) { ui.hideModal(); notice(error); }).finally(function() { controller.busy = false; controller.redraw(); });
}
function load(controller, kind, force) {
	const key = kind + 'State';
	if (controller[kind + 'Read']) return controller[kind + 'Read'];
	if (controller[key] && !force) return Promise.resolve(controller[key]);
	controller[kind + 'Error'] = null;
	const read = { network: api.networkGet, maintenance: api.maintenanceGet, diagnostics: api.diagnosticsGet }[kind];
	controller[kind + 'Read'] = read().then(function(state) {
		controller[key] = state;
		if (kind === 'network') controller.networkDraft = clone(state.settings || {});
		return state;
	}).catch(function(error) { controller[kind + 'Error'] = error; }).finally(function() {
		controller[kind + 'Read'] = null;
		controller.redraw();
	});
	return controller[kind + 'Read'];
}
function pending(controller, kind, title) {
	const error = controller[kind + 'Error'];
	return E('section', {}, [ E('h3', {}, title), E('p', { 'class': error ? 'is-warning' : 'spinning', 'role': 'status' }, error ? errorText(error) : '正在读取设备配置…'),
		button('重新读取', function() { return load(controller, kind, true); }, !!controller[kind + 'Read']) ]);
}
function table(headers, rows) {
	return E('div', { 'class': 'netfleet-management-table' }, E('table', { 'class': 'table' }, [ E('thead', {}, E('tr', {}, headers.map(function(label) { return E('th', {}, label); }))), E('tbody', {}, rows) ]));
}
function network(controller) {
	const state = controller.networkState;
	if (!state) return pending(controller, 'network', '网络接入');
	if (!state.available) return E('div', { 'class': 'alert-message warning' }, [ E('p', {}, state.backend !== 'native-mihomo' ? '网络接入由当前外部后端管理。' : '当前网络配置无法读取（' + (state.reason || '原因未提供') + '）。'), button('重新读取', function() { return load(controller, 'network', true); }) ]);
	const draft = controller.networkDraft;
	const locked = disabled(controller);
	function policies(key, title) {
		return E('section', { 'class': 'netfleet-management-section' }, [ E('h4', {}, title), table(['匹配域名', 'DNS 服务器', '操作'], draft.dns[key].map(function(item, index) {
			return E('tr', {}, [ E('td', {}, input(item.domain, function(value) { item.domain = value; }, 'text', { 'aria-label': '匹配域名' })),
				E('td', {}, lines(item.nameservers, function(value) { item.nameservers = value; }, 'DNS 服务器')),
				E('td', {}, button('移除', function() { draft.dns[key].splice(index, 1); controller.redraw(); }, locked, true)) ]);
		})), button('添加域名 DNS', function() { draft.dns[key].push({ domain: '', nameservers: [] }); controller.redraw(); }, locked) ]);
	}
	const credentials = draft.listeners.credentials || [];
	const rows = [
		row('常规 DNS', lines(draft.dns.nameservers, function(value) { draft.dns.nameservers = value; }, '常规 DNS')),
		row('启动解析 DNS', lines(draft.dns.default_nameservers, function(value) { draft.dns.default_nameservers = value; }, '启动解析 DNS')),
		row('代理节点 DNS', lines(draft.dns.proxy_nameservers, function(value) { draft.dns.proxy_nameservers = value; }, '代理节点 DNS')),
		row('直连 DNS', lines(draft.dns.direct_nameservers, function(value) { draft.dns.direct_nameservers = value; }, '直连 DNS'))
	];
	return E('section', {}, [ E('div', { 'class': 'netfleet-config-heading' }, [ E('h3', {}, '网络接入'), E('p', {}, 'TProxy') ]),
		E('fieldset', { 'disabled': locked, 'class': 'netfleet-management-fields' }, [ E('h4', {}, 'DNS'), E('div', { 'class': 'netfleet-config-rows' }, rows),
			policies('policies', '按域名指定 DNS'), policies('proxy_policies', '按代理节点域名指定 DNS'),
			E('h4', {}, '代理范围'),
			row('路由器本机', toggle(draft.router.enabled, function(value) { draft.router.enabled = value; controller.redraw(); })),
			row('局域网设备', toggle(draft.lan.enabled, function(value) { draft.lan.enabled = value; controller.redraw(); })),
			row('接入接口', E('div', { 'class': 'netfleet-region-checks' }, (state.resources.interfaces || []).map(function(item) {
				return toggle(draft.lan.interfaces.indexOf(item.name) >= 0, function(value) {
					draft.lan.interfaces = value ? draft.lan.interfaces.concat([item.name]) : draft.lan.interfaces.filter(function(name) { return name !== item.name; }); controller.redraw();
				}, item.name + (item.up ? '' : '（未连接）'));
			}))),
			E('h4', {}, '设备访问控制'),
			table(['启用', 'IPv4 / IPv6 / MAC', '代理', 'DNS 接管', '顺序'], draft.lan.rules.map(function(rule, index) {
				return E('tr', {}, [ E('td', {}, toggle(rule.enabled, function(value) { rule.enabled = value; })),
					E('td', {}, [ lines(rule.ipv4, function(value) { rule.ipv4 = value; }, 'IPv4 地址或网段'), lines(rule.ipv6, function(value) { rule.ipv6 = value; }, 'IPv6 地址或网段'), lines(rule.mac, function(value) { rule.mac = value; }, 'MAC 地址') ]),
					E('td', {}, toggle(rule.proxy, function(value) { rule.proxy = value; })), E('td', {}, toggle(rule.dns, function(value) { rule.dns = value; })),
					E('td', { 'class': 'netfleet-inline-actions' }, [ button('↑', function() { draft.lan.rules.splice(index - 1, 0, draft.lan.rules.splice(index, 1)[0]); controller.redraw(); }, index === 0),
						button('↓', function() { draft.lan.rules.splice(index + 1, 0, draft.lan.rules.splice(index, 1)[0]); controller.redraw(); }, index === draft.lan.rules.length - 1),
						button('移除', function() { draft.lan.rules.splice(index, 1); controller.redraw(); }, false, true) ]) ]);
			})), button('添加设备规则', function() { draft.lan.rules.push({ id: 'new_lan_' + Date.now(), enabled: true, ipv4: [], ipv6: [], mac: [], proxy: true, dns: true }); controller.redraw(); }),
			E('h4', {}, '代理监听与认证'),
			row('混合代理端口', input(draft.listeners.mixed_port, function(value) { draft.listeners.mixed_port = Number(value); }, 'number', { min: 0, max: 65535 })),
			row('HTTP 代理端口', input(draft.listeners.http_port, function(value) { draft.listeners.http_port = Number(value); }, 'number', { min: 0, max: 65535 })),
			row('SOCKS 代理端口', input(draft.listeners.socks_port, function(value) { draft.listeners.socks_port = Number(value); }, 'number', { min: 0, max: 65535 })),
			row('连接认证', toggle(draft.listeners.authentication_enabled, function(value) { draft.listeners.authentication_enabled = value; controller.redraw(); })),
			table(['用户名', '密码', '操作'], credentials.map(function(item, index) {
				return E('tr', {}, [ E('td', {}, input(item.username, function(value) { item.username = value; }, 'text', { autocomplete: 'off', 'aria-label': '代理用户名' })),
					E('td', {}, input(item.password, function(value) { if (value) item.password = value; else delete item.password; }, 'password', { autocomplete: 'new-password', placeholder: item.password_configured ? '已保存，留空保留' : '设置密码', 'aria-label': '代理密码' })),
					E('td', {}, button('移除', function() { credentials.splice(index, 1); controller.redraw(); }, false, true)) ]);
			})), button('添加账户', function() { credentials.push({ id: 'new_auth_' + Date.now(), username: '', password: '' }); controller.redraw(); })
		]),
		E('div', { 'class': 'netfleet-config-actions' }, [ E('span', {}, controller.networkResult || ''), E('div', {}, [
			button('放弃更改', function() { return load(controller, 'network', true); }, locked),
			button('校验配置', function() { return api.networkValidate({ revision: state.revision, settings: clone(draft) }).then(function() { controller.networkResult = '校验通过'; controller.redraw(); }).catch(notice); }, locked),
			button('应用网络配置', function() { confirm('应用网络配置', '将保存并重新加载网络接入配置，期间连接可能短暂中断。失败时恢复操作前配置。', function() {
				return run(controller, '应用网络配置', function() { return api.networkApply({ revision: state.revision, settings: clone(draft) }); }, function() { return load(controller, 'network', true).then(function() { return controller.refreshData(true, true); }); });
			}); }, locked)
		]) ])
	]);
}

function download(name, content, type) {
	const url = URL.createObjectURL(new Blob([content], { type: type || 'application/json' }));
	const link = E('a', { href: url, download: name });
	document.body.appendChild(link); link.click(); link.remove();
	setTimeout(function() { URL.revokeObjectURL(url); }, 1000);
}
function editProfile(controller, profile) {
	const state = controller.maintenanceState;
	function display(value) {
		const id = input(value.id || '', function() {}, 'text', { 'aria-label': '文件名', disabled: !!profile, placeholder: 'profile.yaml' });
		const content = E('textarea', { 'class': 'cbi-input-textarea netfleet-profile-editor', 'rows': 18, 'spellcheck': 'false', 'aria-label': '配置内容' }, value.content || '');
		const errorBox = E('p', { 'class': 'is-warning', 'role': 'alert' });
		const save = button('校验并保存', function() {
			if (disabled(controller)) return;
			save.disabled = true;
			api.profileSave({ revision: value.revision || state.revision, id: id.value.trim(), content: content.value }).then(function() {
				content.value = ''; ui.hideModal(); return load(controller, 'maintenance', true);
			}).catch(function(error) { errorBox.textContent = errorText(error); save.disabled = false; });
		}, profile && !profile.editable);
		const upload = E('input', { type: 'file', accept: '.json,.yaml,.yml', 'change': function(event) {
			const file = event.target.files[0]; if (!file) return;
			if (file.size > 8 * 1024 * 1024) { errorBox.textContent = '文件不能超过 8 MiB'; return; }
			file.text().then(function(text) { content.value = text; if (!profile) id.value = file.name; });
		} });
		ui.showModal(profile ? '编辑配置文件' : '导入配置文件', [ E('div', { 'class': 'netfleet-native netfleet-source-form' }, [ row('文件名', id), row('导入文件', upload), content, errorBox,
			E('div', { 'class': 'right' }, [ button('取消', function() { content.value = ''; ui.hideModal(); }), ' ', save ]) ]) ]);
	}
	if (!profile) { display({}); return; }
	ui.showModal('读取配置文件', [ E('p', { 'class': 'spinning' }, '正在读取…') ]);
	return api.profileGet(profile.id).then(function(result) { display(Object.assign({}, result.profile, { revision: result.revision })); }).catch(function(error) { ui.hideModal(); notice(error); });
}
function files(controller) {
	const state = controller.maintenanceState;
	if (!state) return pending(controller, 'maintenance', '配置文件与备份');
	if (!state.supported) return E('p', { 'class': 'alert-message warning' }, '当前后端由外部插件管理，请在对应插件中维护配置文件。');
	const locked = disabled(controller);
	const backupFile = E('input', { 'type': 'file', accept: '.json', 'disabled': locked, 'aria-label': '选择配置备份', 'change': function(event) {
		const file = event.target.files[0]; if (!file) return;
		if (file.size > 32 * 1024 * 1024) { notice(new Error('backup_too_large')); return; }
		file.text().then(function(text) {
			const backup = JSON.parse(text);
			confirm('恢复配置备份', '将替换 NetFleet 自有配置与订阅。备份不包含系统网络配置；失败时恢复操作前状态。', function() {
				return run(controller, '恢复配置备份', function() { return api.backupRestore({ revision: state.revision, confirm: true, backup: backup }); }, function() {
					controller.networkState = null; controller.subscriptionState = null;
					return load(controller, 'maintenance', true).then(function() { return controller.refreshData(true, true); });
				});
			});
		}).catch(notice).finally(function() { event.target.value = ''; });
	} });
	return E('section', {}, [ E('div', { 'class': 'netfleet-section-heading' }, [ E('h3', {}, '配置文件'), E('div', { 'class': 'netfleet-inline-actions' }, [
		button('重新读取', function() { return load(controller, 'maintenance', true); }, !!controller.maintenanceRead), button('导入配置', function() { editProfile(controller); }, locked) ]) ]),
		table(['文件名', '大小', '更新时间', '状态', '操作'], (state.profiles || []).map(function(profile) {
			return E('tr', {}, [ E('td', {}, profile.id), E('td', {}, Math.ceil(profile.size_bytes / 1024) + ' KiB'), E('td', {}, time(profile.modified_at)),
				E('td', {}, profile.referenced ? '使用中' : '未使用'), E('td', { 'class': 'netfleet-inline-actions' }, [
					button('下载', function() { return api.profileGet(profile.id).then(function(result) { download(profile.id, result.profile.content, 'text/plain'); }).catch(notice); }, locked),
					button('编辑', function() { return editProfile(controller, profile); }, locked || !profile.editable),
					button('删除', function() { confirm('删除配置文件', '确认删除 ' + profile.id + '？', function() {
						return run(controller, '删除配置文件', function() { return api.profileDelete({ revision: state.revision, id: profile.id }); }, function() { return load(controller, 'maintenance', true); });
					}); }, locked || profile.referenced, true) ]) ]);
		})),
		E('section', { 'class': 'netfleet-management-section' }, [ E('h3', {}, '配置备份与恢复'), E('p', { 'class': 'is-warning' }, '备份包含订阅地址、认证信息等私有数据，请妥善保管。'),
			row('导出配置', button('下载备份', function() { return api.backupExport().then(function(result) { download('netfleet-backup-' + new Date().toISOString().slice(0, 10) + '.json', JSON.stringify(result.backup || result, null, 2)); }).catch(notice); }, locked)),
			row('恢复配置', backupFile)
		])
	]);
}
function maintenance(controller) {
	const state = controller.maintenanceState;
	const diagnostics = controller.diagnosticsState;
	return E('section', { 'class': 'cbi-section netfleet-maintenance' }, [ E('div', { 'class': 'netfleet-section-heading' }, [ E('h3', {}, '核心维护'),
		E('div', { 'class': 'netfleet-inline-actions' }, [ button('读取日志', function() { return load(controller, 'diagnostics', true); }, !!controller.diagnosticsRead) ].concat(['reload', 'restart'].map(function(action) {
			const label = action === 'reload' ? '重载配置' : '重启核心';
			return button(label, function() { confirm(label, '将重新加载当前配置并确认网络恢复，期间连接可能短暂中断。', function() {
				return run(controller, label, function() { return api.coreAction({ revision: state.revision, action: action, confirm: true }); }, function() {
					return load(controller, 'maintenance', true).then(function() { return load(controller, 'diagnostics', true); }).then(function() { return controller.refreshData(true); });
				});
			}); }, disabled(controller) || !state || !state.supported || !(state.core.actions || []).includes(action));
		}))) ]),
		controller.diagnosticsError ? E('p', { 'class': 'is-warning' }, errorText(controller.diagnosticsError)) : '',
		diagnostics ? E('pre', { 'class': 'netfleet-core-log', 'aria-label': '核心启动与运行日志' }, (diagnostics.lines || []).map(function(line) { return typeof line === 'string' ? line : line.message || ''; }).join('\n') || '暂无日志') : E('p', {}, '尚未读取核心日志')
	]);
}
function dashboard(controller) {
	const state = controller.components && controller.components.dashboard;
	if (!state) return E('div');
	const active = controller.dashboardBusy || disabled(controller);
	function execute(action) {
		if (disabled(controller) || controller.dashboardBusy) return Promise.resolve();
		controller.dashboardBusy = true; controller.redraw();
		return (action === 'check' ? api.dashboardCheck() : api.dashboardUpdate(state.available_version)).then(function(result) {
			controller.components.dashboard = result; controller.dashboardError = null;
		}).catch(function(error) { controller.dashboardError = error; }).finally(function() { controller.dashboardBusy = false; controller.redraw(); });
	}
	return E('section', { 'class': 'netfleet-management-section' }, [ E('div', { 'class': 'netfleet-section-heading' }, [ E('h3', {}, 'Zashboard'), E('div', { 'class': 'netfleet-inline-actions' }, [
		button('检查更新', function() { return execute('check'); }, active || !state.managed),
		button('更新资源', function() { confirm('更新 Zashboard', '只更新面板资源，不重启核心；失败时保留当前面板。', function() { return execute('update'); }); }, active || !state.update_available)
	]) ]),
		table(['已安装版本', '可用版本', '最后检查'], [ E('tr', {}, [ E('td', {}, state.installed_version || (state.available ? '版本未记录' : '未安装')), E('td', {}, state.available_version || '尚未检查'), E('td', {}, time(state.checked_at)) ]) ]),
		controller.dashboardBusy ? E('p', { 'class': 'spinning', 'role': 'status' }, '正在检查或更新面板资源…') : '',
		controller.dashboardError ? E('p', { 'class': 'is-warning', 'role': 'alert' }, errorText(controller.dashboardError)) : ''
	]);
}

return baseclass.extend({ load: load, network: network, files: files, maintenance: maintenance, dashboard: dashboard });
