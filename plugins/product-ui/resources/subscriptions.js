/* SPDX-License-Identifier: Apache-2.0 */
'use strict';
const { errorLabel, failure, button, notify, runSubscription, quotaResetLabel } = managed;
function userAgentControl(value) {
	return new ui.Combobox(value || 'clash.meta', { 'clash': 'clash', 'clash.meta': 'clash.meta', 'mihomo': 'mihomo' }, {
		id: 'netfleet-source-user-agent', sort: false, custom_placeholder: '自定义 User-Agent'
	});
}



function editSource(controller, state, existing) {
	const values = {};
	const fields = [
		[ 'id', '订阅标识', 'text', existing && existing.id, !existing ],
		[ 'name', '名称', 'text', existing && existing.name, true ],
		[ 'alias', '账户备注（可选）', 'text', existing && existing.alias, false ],
		[ 'url', '订阅地址', 'url', existing && existing.url, true ],
		[ 'info_url', '用量查询地址（可选）', 'url', existing && existing.info_url, false ]
	];
	const controls = fields.map(function(field) {
		const input = E('input', { 'class': 'cbi-input-text', 'type': field[2], 'value': field[3] || '', 'required': field[4] || null,
			'disabled': field[0] === 'id' && existing ? true : null, 'autocomplete': 'off', 'spellcheck': 'false', 'id': 'netfleet-source-' + field[0] });
		values[field[0]] = input;
		return E('div', { 'class': 'netfleet-source-row' }, [ E('label', { 'for': 'netfleet-source-' + field[0] }, field[1]), input ]);
	});
	const userAgent = userAgentControl(existing && existing.user_agent);
	controls.splice(3, 0, E('div', { 'class': 'netfleet-source-row' }, [ E('label', { 'for': 'netfleet-source-user-agent' }, 'User-Agent'), userAgent.render() ]));
	const resetDay = E('select', { 'class': 'cbi-input-select', 'id': 'netfleet-source-reset-day' },
		[ E('option', { 'value': '' }, '未设置') ].concat(Array.from({ length: 31 }, function(_, index) {
			const day = index + 1;
			return E('option', { 'value': String(day), 'selected': existing && existing.quota_reset_day === day ? true : null }, '每月 ' + day + ' 日');
		})));
	controls.push(E('div', { 'class': 'netfleet-source-row' }, [ E('label', { 'for': 'netfleet-source-reset-day' }, '每月流量重置日'), resetDay ]));
	const errorBox = E('p', { 'class': 'is-warning', 'role': 'alert' });
	const save = button('保存订阅', function() {
		if (fields.some(function(field) { return field[4] && !values[field[0]].value.trim(); }) || !/^[A-Za-z0-9_]+$/.test(values.id.value.trim())) {
			errorBox.textContent = '请填写名称和地址；订阅标识仅限英文字母、数字和下划线。';
			return;
		}
		const source = { id: values.id.value.trim(), name: values.name.value.trim(), alias: values.alias.value.trim(),
			url: values.url.value.trim(), user_agent: (userAgent.getValue() || 'clash.meta').trim(), info_url: values.info_url.value.trim(),
			quota_reset_day: resetDay.value === '' ? null : Number(resetDay.value) };
		save.disabled = true;
		controller.invalidateReads?.();
		api.subscriptionsSet({ revision: state.revision, source: source }).then(function(saved) {
			controller.subscriptionState = saved && Array.isArray(saved.sources) ? saved : null;
			controller.subscriptionsChanged = true;
			values.url.value = ''; values.info_url.value = '';
			return showSubscriptions(controller);
		}).catch(function(error) { errorBox.textContent = failure(error); save.disabled = false; });
	});
	ui.showModal(existing ? '编辑订阅' : '新增订阅', [ E('div', { 'class': 'netfleet-native netfleet-source-form' }, controls.concat([ errorBox,
		E('div', { 'class': 'right' }, [ button('返回', function() { showSubscriptions(controller); }), ' ', save ]) ])) ]);
}

