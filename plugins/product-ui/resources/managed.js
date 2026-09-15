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
  plugin_package_protected: '此软件为必需组件，可更新但不可单独安装或卸载',
  plugin_disable_before_remove: '请先禁用此插件并确认状态，再卸载软件包',
  plugin_package_required: '其他软件或服务仍依赖此插件，不能单独卸载',
  plugin_dependency_change_required: '需要先更新其他已安装组件；本次未修改软件包',
  plugin_dependencies_unavailable: '依赖无法解析，请检查软件源；当前软件包未改变',
  installed_version_changed: '安装状态已变化，请重新读取后确认',
  invalid_plugin_package_request: '插件安装请求无效，请重新读取后操作',
  package_plan_unreadable: '无法确认软件包变更计划，未开始安装',
		update_cancelled: '已取消更新，尚未替换软件包',
		update_deferred: '现有连接尚未结束，已延后更新并保留旧版；空闲时可重新更新',
		update_prepare_failed: '无法安全准备更新，尚未替换软件包',
		update_resume_failed: '软件包已替换，但相关功能恢复未确认',
		update_cancel_unavailable: '已开始替换或操作已结束，不能取消；请查看最终结果',
		update_operation_changed: '更新操作已变化，请重新读取进度',
		update_transition_busy: '设备正在切换更新阶段，请重新读取进度',
		candidate_group_reset_failed: '候选出口初始化失败',
		runtime_mode_changed: '设备运行模式已变化，请读取当前状态后再切换',
		runtime_mode_unconfirmed: '切换后的运行模式未通过确认',
		runtime_mode_cleanup_failed: '停止代理后的网络接管清理未通过确认',
		compatibility_stop_failed: 'HTTPS 兼容服务未能停止，未继续切换核心',
		supervisor_stop_failed: '自动调度未能停止，未继续切换核心',
		supervisor_start_failed: '自动调度未能启动',
		profile_restore_failed: '原生代理配置未能恢复运行',
		initialization_failed: '代理出口未能完成初始化',
		owner_readback_failed: '代理核心或出口的运行状态未通过确认',
		plugin_data_busy: '插件数据正在读写，请稍后重试',
		plugin_system_revision_changed: '服务组合或插件版本已变化，请关闭后重新读取',
		plugin_system_dependencies_invalid: '组合依赖不完整，请先修正校验结果',
		plugin_system_recovery_required: '组合恢复尚未确认，请检查相关插件状态',
		plugin_system_apply: '组合应用失败',
		plugin_system_invalid: '服务组合格式无效',
		plugin_package_maintenance: '插件正在安装或维护',
		plugin_kernel_maintenance: '内核正在更新，请稍后重试',
		plugin_disabled: '插件未启用',
		healthy_connections_still_draining: '现有连接仍在传输，尚未排空。为保留连接，请在传输结束后重试',
		compatibility_stop_unconfirmed: '尚未确认兼容服务已停止，请查看当前状态',
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
	})[code] || (/^[a-z][a-z0-9_]*$/.test(String(code || '')) ? '操作未能完成，请查看技术详情或诊断记录' : String(code || '设备未返回成功结果'));
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
	snapshotting: '保存恢复点', deactivating: '退出旧配置', saving: '保存配置',
	activating: '启用配置并检查网络',
	preparing: '准备更新', checking: '检查更新源', downloading: '下载中', validating: '校验内容',
	draining: '等待相关功能安全退出',
	compiling: '生成运行配置', reloading: '重载运行配置', selecting: '重新选优',
	measuring: '共享测速', applying: '应用出口', installing: '安装组件', verifying: '确认运行状态', rolling_back: '恢复更新前状态', done: '已完成'
};

