/* SPDX-License-Identifier: MIT */
'use strict';
'require baseclass';
'require ui';
'require netfleet.api as api';

function failure(error) {
	const detail = error && error.detail;
	if (detail && detail.rollback)
		return String(error && error.message || '执行失败') + '；' + (detail.rollback.ok === true ? '已恢复旧后端' : '旧后端恢复未确认，请检查网络') + (detail.rollback.error ? '（' + String(detail.rollback.error) + '）' : '');
	const outcome = detail && (detail.outcome || detail.recovery_result || detail.error);
	return String(error && error.message || '设备未返回成功结果') + (outcome ? '；恢复结果：' + String(outcome) : '');
}

function button(label, click, disabled, destructive) {
	return E('button', { 'class': 'btn cbi-button' + (destructive ? ' cbi-button-negative' : ''), 'type': 'button', 'disabled': disabled || null, 'click': click }, label);
}

function editSource(controller, state, existing) {
	const values = {};
	const fields = [
		[ 'id', '订阅标识', 'text', existing && existing.id, !existing ],
		[ 'name', '名称', 'text', existing && existing.name, true ],
		[ 'url', '订阅地址', 'password', '', !existing ],
		[ 'user_agent', 'User-Agent（可选）', 'text', '', false ],
		[ 'info_url', '用量查询地址（可选）', 'password', '', false ]
	];
	const controls = fields.map(function(field) {
		const input = E('input', { 'class': 'cbi-input-text', 'type': field[2], 'value': field[3] || '', 'required': field[4] || null,
			'disabled': field[0] === 'id' && existing ? true : null, 'autocomplete': 'off',
			'placeholder': existing && ((field[0] === 'url' && existing.has_url) || (field[0] === 'info_url' && existing.has_info_url)) ? '已保存，留空保持不变' : '' });
		values[field[0]] = input;
		return E('div', { 'class': 'netfleet-config-row' }, [ E('label', {}, field[1]), input ]);
	});
	const errorBox = E('p', { 'class': 'is-warning', 'role': 'alert' });
	const save = button('保存订阅', function() {
		if (fields.some(function(field) { return field[4] && !values[field[0]].value.trim(); }) || !/^[A-Za-z0-9_]+$/.test(values.id.value.trim())) {
			errorBox.textContent = '请填写订阅标识、名称和新订阅地址。';
			return;
		}
		const source = { id: values.id.value.trim(), name: values.name.value.trim() };
		[ 'url', 'user_agent', 'info_url' ].forEach(function(key) { if (values[key].value.trim()) source[key] = values[key].value.trim(); });
		save.disabled = true;
		api.subscriptionsSet({ revision: state.revision, source: source }).then(function() {
			values.url.value = ''; values.info_url.value = '';
			return showSubscriptions(controller);
		}).catch(function(error) { errorBox.textContent = failure(error); save.disabled = false; });
	});
	ui.showModal(existing ? '编辑订阅' : '新增订阅', controls.concat([ errorBox,
		E('div', { 'class': 'right' }, [ button('返回', function() { showSubscriptions(controller); }), ' ', save ]) ]));
}

function showSubscriptions(controller) {
	ui.showModal('管理订阅', [ E('p', { 'class': 'spinning' }, '正在读取订阅…') ]);
	return api.subscriptionsGet().then(function(state) {
		if (state.managed_by !== 'netfleet') {
			ui.showModal('管理订阅', [ E('a', { 'href': L.url('admin/services/nikki/profile'), 'target': '_blank', 'rel': 'noopener' }, '打开 Nikki 订阅管理'), E('div', { 'class': 'right' }, button('关闭', ui.hideModal)) ]);
			return;
		}
		const active = Boolean(controller.status && controller.status.active);
		const rows = (state.sources || []).map(function(source) {
			return E('tr', {}, [ E('td', {}, source.name || source.id), E('td', {}, String(source.node_count ?? 0)),
				E('td', {}, source.has_url ? '已保存' : '未配置'),
				E('td', {}, [ button('编辑', function() { editSource(controller, state, source); }, active), ' ',
					button('删除', function() {
						ui.showModal('删除订阅', [ E('p', {}, '确认删除“' + (source.name || source.id) + '”？已引用此订阅的机场配置需要重新选择。'),
							E('div', { 'class': 'right' }, [ button('取消', function() { showSubscriptions(controller); }), ' ', button('确认删除', function(event) {
								event.target.disabled = true;
								api.subscriptionsSet({ revision: state.revision, source: { id: source.id }, delete: true }).then(function() { showSubscriptions(controller); }).catch(function(error) {
									ui.addNotification(null, E('p', {}, failure(error)), 'error'); showSubscriptions(controller);
								});
							}, false, true) ]) ]);
					}, active, true) ]) ]);
		});
		ui.showModal('管理订阅', [
			active ? E('p', { 'class': 'is-warning' }, '请先关闭 NetFleet，再新增、编辑或删除订阅。') : E('p', {}, '订阅地址已隐藏。'),
			E('table', { 'class': 'table' }, [ E('thead', {}, E('tr', {}, [ '名称', '节点', '订阅地址', '操作' ].map(function(label) { return E('th', {}, label); }))), E('tbody', {}, rows) ]),
			E('div', { 'class': 'right' }, [ button('新增订阅', function() { editSource(controller, state, null); }, active), ' ', button('关闭', function() {
				ui.hideModal();
				if (controller.onboarding) controller.refreshOnboarding(); else controller.refreshData(true, true);
			}) ])
		]);
	}).catch(function(error) { ui.showModal('管理订阅', [ E('p', { 'role': 'alert' }, failure(error)), button('关闭', ui.hideModal) ]); });
}