function loadSubscriptions(controller) {
	if (controller.subscriptionRead) return controller.subscriptionRead;
	controller.subscriptionRead = api.subscriptionsGet().then(function(state) {
		controller.subscriptionState = state;
		return state;
	}).finally(function() { controller.subscriptionRead = null; });
	return controller.subscriptionRead;
}

function showSubscriptions(controller, refresh) {
	const display = function(state) {
		if (state.managed_by !== 'netfleet') {
			ui.showModal('管理订阅', [ E('a', { 'href': L.url('admin/services/nikki/profile'), 'target': '_blank', 'rel': 'noopener' }, '打开 Nikki 订阅管理'), E('div', { 'class': 'right' }, button('关闭', ui.hideModal)) ]);
			return;
		}
		const rows = (state.sources || []).map(function(source) {
			const label = source.display_name || [ source.name || source.id, source.alias ].filter(Boolean).join(' · ');
			return E('tr', {}, [ E('td', {}, label), E('td', {}, source.node_count == null ? '未提供' : String(source.node_count)),
				E('td', { 'title': '手动设置，仅供套餐参考；实际结算以机场为准' }, quotaResetLabel(source.quota_reset_day) || '未设置'),
				E('td', {}, source.has_url ? '已保存' : '未配置'),
				E('td', {}, source.pending_update ? (source.using_previous_cache ? '待更新，继续使用上次可用缓存' : '待更新订阅后生效') : source.cache_current ? '已生效' : '尚未更新'),
				E('td', {}, [ button('编辑', function() { editSource(controller, state, source); }), ' ',
					button('更新', function() {
						ui.showModal('更新订阅', [ E('p', {}, '只更新“' + label + '”。内容未变化时不重载；使用中的内容变化后会重启核心并重新选优，已有连接可能中断。尚未使用的订阅只更新缓存。'),
							E('div', { 'class': 'right' }, [ button('取消', function() { showSubscriptions(controller); }), ' ', button('确认更新', function() {
								return runSubscription(controller, function() { return api.subscriptionsRefresh(source.id); });
							}) ]) ]);
					}), ' ',
					button('删除', function() {
						ui.showModal('删除订阅', [ E('p', {}, '确认删除“' + label + '”？仍被配置或运行状态引用的订阅不能删除。'),
							E('div', { 'class': 'right' }, [ button('取消', function() { showSubscriptions(controller); }), ' ', button('确认删除', function(event) {
								event.target.disabled = true;
								controller.invalidateReads?.();
								api.subscriptionsSet({ revision: state.revision, source: { id: source.id }, delete: true }).then(function(saved) {
									controller.subscriptionState = saved && Array.isArray(saved.sources) ? saved : null;
									controller.subscriptionsChanged = true;
									showSubscriptions(controller);
								}).catch(function(error) {
									notify(null, E('p', {}, failure(error)), 'error'); showSubscriptions(controller);
								});
							}, false, true) ]) ]);
					}, false, true) ]) ]);
		});
		ui.showModal('管理订阅', [
			E('p', {}, '地址与 User-Agent 修改后待更新订阅生效；名称、账户备注与重置日保存即生效。账户备注仅用于本机区分。'),
			E('table', { 'class': 'table' }, [ E('thead', {}, E('tr', {}, [ '名称', '节点', '流量重置日', '订阅地址', '状态', '操作' ].map(function(label) { return E('th', {}, label); }))), E('tbody', {}, rows) ]),
			E('div', { 'class': 'right' }, [ button('刷新列表', function() { return showSubscriptions(controller, true); }), ' ', button('新增订阅', function() { editSource(controller, state, null); }), ' ', button('关闭', function() {
				ui.hideModal();
				if (controller.subscriptionsChanged) {
					controller.subscriptionsChanged = false;
					if (controller.onboarding) controller.refreshOnboarding(); else controller.refreshData(true, true);
				}
			}) ])
		]);
	};
	if (controller.subscriptionState && !refresh) {
		display(controller.subscriptionState);
		return Promise.resolve();
	}
	let closed = false;
	ui.showModal('管理订阅', [ E('p', { 'class': 'spinning' }, '正在读取订阅…'), button('关闭', function() { closed = true; ui.hideModal(); }) ]);
	return loadSubscriptions(controller).then(function(state) { if (!closed) display(state); }).catch(function(error) {
		if (!closed) ui.showModal('管理订阅', [ E('p', { 'role': 'alert' }, failure(error)), button('重试', function() { return showSubscriptions(controller, true); }), button('关闭', ui.hideModal) ]);
	});
}