const MODE_LABELS = { openwrt: '纯 OpenWrt', mihomo: 'Mihomo 原生代理', netfleet: 'NetFleet 增强代理' };
const MODE_PHASE_LABELS = {
	checking_mode: '核对当前运行模式', stopping_compatibility: '停止 HTTPS 兼容服务',
	stopping_scheduler: '暂停自动调度', stopping_proxy: '停止代理并清理网络接管',
	restoring_native: '恢复原生代理并检查网络', starting_scheduler: '启动自动调度',
	checking_inputs: '校验运行配置与恢复条件', switching_profile: '切换配置并重启代理核心',
	initializing_exits: '等待出口初始化', measuring: '测量机场节点延迟',
	resetting_candidates: '初始化候选出口', selecting: '测量候选并选择出口',
	activating_exit: '启用出口并验证路径', probing: '验证业务连通性', rolling_back: '恢复可用运行模式'
};

function isRunning(operation) { return operation && ['queued', 'running'].includes(operation.state); }

// Only operation identities and display timestamps cross page scopes. Origin storage
// isolates devices; source contents and credentials never enter this record.
const RESULT_LIFETIME_MS = 60000;
function observedResult(controller, kind, operation) {
	const key = 'netfleet:observed:v1:' + kind;
	const records = controller.observedResults || (controller.observedResults = {});
	if (!Object.prototype.hasOwnProperty.call(records, kind)) {
		try { records[kind] = JSON.parse(sessionStorage.getItem(key)); } catch (_) { records[kind] = null; }
	}
	let record = records[kind];
	const now = Date.now();
	const identity = JSON.stringify([operation.id, operation.started_at]);
	if (isRunning(operation) || controller[kind + 'Request'] && record?.identity !== identity) record = { identity: identity, seenAt: now };
	else if (!record || record.identity !== identity || !record.expiresAt && now - record.seenAt >= RESULT_LIFETIME_MS) return false;
	if (!isRunning(operation) && !record.expiresAt) record.expiresAt = now + RESULT_LIFETIME_MS;
	records[kind] = record;
	try { sessionStorage.setItem(key, JSON.stringify(record)); } catch (_) {}
	return !record.expiresAt || now < record.expiresAt;
}