function migration(controller) {
	ui.showModal('迁移到 NetFleet 原生后端', [ E('p', { 'class': 'spinning' }, '正在检查迁移条件…') ]);
	return api.migrationGet().then(function(state) {
		const controls = [ E('p', {}, '确认后，NetFleet 将接管机场订阅、Mihomo、DNS 和透明代理。设备会检查新后端；失败时恢复旧后端。迁移期间网络可能短暂中断。') ];
		if (!state.ready) controls.push(E('p', { 'class': 'is-warning' }, '当前不能迁移：' + (state.missing || []).map(function(item) { return typeof item === 'string' ? item : item.error || item.code || item.name; }).join('、')));
		controls.push(E('div', { 'class': 'right' }, [ button('取消', ui.hideModal), ' ', button('确认迁移', function() {
			controller.busy = true;
			ui.showModal('迁移到 NetFleet 原生后端', [ E('p', { 'class': 'spinning' }, '正在迁移并等待设备回读…') ]);
			api.migrationApply({ revision: state.revision, confirmed: true, backend: 'native-mihomo' }).then(function() { return controller.refreshData(true, true); }).then(function() {
				ui.hideModal(); ui.addNotification(null, E('p', {}, '迁移已完成，运行状态已从设备重新读取。'), 'info');
			}).catch(function(error) {
				ui.hideModal(); ui.addNotification(null, E('p', {}, '迁移未确认成功：' + failure(error)), 'error');
			}).finally(function() { controller.busy = false; controller.redraw(); });
		}, !state.ready) ]));
		ui.showModal('迁移到 NetFleet 原生后端', controls);
	}).catch(function(error) { ui.showModal('迁移检查失败', [ E('p', {}, failure(error)), button('关闭', ui.hideModal) ]); });
}

function nativeSetup(controller) {
	ui.showModal('首次接入 Mihomo', [ E('p', { 'class': 'spinning' }, '正在检查运行环境…') ]);
	return api.nativeSetupGet().then(function(state) {
		if (!state.ready) {
			ui.showModal('首次接入 Mihomo', [ E('p', { 'class': 'is-warning' }, '当前不能接入：' + (state.missing || []).map(function(item) { return typeof item === 'string' ? item : item.code || item.error; }).join('、')), button('关闭', ui.hideModal) ]);
			return;
		}
		const id = E('input', { 'class': 'cbi-input-text', 'required': true });
		const name = E('input', { 'class': 'cbi-input-text', 'required': true });
		const url = E('input', { 'class': 'cbi-input-text', 'type': 'password', 'required': true, 'autocomplete': 'off' });
		const userAgent = E('input', { 'class': 'cbi-input-text' });
		const errorBox = E('p', { 'class': 'is-warning', 'role': 'alert' });
		const submit = button('确认接入', function() {
			if (!id.value.trim() || !name.value.trim() || !url.value.trim()) { errorBox.textContent = '请填写标识、名称和订阅地址。'; return; }
			submit.disabled = true;
			api.nativeSetupApply({ revision: state.revision, confirmed: true, source: { id: id.value.trim(), name: name.value.trim(), url: url.value.trim(), user_agent: userAgent.value.trim() || undefined } }).then(function() {
				url.value = ''; ui.hideModal(); return controller.refreshOnboarding();
			}).catch(function(error) { errorBox.textContent = failure(error); submit.disabled = false; });
		});
		ui.showModal('首次接入 Mihomo', [ E('p', {}, 'NetFleet 将下载订阅并启动原生后端，接管 DNS 与透明代理。失败时撤销本次网络接管。'),
			E('div', { 'class': 'netfleet-config-rows' }, [ [ '订阅标识', id ], [ '名称', name ], [ '订阅地址', url ], [ 'User-Agent（可选）', userAgent ] ].map(function(field) {
				return E('div', { 'class': 'netfleet-config-row' }, [ E('label', {}, field[0]), field[1] ]);
			})), errorBox, E('div', { 'class': 'right' }, [ button('取消', ui.hideModal), ' ', submit ]) ]);
	}).catch(function(error) { ui.showModal('首次接入失败', [ E('p', {}, failure(error)), button('关闭', ui.hideModal) ]); });
}

return baseclass.extend({ subscriptions: showSubscriptions, migration: migration, nativeSetup: nativeSetup });