function migration(controller) {
	ui.showModal('迁移到 NetFleet 原生后端', [ E('p', { 'class': 'spinning' }, '正在检查迁移条件…') ]);
	return api.migrationGet().then(function(state) {
		const controls = [ E('p', {}, '确认后，NetFleet 将接管机场订阅、Mihomo、DNS 和透明代理。设备会检查新后端；失败时恢复旧后端。迁移期间网络可能短暂中断。') ];
		if (!state.ready) controls.push(E('p', { 'class': 'is-warning' }, '当前不能迁移：' + (state.missing || []).map(function(item) { return errorLabel(typeof item === 'string' ? item : item.error || item.code || item.name); }).join('、')));
		controls.push(E('div', { 'class': 'right' }, [ button('取消', ui.hideModal), ' ', button('确认迁移', function() {
			controller.busy = true;
			ui.showModal('迁移到 NetFleet 原生后端', [ E('p', { 'class': 'spinning' }, '正在迁移并等待设备回读…') ]);
			controller.invalidateReads?.();
			api.migrationApply({ revision: state.revision, confirmed: true, backend: 'native-mihomo' }).then(function() { return controller.refreshData(true, true); }).then(function() {
				ui.hideModal(); notify(null, E('p', {}, '迁移已完成，运行状态已从设备重新读取。'), 'info');
			}).catch(function(error) {
				ui.hideModal(); notify(null, E('p', {}, '迁移未确认成功：' + failure(error)), 'error');
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
		const url = E('input', { 'class': 'cbi-input-text', 'type': 'url', 'required': true, 'autocomplete': 'off' });
		const userAgent = userAgentControl();
		const errorBox = E('p', { 'class': 'is-warning', 'role': 'alert' });
		const submit = button('确认接入', function() {
			if (!id.value.trim() || !name.value.trim() || !url.value.trim()) { errorBox.textContent = '请填写标识、名称和订阅地址。'; return; }
			submit.disabled = true;
			controller.invalidateReads?.();
			api.nativeSetupApply({ revision: state.revision, confirmed: true, source: { id: id.value.trim(), name: name.value.trim(), url: url.value.trim(), user_agent: userAgent.getValue() || 'clash.meta' } }).then(function() {
				url.value = ''; ui.hideModal(); return controller.refreshOnboarding();
			}).catch(function(error) { errorBox.textContent = failure(error); submit.disabled = false; });
		});
		ui.showModal('首次接入 Mihomo', [ E('p', {}, 'NetFleet 将下载订阅并启动原生后端，接管 DNS 与透明代理。失败时撤销本次网络接管。'),
			E('div', { 'class': 'netfleet-native netfleet-source-form' }, [ [ '订阅标识', id ], [ '名称', name ], [ '订阅地址', url ], [ 'User-Agent', userAgent.render() ] ].map(function(field) {
				return E('label', { 'class': 'netfleet-source-row' }, [ E('span', {}, field[0]), field[1] ]);
			})), errorBox, E('div', { 'class': 'right' }, [ button('取消', ui.hideModal), ' ', submit ]) ]);
	}).catch(function(error) { ui.showModal('首次接入失败', [ E('p', {}, failure(error)), button('关闭', ui.hideModal) ]); });
}


return baseclass.extend({ preloadSubscriptions: loadSubscriptions, subscriptions: showSubscriptions, migration, nativeSetup });