function operationBusy(controller) {
	return controller.modeRequest || controller.configurationRequest || controller.subscriptionRequest || controller.selectionRequest ||
		Object.values(controller.operations || {}).some(isRunning);
}

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
	const pending = controller[kind + 'Request'];
	const disconnected = controller.operationError && (pending || isRunning(operation));
	const attrs = { 'class': 'netfleet-operation', 'data-netfleet-operation': kind, 'role': 'status', 'aria-live': 'polite' };
	if (kind === 'selection' && related && !controller.selectionRequest) return E('div', Object.assign(attrs, { 'hidden': true }));
	if (!operation && !pending) return E('div', Object.assign(attrs, { 'hidden': true }));
	if (operation) {
		const observed = observedResult(controller, kind, operation);
		if (operation.state === 'succeeded' && !observed) return E('div', Object.assign(attrs, { 'hidden': true }));
	}
	const active = operation ? isRunning(operation) : pending;
	const state = disconnected ? '连接中断，执行结果尚未确认' : operation?.cancel_requested && isRunning(operation) ? '正在取消，等待当前步骤结束并恢复原状态' : operation?.error?.startsWith('update_cancelled') ? '已取消' : operation?.error?.startsWith('update_deferred') ? '已延后' : !operation ? '等待设备接收' :
		({ queued: '已提交，等待设备执行', running: kind === 'selection' ? ({ preparing: '准备测速', checking: '检查节点健康', selecting: '测速与选优', verifying: '验证业务连通性' })[operation.phase] || PHASE_LABELS[operation.phase] || '处理中' : kind === 'mode' ? MODE_PHASE_LABELS[operation.phase] || PHASE_LABELS[operation.phase] || '处理中' : PHASE_LABELS[operation.phase] || '处理中', succeeded: '已完成', failed: '执行失败', interrupted: '执行已中断，结果尚未确认' })[operation.state] || '等待设备确认';
	const started = operation && operation.started_at || controller[kind + 'StartedAt'];
	const end = active ? Date.now() / 1000 : operation && operation.finished_at;
	const elapsed = started && end >= started ? Math.floor(end - started) : null;
	const details = [ E('strong', { 'class': active && !disconnected ? 'spinning' : '' }, state) ];
	if (operation && operation.subject) {
		const capability = ['selection', 'mode'].includes(kind) && controller.status && (controller.status.capabilities || []).find(function(item) { return item.id === operation.subject; });
		details.push(E('span', {}, kind === 'packages' ? ({ feed: '更新源', netfleet: 'NetFleet', mihomo: 'Mihomo' })[operation.subject] || String(operation.subject) : (kind === 'mode' ? '出口：' : '') + (capability && capability.display_name || String(operation.subject))));
	}
	if (operation && (kind !== 'packages' || operation.phase === 'downloading') && (active || operation.state === 'succeeded') && Number(operation.total) > 0) {
		const label = kind === 'subscription' ? '已处理 ' : kind === 'selection' ? '已完成 ' : '已完成 ';
		const unit = operation.phase === 'resetting_candidates' ? ' 个候选组' : kind === 'subscription' ? ' 个机场' : ['selection', 'mode'].includes(kind) ? ' 个出口' : ' 个文件';
		details.push(E('span', {}, label + Number(operation.completed || 0) + ' / ' + Number(operation.total) + unit));
	}
	if (kind === 'subscription' && related && operation.phase === 'selecting') {
		details.push(E('span', {}, ({ preparing: '准备测速', checking: '检查节点健康', selecting: '测量候选并选优', verifying: '验证业务连通性' })[selection.phase] || PHASE_LABELS[selection.phase] || '测速与选优'));
		if (selection.total > 0) details.push(E('span', {}, '已完成 ' + Number(selection.completed || 0) + ' / ' + Number(selection.total) + (selection.phase === 'resetting_candidates' ? ' 个候选组' : ' 个出口')));
		if (selection.error) details.push(E('span', { 'class': 'is-warning' }, errorLabel(selection.error)));
	}
	if (!active) details.push(E('span', {}, operation.finished_at ? resultTime(operation.finished_at) : operation.updated_at ? resultTime(operation.updated_at, '记录更新于') + '（完成时间未记录）' : '完成时间未记录'));
	if (elapsed != null) details.push(E('span', {}, (active ? '已耗时 ' : '耗时 ') + (elapsed < 60 ? elapsed + ' 秒' : Math.floor(elapsed / 60) + ' 分 ' + elapsed % 60 + ' 秒')));
	if (operation && operation.error) details.push(E('span', { 'class': 'is-warning netfleet-result-reason' }, errorLabel(operation.error)));
	if (operation?.error) details.push(E('details', {}, [E('summary', {}, '技术详情'), E('code', {}, operation.error)]));
	if (kind === 'packages' && active) {
		details.push(E('span', {}, operation.write_started ? '正在替换或验证组件；请保持设备供电，结果会自动回读。' : operation.phase === 'draining' ? '尚未替换软件包；等待连接结束，无法安全退出时会保留旧版。' : '尚未替换软件包；可继续浏览。'));
		if (operation.can_cancel) details.push(button('取消本次更新', function() {
			return api.componentsCancel(operation.id).then(function() { return readOperations(controller); }).catch(function(error) {
				controller.operationError = error; updateOperationNodes(controller);
			});
		}, controller.context?.readOnly || operation.cancel_requested));
	}
	if (operation && operation.failure_detail) {
		const failure = operation.failure_detail;
		details.push(E('details', { 'class': 'netfleet-operation-diagnostic' }, [ E('summary', {}, '查看失败详情'),
			E('p', {}, [failure.group ? '候选组：' + failure.group : '', failure.http_status ? 'HTTP ' + failure.http_status : '未收到控制接口响应',
				failure.transport_code ? '连接错误码：' + failure.transport_code : '', failure.attempts ? '尝试 ' + failure.attempts + ' 次' : ''].filter(Boolean).join('；')) ]));
	}
	if (operation && operation.recovery) details.push(E('span', {}, ({ restored: '已恢复更新前状态', native: '已恢复 Mihomo 原生代理', unchanged: '已确认保持原运行模式', failed: kind === 'mode' ? '恢复结果未通过确认' : '恢复失败', direct: '已恢复网络直通' })[operation.recovery] || '恢复结果尚未确认'));
	if (kind === 'mode') {
		const requested = operation?.requested_mode || controller.modeTarget;
		if (requested) details.push(E('span', {}, '目标：' + (MODE_LABELS[requested] || requested)));
		if (operation && !active) details.push(E('span', {}, operation.actual_mode ? '完成时确认：' + MODE_LABELS[operation.actual_mode] : '完成时运行模式未确认'));
		if (active) details.push(E('span', {}, '可继续浏览，进度会自动更新。'));
	}
	if (kind === 'configuration' && active) details.push(E('span', {}, '可继续浏览；完成前请勿重复应用。'));
	const title = kind === 'mode' ? '运行模式切换' : kind === 'configuration' ? '配置应用' : kind === 'subscription' ? '机场订阅更新' : kind === 'selection' ? '测速与自动选优' : operation && operation.subject === 'feed' ? '软件包源检查' : '组件更新';
	if (!active) return resultNode(controller, kind, JSON.stringify([operation.id, operation.started_at, operation.state, operation.finished_at, operation.recovery]), title, details,
		['failed', 'interrupted'].includes(operation.state), { 'data-netfleet-operation': kind });
	return E('div', Object.assign(attrs, { 'class': attrs.class + (disconnected || operation && ['failed', 'interrupted'].includes(operation.state) ? ' is-warning' : '') }), [
		E('div', { 'class': 'netfleet-operation-title' }, title),
		E('div', { 'class': 'netfleet-operation-detail' }, details)
	]);
}

