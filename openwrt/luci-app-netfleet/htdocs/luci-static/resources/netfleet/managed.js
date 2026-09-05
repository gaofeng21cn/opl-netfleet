/* SPDX-License-Identifier: MIT */
'use strict';
'require baseclass';
'require ui';
'require netfleet.api as api';

function errorLabel(code) {
	return ({
		subscription_revision_changed: '订阅已被其他操作修改，请重新读取后保存',
		invalid_subscription_id: '订阅标识只能包含英文字母、数字和下划线',
		invalid_subscription_url: '订阅地址必须是有效的 HTTP 或 HTTPS 地址',
		subscription_referenced_by_policy: '订阅仍被机场策略引用，请先调整配置',
		subscription_selected_as_profile: '订阅仍是当前运行配置，不能删除',
		subscription_referenced_by_runtime: '运行配置仍使用该订阅，不能删除',
		running_profile_unreadable: '无法确认运行配置的引用关系，暂不能删除',
		subscription_cache_owner_unknown: '已有同名缓存但无法确认其归属，未覆盖',
		mutation_busy: '设备正在执行其他操作，请稍后重试',
		already_native: '已经使用 NetFleet 原生后端',
		existing_native_configuration: '已有原生后端配置，不能覆盖',
		existing_backend_owner: '已有代理后端运行，不能覆盖',
		existing_native_owner: '原生后端尚未清理，不能重复接入',
		source_backend_not_running: '请先恢复当前 Nikki 后端正常运行',
		source_backend_disabled: '当前 Nikki 后端未启用',
		policy_disabled: '请先启用 NetFleet 并验证运行正常',
		native_gateway_unavailable: '尚未安装原生网络接管组件',
		native_dependencies_unavailable: '原生后端依赖尚未齐备',
		upstream_dns_unavailable: '没有可用的上游 DNS',
		source_resource_unavailable: '缺少当前配置引用的本地资源',
		profile_or_subscription_unavailable: '当前原生配置或订阅缓存不可读取'
	})[code] || String(code || '设备未返回成功结果');
}

function failure(error) {
	const detail = error && error.detail;
	if (detail && detail.rollback)
		return errorLabel(error && error.message) + '；' + (detail.rollback.ok === true ? '已恢复更新前状态' : '恢复未确认，请检查网络') + (detail.rollback.error ? '（' + String(detail.rollback.error) + '）' : '');
	const outcome = detail && (detail.outcome || detail.recovery_result || detail.error);
	return errorLabel(error && error.message) + (outcome ? '；恢复结果：' + String(outcome) : '');
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
	const clearInfo = E('input', { 'type': 'checkbox' });
	if (existing && existing.has_info_url)
		controls.push(E('label', { 'class': 'netfleet-check' }, [ clearInfo, '清除已保存的用量查询地址' ]));
	const errorBox = E('p', { 'class': 'is-warning', 'role': 'alert' });
	const save = button('保存订阅', function() {
		if (fields.some(function(field) { return field[4] && !values[field[0]].value.trim(); }) || !/^[A-Za-z0-9_]+$/.test(values.id.value.trim())) {
			errorBox.textContent = '请填写名称和地址；订阅标识仅限英文字母、数字和下划线。';
			return;
		}
		const source = { id: values.id.value.trim(), name: values.name.value.trim() };
		[ 'url', 'user_agent', 'info_url' ].forEach(function(key) { if (values[key].value.trim()) source[key] = values[key].value.trim(); });
		if (clearInfo.checked) source.info_url = '';
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
		const rows = (state.sources || []).map(function(source) {
			return E('tr', {}, [ E('td', {}, source.name || source.id), E('td', {}, source.node_count == null ? '未提供' : String(source.node_count)),
				E('td', {}, source.has_url ? '已保存' : '未配置'),
				E('td', {}, source.pending_update ? (source.using_previous_cache ? '待更新，继续使用上次可用缓存' : '待更新订阅后生效') : source.cache_current ? '已生效' : '尚未更新'),
				E('td', {}, [ button('编辑', function() { editSource(controller, state, source); }), ' ',
					button('更新', function() {
						ui.showModal('更新订阅', [ E('p', {}, '确认更新“' + (source.name || source.id) + '”？使用中的订阅发生变化时，将重载运行配置并重新选优。'),
							E('div', { 'class': 'right' }, [ button('取消', function() { showSubscriptions(controller); }), ' ', button('确认更新', function() {
								controller.busy = true;
								ui.showModal('更新订阅', [ E('p', { 'class': 'spinning' }, '正在更新并等待设备回读…') ]);
								api.subscriptionsRefresh(source.id).then(function() {
									return controller.onboarding ? controller.refreshOnboarding() : controller.refreshData(true, true);
								}).then(function() { return showSubscriptions(controller); }).catch(function(error) {
									ui.addNotification(null, E('p', {}, failure(error)), 'error'); return showSubscriptions(controller);
								}).finally(function() { controller.busy = false; controller.redraw(); });
							}) ]) ]);
					}), ' ',
					button('删除', function() {
						ui.showModal('删除订阅', [ E('p', {}, '确认删除“' + (source.name || source.id) + '”？仍被配置或运行状态引用的订阅不能删除。'),
							E('div', { 'class': 'right' }, [ button('取消', function() { showSubscriptions(controller); }), ' ', button('确认删除', function(event) {
								event.target.disabled = true;
								api.subscriptionsSet({ revision: state.revision, source: { id: source.id }, delete: true }).then(function() { showSubscriptions(controller); }).catch(function(error) {
									ui.addNotification(null, E('p', {}, failure(error)), 'error'); showSubscriptions(controller);
								});
							}, false, true) ]) ]);
					}, false, true) ]) ]);
		});
		ui.showModal('管理订阅', [
			E('p', {}, '来源修改保存后，待更新订阅才生效；当前运行继续使用上次可用缓存。'),
			E('table', { 'class': 'table' }, [ E('thead', {}, E('tr', {}, [ '名称', '节点', '订阅地址', '状态', '操作' ].map(function(label) { return E('th', {}, label); }))), E('tbody', {}, rows) ]),
			E('div', { 'class': 'right' }, [ button('新增订阅', function() { editSource(controller, state, null); }), ' ', button('关闭', function() {
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
		if (!state.ready) controls.push(E('p', { 'class': 'is-warning' }, '当前不能迁移：' + (state.missing || []).map(function(item) { return errorLabel(typeof item === 'string' ? item : item.error || item.code || item.name); }).join('、')));
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
			ui.showModal('首次接入 Mihomo', [ E('p', { 'class': 'is-warning' }, '当前不能接入：' + (state.missing || []).map(function(item) { return errorLabel(typeof item === 'string' ? item : item.code || item.error); }).join('、')), button('关闭', ui.hideModal) ]);
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
