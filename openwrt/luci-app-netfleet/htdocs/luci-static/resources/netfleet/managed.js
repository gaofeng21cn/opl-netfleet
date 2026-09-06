/* SPDX-License-Identifier: MIT */
'use strict';
'require baseclass';
'require ui';
'require netfleet.api as api';

function errorLabel(code) {
	if (typeof code === 'string' && code.endsWith('_rolled_back')) return errorLabel(code.slice(0, -12)) + '；已恢复更新前版本和运行状态';
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
		package_operation_busy: '设备正在检查或更新组件，请稍后重试',
		components_unavailable: '当前设备不支持组件管理，请先更新 NetFleet',
		package_version_changed: '可用版本已变化，请重新检查更新',
		package_candidate_changed: '可用版本已变化，请重新检查更新',
		package_update_failed: '组件更新失败，请查看更新结果',
		package_check_failed: '更新源检查失败，请检查设备联网状态',
		feed_unavailable: '更新源暂不可用',
		unsupported_architecture: '当前设备架构尚不支持此更新源',
		rollback_package_unavailable: '无法取得旧版签名回退包，未开始更新，仍保持原版',
		feed_check_failed: '更新源检查失败，当前安装版本不变',
		feed_not_configured: '尚未配置签名更新源',
		core_managed_externally: '核心由其他后端或系统软件包管理',
		package_not_installed: '未安装受管理的软件包',
		package_manager_unavailable: '设备软件包管理器不可用',
		candidate_changed: '候选版本已变化，请重新检查更新',
		candidate_download_failed: '新版签名包下载或校验失败，当前版本不变',
		dependency_resolution_failed: '无法确认依赖关系，未开始安装',
		dependency_change_requires_system_manager: '此次更新需要调整系统依赖，请使用 OpenWrt 软件包管理器',
		package_validation_failed: '安装预检失败，当前版本不变',
		insufficient_update_space: '存储或临时空间不足，未开始更新，仍保持原版',
		core_config_incompatible: '新核心无法通过当前配置校验，未开始更新',
		runtime_precondition_failed: '当前运行状态未通过检查，未开始更新',
		runtime_readback_failed: '无法读取当前运行状态，未开始更新',
		runtime_stop_failed: '未能确认服务已安全停止，请检查当前运行状态',
		package_install_failed: '软件包安装失败',
		package_identity_mismatch: '安装后的版本与目标不一致',
		runtime_verification_failed: '更新后的运行检查失败',
		rollback_stop_failed: '恢复前无法确认服务已停止，请检查当前运行状态',
		rollback_install_failed: '旧版软件包恢复失败，请检查当前运行状态',
		rollback_identity_mismatch: '恢复后的版本尚未确认',
		rollback_runtime_failed: '旧版已恢复，但运行状态未通过检查',
		unsafe_update_directory: '更新目录无法安全使用，未开始更新',
		update_stage_failed: '无法准备更新文件，未开始更新',
		update_state_write_failed: '无法保存更新状态',
		update_start_failed: '设备未能启动更新任务',
		update_identity_unavailable: '设备未能创建更新任务',
		update_request_changed: '更新条件已变化，请重新检查更新',
		invalid_component_request: '更新请求无效，请重新检查版本',
		component_operation_failed: '组件操作未完成，请检查设备状态',
		previous_update_incomplete: '上次更新尚未完整恢复，请先确认当前版本和运行状态',
		private_configuration_changed: '更新期间设备配置发生变化',
		rollback_configuration_failed: '未能恢复更新前配置，请检查当前网络与配置',
		operation_interrupted: '设备操作已中断，执行结果尚未确认',
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

const PHASE_LABELS = {
	preparing: '准备更新', checking: '检查更新源', downloading: '下载中', validating: '校验内容',
	compiling: '生成运行配置', reloading: '重载运行配置', selecting: '重新选优',
	installing: '安装组件', verifying: '确认运行状态', rolling_back: '恢复更新前状态', done: '已完成'
};

function isRunning(operation) { return operation && ['queued', 'running'].includes(operation.state); }

function operationNode(controller, kind) {
	const operation = controller.operations && controller.operations[kind];
	const pending = kind === 'subscription' && controller.subscriptionRequest;
	const disconnected = controller.operationError && (pending || isRunning(operation));
	const attrs = { 'class': 'netfleet-operation', 'data-netfleet-operation': kind, 'role': 'status', 'aria-live': 'polite' };
	if (!operation && !pending) return E('div', Object.assign(attrs, { 'hidden': true }));
	const active = pending || isRunning(operation);
	const state = disconnected ? '连接中断，执行结果尚未确认' : !operation ? '等待设备接收' :
		({ queued: '已提交，等待设备执行', running: PHASE_LABELS[operation.phase] || '处理中', succeeded: '已完成', failed: '执行失败', interrupted: '执行已中断，结果尚未确认' })[operation.state] || '等待设备确认';
	const started = operation && operation.started_at || controller.subscriptionStartedAt;
	const elapsed = started ? Math.max(0, Math.floor((operation && operation.finished_at || Date.now() / 1000) - started)) : 0;
	const details = [ E('strong', { 'class': active && !disconnected ? 'spinning' : '' }, state) ];
	if (operation && operation.subject) details.push(E('span', {}, kind === 'packages' ? ({ feed: '更新源', netfleet: 'NetFleet', mihomo: 'Mihomo' })[operation.subject] || String(operation.subject) : String(operation.subject)));
	if (operation && Number(operation.total) > 0) details.push(E('span', {}, (kind === 'subscription' ? '已处理 ' : '已完成 ') + Number(operation.completed || 0) + ' / ' + Number(operation.total) + (kind === 'subscription' ? ' 个机场' : ' 个文件')));
	details.push(E('span', {}, '已耗时 ' + (elapsed < 60 ? elapsed + ' 秒' : Math.floor(elapsed / 60) + ' 分 ' + elapsed % 60 + ' 秒')));
	if (operation && operation.error) details.push(E('span', { 'class': 'is-warning' }, errorLabel(operation.error)));
	if (operation && operation.recovery) details.push(E('span', {}, ({ restored: '已恢复更新前状态', failed: '恢复失败', direct: '已恢复网络直通' })[operation.recovery] || '恢复结果尚未确认'));
	return E('div', Object.assign(attrs, { 'class': attrs.class + (disconnected || operation && ['failed', 'interrupted'].includes(operation.state) ? ' is-warning' : '') }), [
		E('div', { 'class': 'netfleet-operation-title' }, kind === 'subscription' ? '机场订阅更新' : '组件与更新'),
		E('div', { 'class': 'netfleet-operation-detail' }, details)
	]);
}

function updateOperationNodes(controller) {
	if (typeof document === 'undefined') return;
	document.querySelectorAll('[data-netfleet-operation]').forEach(function(node) {
		node.replaceWith(operationNode(controller, node.getAttribute('data-netfleet-operation')));
	});
}

function readOperations(controller) {
	if (controller.operationRead) return controller.operationRead;
	clearTimeout(controller.operationTimer);
	controller.operationRead = api.operationGet().then(function(snapshot) {
		const previous = controller.operations && controller.operations.packages;
		if (controller.subscriptionRequest && snapshot.subscription && snapshot.subscription.id === controller.previousSubscriptionId) snapshot.subscription = null;
		if (controller.packageOperationId && (!snapshot.packages || snapshot.packages.id !== controller.packageOperationId) && isRunning(previous)) snapshot.packages = previous;
		controller.operations = snapshot;
		controller.operationError = null;
		const current = snapshot.packages;
		if (current && !isRunning(current) && previous && previous.id === current.id && isRunning(previous)) {
			loadComponents(controller).then(function() {
				if (current.state === 'succeeded' && (current.subject === 'netfleet' || controller.packageTarget && controller.packageTarget.component === 'netfleet')) {
					const component = controller.components && controller.components.components.find(function(item) { return item.id === 'netfleet'; });
					if (component && component.installed_version && (!controller.packageTarget || component.installed_version === controller.packageTarget.version))
						controller.refreshData(true).then(function() { window.location.reload(); }).catch(function() {
							controller.componentsError = new Error('版本已更新，运行状态尚未确认，请重新读取'); controller.redraw();
						});
					else controller.componentsError = new Error('更新后的版本尚未确认，请重新读取');
				}
				controller.redraw();
			});
		}
		return snapshot;
	}).catch(function(error) { controller.operationError = error; }).finally(function() {
		controller.operationRead = null;
		updateOperationNodes(controller);
		const snapshot = controller.operations || {};
		const running = controller.subscriptionRequest || isRunning(snapshot.subscription) || isRunning(snapshot.packages);
		if (running)
			controller.operationTimer = setTimeout(function() { if (!controller.root || controller.root.isConnected !== false) readOperations(controller); }, 1000);
	});
	return controller.operationRead;
}

function runSubscription(controller, request) {
	controller.busy = true;
	controller.subscriptionRequest = true;
	controller.subscriptionStartedAt = Math.floor(Date.now() / 1000);
	controller.previousSubscriptionId = controller.operations && controller.operations.subscription && controller.operations.subscription.id;
	controller.operations = Object.assign({}, controller.operations, { subscription: null });
	ui.showModal('更新机场订阅', [ E('div', { 'class': 'netfleet-native' }, [ operationNode(controller, 'subscription'),
		E('div', { 'class': 'right' }, button('收起进度', ui.hideModal)) ]) ]);
	controller.redraw();
	readOperations(controller);
	return Promise.resolve().then(request).then(function(result) {
		controller.subscriptionState = null;
		return controller.onboarding ? controller.refreshOnboarding().then(function() { return result; }) : controller.refreshData(true, true).then(function() { return result; });
	}).catch(function(error) {
		const uncertain = error && (error.netfleetKind === 'request_aborted' || /timeout|XHR|network/i.test(error.message || ''));
		ui.addNotification(null, E('p', {}, uncertain ? '连接中断，设备可能仍在更新；结果尚未确认。' : failure(error)), uncertain ? 'warning' : 'error');
	}).finally(function() {
		controller.subscriptionRequest = false;
		controller.busy = false;
		readOperations(controller).then(function() { controller.redraw(); });
	});
}

function loadComponents(controller) {
	if (controller.componentsRead) return controller.componentsRead;
	controller.componentsLoading = true;
	controller.componentsError = null;
	controller.componentsRead = api.componentsGet().then(function(snapshot) { controller.components = snapshot; }).catch(function(error) {
		controller.componentsError = error;
	}).finally(function() { controller.componentsLoading = false; controller.componentsRead = null; if (controller.currentView === 'components') controller.redraw(); });
	return controller.componentsRead;
}

function startPackageOperation(controller, component) {
	controller.componentsError = null;
	controller.componentsStarting = true;
	controller.packageTarget = component ? { component: component.id, version: component.available_version } : null;
	controller.redraw();
	const request = component ? api.componentsUpdate(component.id, component.available_version) : api.componentsCheck();
	return request.then(function(result) {
		controller.packageOperationId = result.operation.id;
		controller.operations = Object.assign({}, controller.operations, { packages: result.operation });
		return readOperations(controller);
	}).catch(function(error) { controller.componentsError = error; }).finally(function() { controller.componentsStarting = false; controller.redraw(); });
}

function componentsPage(controller) {
	const snapshot = controller.components;
	const operation = controller.operations && controller.operations.packages;
	const active = controller.componentsStarting || isRunning(operation);
	const content = [ E('div', { 'class': 'netfleet-section-heading' }, [ E('h3', {}, '已安装组件'), E('div', { 'class': 'netfleet-inline-actions' }, [
		button('重新读取', function() { loadComponents(controller); readOperations(controller); }, controller.componentsLoading),
		button('检查更新', function() { return startPackageOperation(controller); }, active || !snapshot || !snapshot.supported)
	]) ]), operationNode(controller, 'packages') ];
	if (controller.componentsError) content.push(E('p', { 'class': 'is-warning', 'role': 'alert' }, '组件信息未能确认：' + errorLabel(controller.componentsError.message)));
	if (!snapshot) {
		content.push(E('p', { 'class': controller.componentsLoading ? 'spinning' : '' }, controller.componentsLoading ? '正在读取已安装组件…' : '当前设备未提供组件管理接口，请确认 NetFleet 已更新。'));
		return E('section', { 'class': 'cbi-section netfleet-components' }, content);
	}
	const rows = snapshot.components.map(function(component) {
		const canUpdate = snapshot.supported && component.managed && component.update_available && component.available_version;
		const update = component.id === 'luci' ? E('span', { 'class': 'netfleet-muted' }, '随 NetFleet 更新') : button('更新', function() {
			ui.showModal('更新 ' + component.label, [ E('p', {}, (component.id === 'mihomo' ? '核心更新会短暂中断代理连接，设备将校验当前配置并检查重启后的运行状态。' : '将同时更新 NetFleet 与 LuCI 界面，完成后重新载入页面。') + '目标版本：' + component.available_version),
				E('div', { 'class': 'right' }, [ button('取消', ui.hideModal), ' ', button('确认更新', function() { ui.hideModal(); return startPackageOperation(controller, component); }) ]) ]);
		}, active || !canUpdate);
		return E('tr', {}, [ E('td', {}, component.label), E('td', {}, component.installed_version || '未安装'), E('td', {}, component.running_version || (component.id === 'mihomo' ? '未提供' : '不适用')),
			E('td', {}, component.available_version || '尚未检查'), E('td', {}, component.reason ? errorLabel(component.reason) : component.update_available ? '可更新' : component.available_version ? '已是当前源最新版本' : '等待检查'), E('td', {}, update) ]);
	});
	content.push(E('div', { 'class': 'table cbi-section-table netfleet-component-table' }, E('table', { 'class': 'table' }, [
		E('thead', {}, E('tr', {}, ['组件', '已安装版本', '运行版本', '可用版本', '状态', '操作'].map(function(label) { return E('th', {}, label); }))), E('tbody', {}, rows)
	])));
	const feed = snapshot.feed || {};
	content.push(E('h3', {}, '更新源'), E('dl', { 'class': 'netfleet-component-meta' }, [
		E('dt', {}, '设备架构'), E('dd', {}, snapshot.architecture || '未提供'), E('dt', {}, 'Feed'), E('dd', {}, feed.configured ? feed.url || '已配置' : '未配置'),
		E('dt', {}, '最后检查'), E('dd', {}, feed.checked_at ? new Date(feed.checked_at * 1000).toLocaleString() : '尚未检查'),
		E('dt', {}, '更新方式'), E('dd', {}, '手动确认更新')
	]));
	if (feed.error) content.push(E('p', { 'class': 'is-warning' }, errorLabel(feed.error)));
	content.push(E('details', {}, [ E('summary', {}, '运行依赖（' + (snapshot.dependencies || []).filter(function(item) { return item.available; }).length + ' / ' + (snapshot.dependencies || []).length + ' 可用）'),
		E('ul', { 'class': 'netfleet-dependencies' }, (snapshot.dependencies || []).map(function(item) { return E('li', {}, [E('strong', {}, item.label), E('span', { 'class': item.available ? '' : 'is-warning' }, item.available ? item.installed_version || '已安装' : '缺少')]); }))
	]));
	return E('section', { 'class': 'cbi-section netfleet-components' }, content);
}

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
	const errorBox = E('p', { 'class': 'is-warning', 'role': 'alert' });
	const save = button('保存订阅', function() {
		if (fields.some(function(field) { return field[4] && !values[field[0]].value.trim(); }) || !/^[A-Za-z0-9_]+$/.test(values.id.value.trim())) {
			errorBox.textContent = '请填写名称和地址；订阅标识仅限英文字母、数字和下划线。';
			return;
		}
		const source = { id: values.id.value.trim(), name: values.name.value.trim(),
			url: values.url.value.trim(), user_agent: (userAgent.getValue() || 'clash.meta').trim(), info_url: values.info_url.value.trim() };
		save.disabled = true;
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
			return E('tr', {}, [ E('td', {}, source.name || source.id), E('td', {}, source.node_count == null ? '未提供' : String(source.node_count)),
				E('td', {}, source.has_url ? '已保存' : '未配置'),
				E('td', {}, source.pending_update ? (source.using_previous_cache ? '待更新，继续使用上次可用缓存' : '待更新订阅后生效') : source.cache_current ? '已生效' : '尚未更新'),
				E('td', {}, [ button('编辑', function() { editSource(controller, state, source); }), ' ',
					button('更新', function() {
						ui.showModal('更新订阅', [ E('p', {}, '确认更新“' + (source.name || source.id) + '”？使用中的订阅发生变化时，将重载运行配置并重新选优。'),
							E('div', { 'class': 'right' }, [ button('取消', function() { showSubscriptions(controller); }), ' ', button('确认更新', function() {
								return runSubscription(controller, function() { return api.subscriptionsRefresh(source.id); });
							}) ]) ]);
					}), ' ',
					button('删除', function() {
						ui.showModal('删除订阅', [ E('p', {}, '确认删除“' + (source.name || source.id) + '”？仍被配置或运行状态引用的订阅不能删除。'),
							E('div', { 'class': 'right' }, [ button('取消', function() { showSubscriptions(controller); }), ' ', button('确认删除', function(event) {
								event.target.disabled = true;
								api.subscriptionsSet({ revision: state.revision, source: { id: source.id }, delete: true }).then(function(saved) {
									controller.subscriptionState = saved && Array.isArray(saved.sources) ? saved : null;
									controller.subscriptionsChanged = true;
									showSubscriptions(controller);
								}).catch(function(error) {
									ui.addNotification(null, E('p', {}, failure(error)), 'error'); showSubscriptions(controller);
								});
							}, false, true) ]) ]);
					}, false, true) ]) ]);
		});
		ui.showModal('管理订阅', [
			E('p', {}, '来源修改保存后，待更新订阅才生效；当前运行继续使用上次可用缓存。'),
			E('table', { 'class': 'table' }, [ E('thead', {}, E('tr', {}, [ '名称', '节点', '订阅地址', '状态', '操作' ].map(function(label) { return E('th', {}, label); }))), E('tbody', {}, rows) ]),
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
		const url = E('input', { 'class': 'cbi-input-text', 'type': 'url', 'required': true, 'autocomplete': 'off' });
		const userAgent = userAgentControl();
		const errorBox = E('p', { 'class': 'is-warning', 'role': 'alert' });
		const submit = button('确认接入', function() {
			if (!id.value.trim() || !name.value.trim() || !url.value.trim()) { errorBox.textContent = '请填写标识、名称和订阅地址。'; return; }
			submit.disabled = true;
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

return baseclass.extend({ preloadSubscriptions: loadSubscriptions, subscriptions: showSubscriptions, migration: migration, nativeSetup: nativeSetup,
	operationNode: operationNode, readOperations: readOperations, runSubscription: runSubscription, components: componentsPage, loadComponents: loadComponents });