function updateOperationNodes(controller) {
	if (controller.context?.signal.aborted) return;
	if (typeof document === 'undefined') return;
	document.querySelectorAll('[data-netfleet-operation]').forEach(function(node) {
		node.replaceWith(operationNode(controller, node.getAttribute('data-netfleet-operation')));
	});
}

function scheduleResultExpiry(controller) {
	clearTimeout(controller.resultTimer);
	const expiries = Object.values(controller.observedResults || {}).map(function(record) { return record?.expiresAt; }).filter(function(at) { return at > Date.now(); });
	if (expiries.length && !controller.context?.signal.aborted)
		controller.resultTimer = setTimeout(function() { updateOperationNodes(controller); scheduleResultExpiry(controller); }, Math.min(...expiries) - Date.now() + 1);
}

function readOperations(controller) {
	if (controller.context && controller.context.signal.aborted) return Promise.resolve();
	if (controller.operationRead) return controller.operationRead;
	clearTimeout(controller.operationTimer);
	controller.operationRead = api.operationGet().then(function(snapshot) {
		if (controller.context?.signal.aborted) return;
		const wasBusy = operationBusy(controller);
		Object.entries(controller.operations || {}).forEach(function(entry) { if (isRunning(entry[1])) observedResult(controller, entry[0], entry[1]); });
		const previous = controller.operations && controller.operations.packages;
		const previousConfig = controller.operations?.configuration;
		const previousMode = controller.operations?.mode;
		if (controller.modeRequest && snapshot.mode?.id === controller.previousModeId) snapshot.mode = null;
		if (controller.configurationRequest && snapshot.configuration?.id === controller.previousConfigurationId) snapshot.configuration = null;
		if (controller.subscriptionRequest && snapshot.subscription && snapshot.subscription.id === controller.previousSubscriptionId) snapshot.subscription = null;
		if (controller.selectionRequest && snapshot.selection && snapshot.selection.id === controller.previousSelectionId) snapshot.selection = null;
		if (controller.packageOperationId && (!snapshot.packages || snapshot.packages.id !== controller.packageOperationId) && isRunning(previous)) snapshot.packages = previous;
		controller.operations = snapshot;
		controller.operationError = null;
		Object.entries(snapshot).forEach(function(entry) { if (entry[1]) observedResult(controller, entry[0], entry[1]); });
		if (wasBusy !== operationBusy(controller)) controller.redraw();
		if (previousMode && isRunning(previousMode) && snapshot.mode?.id === previousMode.id &&
			!isRunning(snapshot.mode) && !controller.modeRequest)
			controller.refreshData(true).catch(function() {});
		if (previousConfig && isRunning(previousConfig) && snapshot.configuration?.id === previousConfig.id &&
			!isRunning(snapshot.configuration) && !controller.configurationRequest)
			controller.refreshData(true, true).catch(function() {});
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
		const running = operationBusy(controller);
		if (running && !(controller.context && controller.context.signal.aborted))
			controller.operationTimer = setTimeout(function() { if (!controller.root || controller.root.isConnected !== false) readOperations(controller); }, 1000);
		scheduleResultExpiry(controller);
	});
	return controller.operationRead;
}

