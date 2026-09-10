/* SPDX-License-Identifier: Apache-2.0 */
'use strict';
'require baseclass';
'require ui';
'require netfleet.api as api';

function errorLabel(code) {
	if (typeof code === 'string' && code.indexOf(':') >= 0) {
		const separator = code.indexOf(':');
		return errorLabel(code.slice(0, separator)) + '：' + code.slice(separator + 1);
	}
	if (code === 'plugin_load_failed_rolled_back') return '插件加载失败，已恢复未加载状态';
	if (typeof code === 'string' && code.endsWith('_rolled_back')) return errorLabel(code.slice(0, -12)) + '；已恢复更新前版本和运行状态';
	return ({
		plugin_data_busy: '插件数据正在读写，请稍后重试',
		plugin_system_revision_changed: '服务组合或插件版本已变化，请关闭后重新读取',
		plugin_system_dependencies_invalid: '组合依赖不完整，请先修正校验结果',
		plugin_system_recovery_required: '组合恢复尚未确认，请检查相关插件状态',
		plugin_system_apply: '组合应用失败',
		plugin_system_invalid: '服务组合格式无效',
		plugin_package_maintenance: '插件正在安装或维护',
		plugin_kernel_maintenance: '内核正在更新，请稍后重试',
		plugin_disabled: '插件未启用',
		plugin_required_by: '其他已启用插件仍依赖此插件',
		plugin_binding_conflict: '服务已绑定其他插件',
		plugin_service_unbound: '服务尚未绑定提供者',
		plugin_service_missing: '插件未提供所需服务',
		plugin_service_incompatible: '服务接口版本不兼容',
		plugin_dependency_cycle: '插件存在循环依赖',
		plugin_code_busy: '插件仍有调用正在执行',
		plugin_calls_draining: '插件仍有调用正在结束',
		plugin_package_replacing: '插件文件正在替换，请在包操作完成后重试',
		plugin_api_incompatible: '插件接口版本与当前 NetFleet 不兼容',
		plugin_backend_unsupported: '插件不适用于当前后端',
		plugin_dependency_missing: '插件运行依赖缺失',
		region_not_authorized: '此出口不再允许使用该地区，请刷新后重新选择',
		protected_probe_failed: '业务连通性验证未通过，请查看当前路径与诊断信息',
		manual_region_readback_failed: '指定地区的实际节点未能确认，切换未完成',
		plugin_not_loaded: '请先加载插件',
		plugin_manifest_invalid: '插件声明无效',
		plugin_files_unsafe: '插件文件权限或入口无效',
		plugin_confirmation_or_revision_required: '插件版本已变化，请重新读取后确认',
		plugin_load_failed: '插件加载失败',
		plugin_unload_unconfirmed: '插件退出尚未确认，请检查插件状态',
		plugin_rollback_unconfirmed: '插件恢复尚未确认，请检查插件状态',
		plugin_timeout: '插件响应超时',
		plugin_response_invalid: '插件返回内容无效',
		plugin_action_failed: '插件操作失败',
		extension_component_not_installed: '未安装可选模块',
		extension_api_incompatible: '模块接口与当前 NetFleet 不兼容',
		extension_dependency_missing: '模块运行依赖缺失',
		extension_manifest_missing: '模块接口声明缺失',
		extension_manifest_invalid: '模块接口声明无效',
		extension_backend_unsupported: '当前后端不支持此模块',
		extension_owner_unavailable: '模块状态暂不可读取',
		extension_package_unknown: '模块安装版本尚未确认',
		dashboard_managed_externally: '面板由 Nikki 管理',
		dashboard_path_unmanaged: '当前面板目录未由 NetFleet 管理',
		dashboard_unpacker_unavailable: '缺少面板解压组件，请安装 unzip',
		dashboard_state_unavailable: '无法读取或保存面板更新记录',
		dashboard_release_check_failed: '无法检查面板发行源，请检查设备联网后重试',
		dashboard_candidate_changed: '面板候选版本已变化，请重新检查更新',
		dashboard_stage_unavailable: '无法准备面板更新目录，未开始替换',
		dashboard_download_failed: '面板下载失败，当前资源未替换',
		dashboard_asset_mismatch: '面板下载内容未通过校验，当前资源未替换',
		dashboard_archive_invalid: '面板压缩包无效，当前资源未替换',
		dashboard_insufficient_space: '面板更新空间不足，当前资源未替换',
		dashboard_unpack_failed: '面板解压失败，当前资源未替换',
		dashboard_replace_failed: '面板资源替换失败',
		dashboard_readback_failed: '更新后的面板访问检查失败',
		dashboard_recovery_failed: '面板资源恢复未确认，请检查当前面板',
		dashboard_update_failed: '面板更新未完成，请重新读取状态',
		subscription_revision_changed: '订阅已被其他操作修改，请重新读取后保存',
		invalid_subscription_id: '订阅标识只能包含英文字母、数字和下划线',
		invalid_subscription_url: '订阅地址必须是有效的 HTTP 或 HTTPS 地址',
		invalid_quota_reset_day: '流量重置日必须为每月 1 至 31 日，或留空',
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
	measuring: '共享测速', applying: '应用出口', installing: '安装组件', verifying: '确认运行状态', rolling_back: '恢复更新前状态', done: '已完成'
};

function isRunning(operation) { return operation && ['queued', 'running'].includes(operation.state); }

function resultTime(value, label) {
	return value > 0 ? (label || '完成于') + ' ' + new Date(value * 1000).toLocaleString() : '';
}

function dismissedResult(controller, kind, identity, dismiss) {
	const key = 'netfleet:result:v1:' + kind;
	const records = controller.dismissedResults || (controller.dismissedResults = {});
	if (!Object.prototype.hasOwnProperty.call(records, key)) {
		try { records[key] = sessionStorage.getItem(key); } catch (_) { records[key] = null; }
	}
	if (dismiss) {
		records[key] = identity;
		try { sessionStorage.setItem(key, identity); } catch (_) { /* Display preferences remain usable without storage. */ }
	}
	return records[key] === identity;
}

function resultNode(controller, kind, identity, title, details, warning, attrs) {
	attrs = Object.assign({ 'class': 'netfleet-operation is-result' + (warning ? ' is-warning' : ''), 'role': 'status' }, attrs);
	if (dismissedResult(controller, kind, identity)) return E('div', Object.assign(attrs, { 'hidden': true }));
	const close = E('button', { 'type': 'button', 'class': 'netfleet-result-close', 'title': '关闭此条结果', 'aria-label': '关闭' + title + '结果', 'click': function() {
		if (typeof close.closest === 'function' && close.closest('#modal_overlay')) ui.hideModal();
		dismissedResult(controller, kind, identity, true);
		updateOperationNodes(controller);
		controller.redraw();
	} }, '×');
	return E('div', attrs, [ E('div', { 'class': 'netfleet-result-body' }, [ E('strong', {}, title), E('div', { 'class': 'netfleet-operation-detail' }, details) ]), close ]);
}

function notify(title, content, severity) {
	return ui.addNotification(title, E('div', {}, [content, E('small', { 'class': 'netfleet-notification-time' }, resultTime(Date.now() / 1000, '收到反馈'))]), severity);
}

function operationNode(controller, kind) {
	const operation = controller.operations && controller.operations[kind];
	const subscription = controller.operations?.subscription;
	const selection = controller.operations?.selection;
	const related = subscription && selection?.parent_id === subscription.id;
	const pending = kind === 'subscription' && controller.subscriptionRequest || kind === 'selection' && controller.selectionRequest;
	const disconnected = controller.operationError && (pending || isRunning(operation));
	const attrs = { 'class': 'netfleet-operation', 'data-netfleet-operation': kind, 'role': 'status', 'aria-live': 'polite' };
	if (kind === 'selection' && related && !controller.selectionRequest) return E('div', Object.assign(attrs, { 'hidden': true }));
	if (!operation && !pending) return E('div', Object.assign(attrs, { 'hidden': true }));
	const active = operation ? isRunning(operation) : pending;
	const state = disconnected ? '连接中断，执行结果尚未确认' : !operation ? '等待设备接收' :
		({ queued: '已提交，等待设备执行', running: kind === 'selection' ? ({ preparing: '准备测速', checking: '检查节点健康', selecting: '测速与选优', verifying: '验证业务连通性' })[operation.phase] || PHASE_LABELS[operation.phase] || '处理中' : PHASE_LABELS[operation.phase] || '处理中', succeeded: '已完成', failed: '执行失败', interrupted: '执行已中断，结果尚未确认' })[operation.state] || '等待设备确认';
	const started = operation && operation.started_at || (kind === 'selection' ? controller.selectionStartedAt : controller.subscriptionStartedAt);
	const end = active ? Date.now() / 1000 : operation && operation.finished_at;
	const elapsed = started && end >= started ? Math.floor(end - started) : null;
	const details = [ E('strong', { 'class': active && !disconnected ? 'spinning' : '' }, state) ];
	if (operation && operation.subject) {
		const capability = kind === 'selection' && controller.status && (controller.status.capabilities || []).find(function(item) { return item.id === operation.subject; });
		details.push(E('span', {}, kind === 'packages' ? ({ feed: '更新源', netfleet: 'NetFleet', mihomo: 'Mihomo' })[operation.subject] || String(operation.subject) : capability && capability.display_name || String(operation.subject)));
	}
	if (operation && Number(operation.total) > 0) {
		const label = kind === 'subscription' ? '已处理 ' : kind === 'selection' ? '已完成 ' : '已完成 ';
		const unit = kind === 'subscription' ? ' 个机场' : kind === 'selection' ? ' 个出口' : ' 个文件';
		details.push(E('span', {}, label + Number(operation.completed || 0) + ' / ' + Number(operation.total) + unit));
	}
	if (kind === 'subscription' && related && operation.phase === 'selecting') {
		details.push(E('span', {}, ({ preparing: '准备测速', checking: '检查节点健康', selecting: '测量候选并选优', verifying: '验证业务连通性' })[selection.phase] || PHASE_LABELS[selection.phase] || '测速与选优'));
		if (selection.total > 0) details.push(E('span', {}, '已完成 ' + Number(selection.completed || 0) + ' / ' + Number(selection.total) + ' 个出口'));
		if (selection.error) details.push(E('span', { 'class': 'is-warning' }, errorLabel(selection.error)));
	}
	if (!active) details.push(E('span', {}, operation.finished_at ? resultTime(operation.finished_at) : operation.updated_at ? resultTime(operation.updated_at, '记录更新于') + '（完成时间未记录）' : '完成时间未记录'));
	if (elapsed != null) details.push(E('span', {}, (active ? '已耗时 ' : '耗时 ') + (elapsed < 60 ? elapsed + ' 秒' : Math.floor(elapsed / 60) + ' 分 ' + elapsed % 60 + ' 秒')));
	if (operation && operation.error) details.push(E('span', { 'class': 'is-warning' }, errorLabel(operation.error)));
	if (operation && operation.recovery) details.push(E('span', {}, ({ restored: '已恢复更新前状态', failed: '恢复失败', direct: '已恢复网络直通' })[operation.recovery] || '恢复结果尚未确认'));
	const title = kind === 'subscription' ? '机场订阅更新' : kind === 'selection' ? '测速与自动选优' : operation && operation.subject === 'feed' ? '软件包源检查' : '组件更新';
	if (!active) return resultNode(controller, kind, JSON.stringify([operation.id, operation.started_at, operation.state, operation.finished_at, operation.recovery]), title, details,
		['failed', 'interrupted'].includes(operation.state), { 'data-netfleet-operation': kind });
	return E('div', Object.assign(attrs, { 'class': attrs.class + (disconnected || operation && ['failed', 'interrupted'].includes(operation.state) ? ' is-warning' : '') }), [
		E('div', { 'class': 'netfleet-operation-title' }, title),
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
	if (controller.context && controller.context.signal.aborted) return Promise.resolve();
	if (controller.operationRead) return controller.operationRead;
	clearTimeout(controller.operationTimer);
	controller.operationRead = api.operationGet().then(function(snapshot) {
		const previous = controller.operations && controller.operations.packages;
		if (controller.subscriptionRequest && snapshot.subscription && snapshot.subscription.id === controller.previousSubscriptionId) snapshot.subscription = null;
		if (controller.selectionRequest && snapshot.selection && snapshot.selection.id === controller.previousSelectionId) snapshot.selection = null;
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
		const running = controller.subscriptionRequest || controller.selectionRequest || isRunning(snapshot.subscription) || isRunning(snapshot.selection) || isRunning(snapshot.packages);
		if (running && !(controller.context && controller.context.signal.aborted))
			controller.operationTimer = setTimeout(function() { if (!controller.root || controller.root.isConnected !== false) readOperations(controller); }, 1000);
	});
	return controller.operationRead;
}

function runSelection(controller, request, title) {
	title = title || '测速与自动选优';
	controller.busy = true;
	controller.selectionRequest = true;
	controller.selectionStartedAt = Math.floor(Date.now() / 1000);
	controller.previousSelectionId = controller.operations && controller.operations.selection && controller.operations.selection.id;
	controller.operations = Object.assign({}, controller.operations, { selection: null });
	ui.showModal(title, [ E('div', { 'class': 'netfleet-native' }, [ operationNode(controller, 'selection'),
		E('div', { 'class': 'right' }, button('收起进度', ui.hideModal)) ]) ]);
	controller.redraw();
	readOperations(controller);
	return Promise.resolve().then(request).then(function(result) {
		return completedRead(controller, result, title, function() { return controller.refreshData(true); });
	}).catch(function(error) {
		const uncertain = error && (error.netfleetKind === 'request_aborted' || /timeout|XHR|network/i.test(error.message || ''));
		notify(null, E('p', {}, uncertain ? '连接中断，设备可能仍在测速；结果尚未确认。' : failure(error)), uncertain ? 'warning' : 'error');
		return controller.refreshData(true).catch(function() {});
	}).finally(function() {
		controller.selectionRequest = false;
		controller.busy = false;
		readOperations(controller).then(function() { controller.redraw(); });
	});
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
		return completedRead(controller, result, '订阅更新', function() { return controller.onboarding ? controller.refreshOnboarding() : controller.refreshData(true, true); });
	}).catch(function(error) {
		const uncertain = error && (error.netfleetKind === 'request_aborted' || /timeout|XHR|network/i.test(error.message || ''));
		notify(null, E('p', {}, uncertain ? '连接中断，设备可能仍在更新；结果尚未确认。' : failure(error)), uncertain ? 'warning' : 'error');
	}).finally(function() {
		controller.subscriptionRequest = false;
		controller.busy = false;
		readOperations(controller).then(function() { controller.redraw(); });
	});
}

function completedRead(controller, result, title, read) {
	function unconfirmed() { notify(null, E('p', {}, title + '已返回执行结果；状态读取失败，请重新读取并查看操作记录，不要重复执行。'), 'warning'); }
	return Promise.resolve().then(read).then(function() {
		if (controller.refreshError) unconfirmed();
		return result;
	}, function() { unconfirmed(); return result; });
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

function compositionDialog(controller) {
	const output = E('p', { 'role': 'status' }, '正在读取服务组合…');
	const editor = E('textarea', { 'rows': 16, 'aria-label': '服务组合配置', 'style': 'width:100%;box-sizing:border-box;font-family:monospace' }, '');
	let revision, preview = null, busy = false, closed = false, applied = false, snapshot;
	const form = E('div', {}), instance = E('select', { 'aria-label': '组合实例' }, []);
	function draft() { return JSON.parse(editor.value); }
	function edit(change) {
		if (busy || applied) return;
		try {
			const value = draft(); change(value); editor.value = JSON.stringify(value, null, 2);
			preview = null; apply.disabled = true; renderForm();
		} catch (error) { output.textContent = '请先修正高级 JSON：' + String(error.message || error); }
	}
	function renderForm() {
		if (!snapshot || closed) return;
		let config;
		try { config = draft(); } catch (error) { form.textContent = '高级 JSON 无效，修正后可继续使用表单。'; return; }
		const names = ['default', ...Object.keys(config.instances || {})];
		const name = names.includes(instance.value) ? instance.value : 'default', defaults = snapshot.defaults || {};
		instance.replaceChildren(...names.map(value => E('option', { value }, value === 'default' ? '默认实例' : value)));
		instance.value = name; instance.disabled = busy || applied;

		const local = name === 'default' ? config : config.instances?.[name] || {};
		const inherited = name === 'default' ? defaults : { enabled: { ...defaults.enabled, ...config.enabled }, bindings: { ...defaults.bindings, ...config.bindings } };
		function update(field, key, value) {
			edit(config => {
				const target = name === 'default' ? config : (config.instances ||= {})[name] ||= {};
				if (value === '') { if (target[field]) delete target[field][key]; }
				else (target[field] ||= {})[key] = value;
			});
		}
		const rows = [];
		for (const plugin of snapshot.plugins || []) {
			const selected = local.enabled?.[plugin.id];
			const enable = E('select', { 'aria-label': '插件开关 ' + plugin.id, disabled: busy || applied ? '' : null, change: event => update('enabled', plugin.id, event.target.value === '' ? '' : event.target.value === 'true') },
				[E('option', { value: '' }, '继承（' + (inherited.enabled?.[plugin.id] ? '启用' : '停用') + '）'), E('option', { value: 'true' }, '启用'), E('option', { value: 'false' }, '停用')]);
			enable.value = selected == null ? '' : String(selected);
			rows.push(E('div', {}, [E('label', {}, [plugin.id + ' ', enable])]));
		}
		const services = new Map();
		for (const plugin of snapshot.plugins || []) for (const service of plugin.services || []) {
			if (!services.has(service.name)) services.set(service.name, []);
			services.get(service.name).push({ plugin: plugin.id, ...service });
		}
		for (const [service, providers] of services) {
			const select = E('select', { 'aria-label': '服务提供者 ' + service, disabled: busy || applied ? '' : null, change: event => update('bindings', service, event.target.value) },
				[E('option', { value: '' }, '继承（' + (inherited.bindings?.[service] || '未绑定') + '）'), ...providers.map(provider => E('option', { value: provider.plugin }, provider.plugin + ' · v' + provider.version))]);
			const selected = local.bindings?.[service];
			if (selected && !providers.some(provider => provider.plugin === selected)) select.replaceChildren(E('option', { value: '' }, '继承（' + (inherited.bindings?.[service] || '未绑定') + '）'), ...providers.map(provider => E('option', { value: provider.plugin }, provider.plugin + ' · v' + provider.version)), E('option', { value: selected }, selected + '（当前不可用）'));
			select.value = selected || '';
			rows.push(E('div', {}, [E('label', {}, [service + ' ', select])]));
		}
		form.replaceChildren(...rows);
	}
	instance.addEventListener?.('change', renderForm);
	const apply = button('应用组合', async function() {
		if (busy || !preview || preview.text !== editor.value) return;
		busy = true; editor.disabled = true; renderForm(); apply.disabled = true; validate.disabled = true;
		try {
			await api.systemApply({ revision, config: preview.config, confirm: true });
			if (!closed) { output.textContent = '组合已应用，插件页面会自动更新。'; applied = true; }
			await loadComponents(controller);
		} catch (error) { if (!closed) output.textContent = errorLabel(error.message || String(error)); }
		finally { busy = false; preview = null; if (!closed) { editor.disabled = applied; validate.disabled = applied; renderForm(); } }
	}, true);
	const validate = button('校验并预览影响', async function() {
		if (busy || !revision) return;
		busy = true; editor.disabled = true; renderForm(); apply.disabled = true; validate.disabled = true; preview = null;
		try {
			const config = JSON.parse(editor.value), text = editor.value;
			const result = await api.systemValidate({ revision, config });
			if (closed || editor.value !== text) return;
			if (result.valid) {
				preview = { config, text };
				output.textContent = '校验通过。受影响插件：' + (result.affected_plugins.join('、') || '无') + '。点击“应用组合”确认保存并交接相关资源。';
				apply.disabled = false;
			} else output.textContent = result.errors.map(item => [item.instance, item.service, item.error].filter(Boolean).join(' · ')).join('\n');
		} catch (error) { if (!closed) output.textContent = errorLabel(error.message || String(error)); }
		finally { busy = false; if (!closed) { editor.disabled = applied; validate.disabled = applied; renderForm(); } }
	}, true);
	editor.addEventListener?.('input', function() { preview = null; apply.disabled = true; renderForm(); });
	const close = button('关闭', function() { closed = true; editor.value = ''; ui.hideModal(); });
	ui.showModal('服务组合与实例', [E('p', {}, '维护服务提供者、插件开关与实例配置。先校验依赖和影响，再应用。'), instance, form, E('details', {}, [E('summary', {}, '高级 JSON（实例配置与完整覆盖）'), editor]), output,
		E('div', { 'class': 'right' }, [validate, ' ', apply, ' ', close])]);
	return api.systemGet().then(function(result) {
		if (closed) return;
		snapshot = result; revision = result.revision; editor.value = JSON.stringify(result.config, null, 2);
		instance.replaceChildren(...['default', ...Object.keys(result.config.instances || {})].map(name => E('option', { value: name }, name === 'default' ? '默认实例' : name)));
		instance.value = 'default'; renderForm(); validate.disabled = false; output.textContent = '已读取当前私有组合配置。';
	}).catch(function(error) { if (!closed) output.textContent = errorLabel(error.message || String(error)); });
}

function pluginDialog(controller, plugin) {
	const output = E('pre', { 'style': 'max-height:18rem;overflow:auto;white-space:pre-wrap;overflow-wrap:anywhere' }, '');
	const status = E('p', {}, '正在读取');
	const actions = Object.keys(plugin.actions || {});
	const selector = E('select', { 'class': 'cbi-input-select' }, actions.map(function(action) { return E('option', { 'value': action }, action); }));
	const params = E('textarea', { 'class': 'cbi-input-textarea', 'rows': 4, 'aria-label': '插件参数 JSON', 'style': 'width:100%;box-sizing:border-box' }, '{}');
	let revision = plugin.revision;
	let pending = false;
	const controls = [];
	function busy(value) { pending = value; controls.forEach(function(control) { control.disabled = value; }); }
	function show(result) {
		revision = result.revision || revision;
		status.textContent = result.loaded === true ? (result.ready === true ? '已加载，就绪' : '已加载，未就绪') : result.loaded === false ? '未加载' : '操作完成';
		output.textContent = JSON.stringify(result, null, 2);
	}
	function run(action) {
		if (pending) return;
		let values = {};
		try {
			if (actions.indexOf(action) >= 0) values = JSON.parse(params.value);
			if (!values || typeof values !== 'object' || Array.isArray(values)) throw new Error('参数必须是 JSON 对象');
		} catch (error) { status.textContent = error.message; return; }
			const definition = (plugin.actions || {})[action];
			const access = typeof definition === 'string' ? definition : definition && definition.access;
			const writing = ['load', 'reload', 'unload'].indexOf(action) >= 0 || access === 'write';
		const execute = function() {
			busy(true);
				const request = { id: plugin.id, action: action, revision: revision, confirm: writing, params: values };
				if (plugin.instance) request.instance = plugin.instance;
			return (writing ? api.pluginCall(request) : api.pluginRead(request)).then(show).catch(function(error) {
				status.textContent = errorLabel(error.message || String(error));
			}).finally(function() { busy(false); if (writing) loadComponents(controller); });
		};
		if (!writing) return execute();
		ui.showModal('确认插件操作', [ E('p', {}, plugin.label + ' · ' + action),
			E('div', { 'class': 'right' }, [ button('取消', function() { pluginDialog(controller, plugin); }), ' ',
				button('确认', function() { open(); execute(); }) ]) ]);
	}

	controls.push(button('加载', function() { run('load'); }), button('重新加载', function() { run('reload'); }),
		button('退出', function() { run('unload'); }), button('↻', function() { run('get'); }));
	controls[3].setAttribute('title', '刷新状态');
	const configPages = (plugin.ui || []).map(function(page) { return button('配置 · ' + page.title, function() {
		ui.hideModal(); controller.context.navigate('plugin:' + plugin.id + ':' + (plugin.instance && plugin.instance !== 'default' ? plugin.instance + ':' : '') + page.id);
	}, plugin.enabled === false); });
	const children = [E('p', {}, '版本 ' + (plugin.installed_version || plugin.version || '未记录') + (plugin.instance ? ' · 实例 ' + plugin.instance : '')), status,
		E('div', { 'class': 'cbi-page-actions' }, configPages), E('div', { 'class': 'cbi-page-actions' }, controls),
		E('a', { 'href': L.url('admin/system/packages'), 'target': '_blank', 'rel': 'noopener' }, '安装、更新与卸载软件包 ↗'),
		E('details', {}, [E('summary', {}, '技术状态'), output])];
	if (actions.length) {
		const execute = button('执行', function() { run(selector.value); });
		controls.push(execute);
		children.push(E('label', {}, '插件动作'), selector, E('label', {}, '参数（JSON）'), params, execute);
	}
	children.push(E('div', { 'class': 'right' }, button('关闭', ui.hideModal)));
	function open() { ui.showModal(plugin.label, children); }
	open(); run('get');
}

function startPackageOperation(controller, component) {
	if (componentsLocked(controller)) return Promise.resolve();
	controller.componentsError = null;
	controller.componentsStarting = true;
	controller.packageTarget = component ? { component: component.id, version: component.available_version } : null;
	controller.redraw();
	const request = component ? api.componentsUpdate(component.id, component.available_version) : api.componentsCheck();
	return request.then(function(result) {
		controller.packageOperationId = result.operation.id;
		controller.operations = Object.assign({}, controller.operations, { packages: result.operation });
		return readOperations(controller).then(function() { if (!isRunning(result.operation)) return loadComponents(controller); });
	}).catch(function(error) { controller.componentsError = error; }).finally(function() { controller.componentsStarting = false; controller.redraw(); });
}

function componentsLocked(controller) {
	return controller.busy || !controller.liveDataReady || controller.context?.readOnly || controller.componentsStarting || controller.componentsChecking ||
		controller.dashboardBusy || isRunning(controller.operations && controller.operations.packages);
}

function dashboardFailure(controller, error) {
	controller.dashboardError = error;
	controller.dashboardResultAt = Date.now() / 1000;
	if (error.detail && error.detail.id === 'zashboard') controller.components.dashboard = error.detail;
}

function checkUpdates(controller) {
	if (componentsLocked(controller) || !controller.components) return Promise.resolve();
	const snapshot = controller.components;
	controller.componentsChecking = true;
	controller.dashboardAction = 'check';
	controller.dashboardError = null;
	controller.redraw();
	// The two sources share the device mutation lock, so finish the bounded resource check first.
	const dashboard = snapshot.dashboard && snapshot.dashboard.managed ? api.dashboardCheck().then(function(result) {
		controller.components.dashboard = result;
		controller.dashboardResultAt = Date.now() / 1000;
	}).catch(function(error) { dashboardFailure(controller, error); }) : Promise.resolve();
	return dashboard.then(function() {
		controller.componentsChecking = false;
		if (snapshot.supported && snapshot.feed && snapshot.feed.configured) return startPackageOperation(controller);
	}).finally(function() { controller.componentsChecking = false; controller.redraw(); });
}

function updateDashboard(controller, version) {
	if (componentsLocked(controller)) return Promise.resolve();
	controller.dashboardBusy = true;
	controller.dashboardAction = 'update';
	controller.dashboardError = null;
	controller.redraw();
	return api.dashboardUpdate(version).then(function(result) {
		controller.components.dashboard = result;
		controller.dashboardResultAt = Date.now() / 1000;
	}).catch(function(error) { dashboardFailure(controller, error); }).finally(function() { controller.dashboardBusy = false; controller.redraw(); });
}

function coreVersion(value) { return String(value || '').replace(/^v/, '').replace(/-r\d+$/, ''); }
function componentMismatch(component) {
	return component.id === 'mihomo' && component.installed_version && component.running_version &&
		coreVersion(component.installed_version) !== coreVersion(component.running_version);
}

function componentsPage(controller) {
	const snapshot = controller.components;
	const active = componentsLocked(controller);
	const feed = snapshot && snapshot.feed || {};
	const dashboard = snapshot && snapshot.dashboard;
	const refresh = button('↻', function() { return Promise.all([loadComponents(controller), readOperations(controller), controller.refreshData(true)]); },
		controller.componentsLoading || controller.refreshing || controller.busy || controller.componentsStarting || controller.componentsChecking || controller.dashboardBusy || isRunning(controller.operations && controller.operations.packages));
	refresh.setAttribute('title', '刷新设备组件状态');
	refresh.setAttribute('aria-label', '刷新设备组件状态');
	const check = button(controller.componentsChecking ? '正在检查更新…' : '检查更新', function() { return checkUpdates(controller); },
		active || !snapshot || !(snapshot.supported && feed.configured || dashboard && dashboard.managed));
	if (!controller.liveDataReady) check.setAttribute('title', '等待设备实时状态恢复');
	else if (active) check.setAttribute('title', '设备正在执行操作');
	const content = [ E('div', { 'class': 'netfleet-section-heading' }, [ E('h3', {}, controller.componentsSection === 'software' ? '基础组件' : '功能插件'), E('div', { 'class': 'netfleet-inline-actions' }, [
		refresh, check, controller.componentsSection !== 'software' ? button('服务组合', function() { return compositionDialog(controller); }, active || controller.context?.readOnly === true) : ''
	]) ]), operationNode(controller, 'packages') ];
	content.unshift(E('nav', { 'class': 'netfleet-subtabs', 'aria-label': '插件与更新分类' }, [['plugins', '功能插件'], ['software', '基础组件']].map(function(item) {
		return E('button', { 'type': 'button', 'aria-current': (controller.componentsSection || 'plugins') === item[0] ? 'page' : null, 'click': function() { controller.componentsSection = item[0]; controller.redraw(); } }, item[1]);
	})));
	if (controller.componentsError) content.push(E('p', { 'class': 'is-warning', 'role': 'alert' }, '组件信息未能确认：' + errorLabel(controller.componentsError.message)));
	if (!snapshot) {
		if (!controller.componentsError) content.push(E('p', { 'class': 'spinning', 'role': 'status' }, '正在读取已安装组件…'));
		return E('section', { 'class': 'cbi-section netfleet-components' }, content);
	}
	const packageOperation = controller.operations && controller.operations.packages;
	if (packageOperation?.recovery === 'required') content.push(button('恢复中断更新', async function() {
		if (componentsLocked(controller)) return;
		controller.componentsStarting = true; controller.redraw();
		try { await api.componentsRecover(); await readOperations(controller); await loadComponents(controller); }
		catch (error) { controller.componentsError = error; }
		finally { controller.componentsStarting = false; controller.redraw(); }
	}, active));
	const packageFailed = packageOperation && ['failed', 'interrupted'].includes(packageOperation.state);
	const sameFeedFailure = packageFailed && packageOperation.error === feed.error && (!feed.checked_at || feed.checked_at >= packageOperation.started_at && feed.checked_at <= packageOperation.finished_at);
	if (feed.error && !sameFeedFailure && !isRunning(packageOperation)) content.push(resultNode(controller, 'feed', String(feed.checked_at || 0), '软件包源检查', [
		E('span', {}, errorLabel(feed.error)), E('span', {}, resultTime(feed.checked_at, '检查于') || '检查时间未记录')
	], true));
	const dashboardError = controller.dashboardError || dashboard && dashboard.error;
	if (dashboard && dashboard.managed && !controller.dashboardBusy && !controller.componentsChecking && (dashboardError || controller.dashboardResultAt)) {
		const recordedCheck = controller.dashboardAction !== 'update' && dashboard.checked_at && (!controller.dashboardError || dashboard.error);
		const time = recordedCheck ? dashboard.checked_at : controller.dashboardResultAt;
		content.push(resultNode(controller, 'dashboard', JSON.stringify([time, controller.dashboardAction || 'check', Boolean(dashboardError)]),
			controller.dashboardAction === 'update' ? '面板更新' : '面板检查', [
				E('span', {}, dashboardError ? (controller.dashboardError ? failure(controller.dashboardError) : errorLabel(dashboard.error)) : '已完成'),
				E('span', {}, resultTime(time, recordedCheck ? '检查于' : '收到结果') || '检查时间未记录')
			], Boolean(dashboardError)));
	}
	const sourceStates = [ E('span', {}, !snapshot.supported ? '软件包：当前安装方式不支持包管理' :
		!feed.configured ? '软件包：未配置更新源' : '软件包：' + (feed.error ? '上次检查失败 · ' : '') + (resultTime(feed.checked_at, '检查于') || (feed.error ? '检查时间未记录' : '尚未检查更新'))) ];
	if (dashboard) sourceStates.push(E('span', {}, !dashboard.managed ? errorLabel(dashboard.reason || 'dashboard_managed_externally') :
		'面板：' + (controller.componentsChecking ? '正在检查更新…' : controller.dashboardBusy ? '正在更新资源…' :
		(dashboardError ? '上次' + (controller.dashboardAction === 'update' ? '更新' : '检查') + '失败 · ' : '') + (resultTime(controller.dashboardResultAt || dashboard.checked_at, '最近结果') || (dashboardError ? '检查时间未记录' : '尚未检查更新')))));
	if (controller.componentsSection === 'software') content.push(E('div', { 'class': 'netfleet-component-checks', 'role': 'status' }, sourceStates));
	const luci = snapshot.components.find(function(item) { return item.id === 'luci'; });
	const rows = snapshot.components.filter(function(item) { return item.id !== 'luci'; }).map(function(component) {
		const mismatch = componentMismatch(component);
		const hasUpdate = component.update_available || component.id === 'netfleet' && luci && luci.update_available;
		const uiOnly = component.id === 'netfleet' && !component.update_available && luci && luci.update_available;
		const canUpdate = snapshot.supported && feed.configured && !feed.error && component.managed && hasUpdate && component.available_version;
		const targetVersion = component.available_version + (component.id === 'netfleet' && luci && luci.available_version ? '；LuCI 界面 ' + luci.available_version : '');
		const update = canUpdate ? button(mismatch ? '更新软件包' : '更新', function() {
			ui.showModal('更新 ' + component.label, [ E('p', {}, (component.id === 'mihomo' ? '核心更新会中断已有代理连接，设备将校验当前配置并检查重启后的运行状态。' : '将更新 NetFleet 与 LuCI 界面；基础包更新会停止并恢复运行服务，已有连接可能中断。完成后重新载入页面，私有配置保留。') + '目标版本：' + targetVersion),
				mismatch ? E('p', { 'class': 'is-warning' }, '当前运行 ' + component.running_version + '，安装记录 ' + component.installed_version + '。本次将安装所列候选软件包，请核对版本。') : '',
				E('div', { 'class': 'right' }, [ button('取消', ui.hideModal), ' ', button('确认更新', function() { ui.hideModal(); return startPackageOperation(controller, component); }) ]) ]);
		}, active) : '';
		const current = [ E('strong', {}, component.id === 'mihomo' ? component.running_version || '核心运行版本暂不可读取' : component.installed_version || '未安装') ];
		if (component.id === 'mihomo' && component.installed_version) current.push(E('small', {}, '安装记录 ' + component.installed_version));
		if (mismatch) current.push(E('span', { 'class': 'is-warning' }, '运行版本与安装记录不一致'));
		if (component.reason) current.push(E('small', {}, errorLabel(component.reason)));
		const available = component.available_version && !feed.error ? [ uiOnly ? '界面可更新至 ' + luci.available_version : hasUpdate ? '候选版本 ' + component.available_version : '当前更新源暂无新版' ] : [];
		if (hasUpdate && !feed.error) available.push(E('small', {}, component.id === 'mihomo' ? '更新核心会中断已有代理连接' : '基础包更新会停止并恢复服务，私有配置保留'));
		return E('tr', {}, [ E('td', {}, [ E('strong', {}, component.label), E('small', {}, component.id === 'netfleet' ? '网络增强服务' : '代理核心') ]),
			E('td', {}, current), E('td', { 'class': 'netfleet-component-actions' }, [ E('div', {}, available), update ]) ]);
	});
	if (luci) rows.splice(1, 0, E('tr', {}, [ E('td', {}, [ E('strong', {}, 'LuCI 界面'), E('small', {}, 'NetFleet 管理界面') ]),
		E('td', {}, E('strong', {}, luci.installed_version || '未安装')),
		E('td', {}, [ luci.available_version && !feed.error ? (luci.update_available ? '候选版本 ' + luci.available_version : '当前更新源暂无新版') : '',
			E('small', {}, '由 NetFleet 更新入口管理') ]) ]));
	const moduleRows = [];
	(snapshot.extensions || []).filter(function(extension) { return extension.kind === 'plugin'; }).forEach(function(plugin) {
		const controls = [];
		if (plugin.ui?.length) controls.push(button('配置', function() {
			controller.context.navigate('plugin:' + plugin.id + ':' + (plugin.instance && plugin.instance !== 'default' ? plugin.instance + ':' : '') + plugin.ui[0].id);
		}, active || plugin.enabled === false));
		if (plugin.revision) controls.push(button('运行与管理', function() { pluginDialog(controller, plugin); }, active));
		moduleRows.push(E('tr', {}, [ E('td', {}, [ E('strong', { 'title': plugin.package || '' }, plugin.label), E('small', {}, plugin.runtime === 'service' ? '功能插件' : '进程插件') ]),
			E('td', {}, E('strong', {}, plugin.installed_version || plugin.version || '未知版本')),
			E('td', {}, plugin.reason ? errorLabel(plugin.reason) : plugin.enabled === true ? '已启用' : '可按需加载'), E('td', { 'class': 'netfleet-component-actions' },
				controls) ]));
	});
	(snapshot.extensions || []).filter(function(extension) { return extension.kind === 'optional'; }).forEach(function(extension) {
		const state = ({ ready: '可配置', not_installed: '未安装', incompatible: '模块版本不兼容', backend_unsupported: '当前后端不支持', dependency_missing: '缺少依赖', unknown: '状态未确认' })[extension.state];
		const absent = extension.state === 'not_installed' && !extension.available;
		const dependencies = extension.dependencies || [];
		const missing = dependencies.filter(function(dependency) { return dependency.available === false; });
		const warning = extension.state !== 'ready' && extension.state !== 'not_installed';
		const current = [];
		if (extension.state !== 'not_installed') current.push(E('small', { 'class': warning ? 'is-warning' : '' }, state));
		if (extension.reason) current.push(E('small', {}, errorLabel(extension.reason)));
		if (!absent && dependencies.length) current.push(E('details', { 'open': missing.length ? true : null }, [
			E('summary', { 'class': missing.length ? 'is-warning' : '' }, missing.length ? '缺少 ' + missing.length + ' 项模块依赖' : '运行依赖（' + dependencies.length + '）'),
			E('small', { 'style': 'overflow-wrap:anywhere' }, extension.package)
		].concat(dependencies.map(function(dependency) { return E('small', { 'class': dependency.available === false ? 'is-warning' : '' },
				dependency.id + '：' + (dependency.available == null ? '未确认' : dependency.available ? dependency.installed_version || '已安装' : '缺少')); })
		)));
		moduleRows.push(E('tr', {}, [ E('td', {}, [ E('strong', {}, extension.label), E('small', { 'title': extension.package }, '可选模块') ]),
			E('td', {}, E('strong', {}, extension.installed_version || (absent ? '未安装' : '安装版本未确认'))), E('td', {}, current), E('td', { 'class': 'netfleet-component-actions' }, '') ]));
	});
	if (dashboard) {
		const controls = [];
		if (dashboard.available && controller.dashboardUrl) controls.push(E('a', { 'class': 'netfleet-dashboard-link', 'href': controller.dashboardUrl, 'target': '_blank', 'rel': 'noopener' }, '打开面板 ↗'));
		if (dashboard.managed && dashboard.update_available && dashboard.available_version && !dashboard.error && !controller.dashboardError) controls.push(button(dashboard.available ? '更新面板' : '安装面板', function() {
			const version = dashboard.available_version;
			ui.showModal('更新 Zashboard', [ E('p', {}, '目标版本：' + version + '。只更新面板资源，不重启核心；失败时保留当前面板。'),
				E('div', { 'class': 'right' }, [ button('取消', ui.hideModal), ' ', button('确认更新', function() { ui.hideModal(); return updateDashboard(controller, version); }) ]) ]);
		}, active));
		rows.push(E('tr', {}, [ E('td', {}, [ E('strong', {}, 'Zashboard'), E('small', {}, '实时运行面板') ]),
			E('td', {}, [ E('strong', {}, dashboard.available ? dashboard.installed_version || '版本未记录' : '未安装'),
				dashboard.available ? E('small', {}, '已安装，可使用') : '', !dashboard.managed ? E('small', {}, errorLabel(dashboard.reason || 'dashboard_managed_externally')) : '' ]),
			E('td', { 'class': 'netfleet-component-actions' }, [ E('div', {}, dashboard.available_version && !dashboard.error && !controller.dashboardError ? dashboard.update_available ? '候选版本 ' + dashboard.available_version : '当前更新源暂无新版' : '') ].concat(controls)) ]));
	}
	if (controller.componentsSection === 'software') content.push(E('div', { 'class': 'netfleet-component-table netfleet-software-table' }, E('table', { 'class': 'table' }, [
		E('thead', {}, E('tr', {}, ['软件', '当前版本', '更新与操作'].map(function(label) { return E('th', {}, label); }))), E('tbody', {}, rows)
	])));
	if (controller.componentsSection !== 'software') content.push(E('section', { 'class': 'netfleet-component-modules' }, [
		E('div', { 'class': 'netfleet-section-heading' }, [ E('a', { 'class': 'netfleet-inline-link', 'href': L.url('admin/system/packages'), 'target': '_blank', 'rel': 'noopener' }, '安装与卸载软件包 ↗') ]),
		E('div', { 'class': 'netfleet-component-table' }, E('table', { 'class': 'table' }, [
			E('thead', {}, E('tr', {}, ['插件', '安装版本', '状态', '操作'].map(function(label) { return E('th', {}, label); }))), E('tbody', {}, moduleRows.length ? moduleRows : [E('tr', {}, E('td', { 'colspan': 4 }, '当前没有可管理的功能插件'))])
		]))
	]));
	content.push(E('details', { 'class': 'netfleet-component-details' }, [ E('summary', {}, '技术详情：更新源与安装信息'),
		feed.error ? E('p', {}, '软件包源最近错误：' + errorLabel(feed.error)) : '',
		packageFailed ? E('p', {}, '最近组件操作：' + errorLabel(packageOperation.error) + (packageOperation.recovery ? '；' + ({ restored: '已恢复更新前状态', failed: '恢复失败', direct: '已恢复网络直通' })[packageOperation.recovery] : '')) : '',
		dashboardError ? E('p', {}, '面板最近错误：' + (controller.dashboardError ? failure(controller.dashboardError) : errorLabel(dashboard.error))) : '',
		E('dl', { 'class': 'netfleet-component-meta' }, [].concat(
		snapshot.architecture ? [ E('dt', {}, '设备架构'), E('dd', {}, snapshot.architecture) ] : '',
		feed.url ? [ E('dt', {}, '软件包源'), E('dd', {}, feed.url) ] : '',
		dashboard && dashboard.release_url && dashboard.release_url.startsWith('https://github.com/') ? [ E('dt', {}, '面板发行说明'), E('dd', {}, E('a', { 'href': dashboard.release_url, 'target': '_blank', 'rel': 'noopener' }, 'Zashboard 发行说明 ↗')) ] : ''
	)) ]));
	const missing = (snapshot.dependencies || []).filter(function(item) { return !item.available; });
	if (snapshot.supported && (snapshot.dependencies || []).length) content.push(E('details', { 'open': missing.length ? true : null, 'class': 'netfleet-component-details' }, [ E('summary', { 'class': missing.length ? 'is-warning' : '' }, missing.length ? '缺少 ' + missing.length + ' 项运行依赖' : '运行依赖正常'),
		missing.length ? E('p', {}, '请通过 OpenWrt 软件包管理安装缺少的依赖。') : '',
		E('ul', { 'class': 'netfleet-dependencies' }, (snapshot.dependencies || []).map(function(item) { return E('li', {}, [E('strong', {}, item.label), E('span', { 'class': item.available ? '' : 'is-warning' }, item.available ? item.installed_version || '已安装' : '缺少')]); }))
	]));
	return E('section', { 'class': 'cbi-section netfleet-components' }, content);
}

function userAgentControl(value) {
	return new ui.Combobox(value || 'clash.meta', { 'clash': 'clash', 'clash.meta': 'clash.meta', 'mihomo': 'mihomo' }, {
		id: 'netfleet-source-user-agent', sort: false, custom_placeholder: '自定义 User-Agent'
	});
}

function quotaResetLabel(day) {
	return Number.isInteger(day) && day >= 1 && day <= 31 ? '每月 ' + day + ' 日重置' : '';
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
		const source = { id: values.id.value.trim(), name: values.name.value.trim(),
			url: values.url.value.trim(), user_agent: (userAgent.getValue() || 'clash.meta').trim(), info_url: values.info_url.value.trim(),
			quota_reset_day: resetDay.value === '' ? null : Number(resetDay.value) };
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
				E('td', { 'title': '手动设置，仅供套餐参考；实际结算以机场为准' }, quotaResetLabel(source.quota_reset_day) || '未设置'),
				E('td', {}, source.has_url ? '已保存' : '未配置'),
				E('td', {}, source.pending_update ? (source.using_previous_cache ? '待更新，继续使用上次可用缓存' : '待更新订阅后生效') : source.cache_current ? '已生效' : '尚未更新'),
				E('td', {}, [ button('编辑', function() { editSource(controller, state, source); }), ' ',
					button('更新', function() {
						ui.showModal('更新订阅', [ E('p', {}, '只更新“' + (source.name || source.id) + '”。内容未变化时不重载；使用中的内容变化后会重启核心并重新选优，已有连接可能中断。尚未使用的订阅只更新缓存。'),
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
									notify(null, E('p', {}, failure(error)), 'error'); showSubscriptions(controller);
								});
							}, false, true) ]) ]);
					}, false, true) ]) ]);
		});
		ui.showModal('管理订阅', [
			E('p', {}, '地址与 User-Agent 修改后待更新订阅生效；名称与重置日保存即生效。'),
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

return baseclass.extend({ quotaResetLabel: quotaResetLabel, notify: notify, preloadSubscriptions: loadSubscriptions, subscriptions: showSubscriptions, migration: migration, nativeSetup: nativeSetup,
	operationNode: operationNode, readOperations: readOperations, runSubscription: runSubscription, runSelection: runSelection, components: componentsPage, loadComponents: loadComponents });