function runConfiguration(controller, request) {
	controller.invalidateReads?.();
	controller.configurationRequest = true;
	controller.configurationStartedAt = Math.floor(Date.now() / 1000);
	controller.previousConfigurationId = controller.operations?.configuration?.id;
	controller.operations = Object.assign({}, controller.operations, { configuration: null });
	ui.showModal('应用 NetFleet 配置', [ E('div', { 'class': 'netfleet-native' }, [
		operationNode(controller, 'configuration'), E('div', { 'class': 'right' }, button('收起进度', ui.hideModal))
	]) ]);
	controller.redraw();
	readOperations(controller);
	return Promise.resolve().then(request).then(function() {
		if (controller.context?.signal.aborted) return;
		return readOperations(controller).then(function() { return controller.refreshData(true, true); });
	}).catch(function(error) {
		if (controller.context?.signal.aborted) return;
		const uncertain = error && (error.netfleetKind === 'request_aborted' || /timeout|XHR|network/i.test(error.message || ''));
		controller.operationError = uncertain ? error : null;
		notify(null, E('p', {}, uncertain ? '连接中断，配置应用结果尚未确认；请等待设备回读，不要重复应用。' :
			'配置应用反馈：' + (controller.configFailure ? controller.configFailure(error) : failure(error))), uncertain ? 'warning' : 'error');
	}).finally(function() {
		controller.configurationRequest = false;
		if (!controller.context?.signal.aborted) readOperations(controller).then(function() { controller.redraw(); });
	});
}

function runSelection(controller, request, title) {
	controller.invalidateReads?.();
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
	controller.invalidateReads?.();
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

function coreVersion(value) { return String(value || '').replace(/^v/, '').replace(/-r\d+$/, ''); }
function displayVersion(value) { return value ? coreVersion(value) : '版本未提供'; }
function quotaResetLabel(day) {
	return Number.isInteger(day) && day >= 1 && day <= 31 ? '每月 ' + day + ' 日重置' : '';
}

function loadComponents(controller) { return loadModule('components').then(function(module) { return module.loadComponents(controller); }); }
function subscriptionAction(name, args) { return loadModule('subscriptions').then(function(module) { return module[name](...args); }); }
return baseclass.extend({ displayVersion, quotaResetLabel, errorLabel, notify,
    preloadSubscriptions: function(...args) { return subscriptionAction('preloadSubscriptions', args); },
    subscriptions: function(...args) { return subscriptionAction('subscriptions', args); },
    migration: function(...args) { return subscriptionAction('migration', args); },
    nativeSetup: function(...args) { return subscriptionAction('nativeSetup', args); },
    operationNode, operationBusy, readOperations, runConfiguration, runSubscription, runSelection, loadComponents,
button, coreVersion, failure, isRunning, resultNode, resultTime
});
