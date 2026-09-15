/* SPDX-License-Identifier: Apache-2.0 */
'use strict';
const { errorLabel, failure, button, isRunning, resultTime, resultNode, operationNode, readOperations, coreVersion, displayVersion } = managed;
function packageManagerRoute(menu, path) {
	for (const [name, node] of Object.entries(menu && menu.children || {})) {
		if (node.satisfied === false) continue;
		const route = (path || []).concat(name);
		if (node.title && node.action?.type === 'view' && ['package-manager', 'system/opkg', 'system/apk'].includes(node.action.path)) return route;
		const found = packageManagerRoute(node, route);
		if (found) return found;
	}
	return null;
}

function packageManagerLink(controller, label) {
	return controller.packageManagerUrl ? E('a', { 'class': 'netfleet-inline-link', 'href': controller.packageManagerUrl, 'target': '_blank', 'rel': 'noopener' }, label || '软件包管理 ↗') :
		E('small', {}, controller.packageManagerRead && !controller.packageManagerResolved ? '正在读取软件包管理入口…' : '此设备未提供软件包管理页面');
}

async function readPluginState(request) {
	// A background mutation can briefly hold the host lock. Retry reads only;
	// lifecycle writes must never be replayed after an uncertain response.
	for (let attempt = 0; ; attempt++) {
		try { return await api.pluginRead(request); }
		catch (error) {
			if (error.message !== 'mutation_busy' || attempt >= 2) throw error;
			await new Promise(resolve => setTimeout(resolve, attempt === 0 ? 200 : 600));
		}
	}
}

function loadComponents(controller) {
	if (controller.componentsRead) return controller.componentsRead;
	controller.componentsLoading = true;
	controller.componentsError = null;
	if (!controller.packageManagerRead) controller.packageManagerRead = Promise.resolve().then(function() {
		return ui.menu && typeof ui.menu.load === 'function' ? ui.menu.load() : null;
	}).then(function(menu) {
		const route = packageManagerRoute(menu);
		controller.packageManagerUrl = route ? L.url.apply(L, route) : null;
	}).catch(function() { controller.packageManagerUrl = null; }).finally(function() { controller.packageManagerResolved = true; });
	const inventory = api.componentsGet().then(function(snapshot) { controller.components = snapshot;
		return Promise.all((snapshot.extensions || []).filter(plugin => plugin.kind === 'plugin' && plugin.runtime === 'process' && plugin.revision).map(async plugin => {
			try {
				const result = await readPluginState({ id: plugin.id, instance: plugin.instance || 'default', action: 'get', params: {} });
				plugin.enabled = typeof result.loaded === 'boolean' ? result.loaded : null;
				plugin.revision = result.revision || plugin.revision;
				delete plugin.stateReadError;
			} catch (error) { plugin.enabled = null; plugin.stateReadError = error.message || String(error); }
		}));
	}).catch(function(error) {
		controller.componentsError = error;
	});
	controller.componentsRead = Promise.all([inventory, controller.packageManagerRead]).finally(function() { controller.componentsLoading = false; controller.componentsRead = null; if (controller.currentView === 'components') controller.redraw(); });
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

function managementRequired(plugin) {
	return ['product-ui', 'components', 'status', 'events', 'setup'].includes(plugin.id);
}

function pluginDialog(controller, plugin, initialAction) {
	const output = E('pre', { 'style': 'max-height:18rem;overflow:auto;white-space:pre-wrap;overflow-wrap:anywhere' }, '');
	const status = E('p', { 'role': 'status' }, '正在读取运行状态…');
	const service = plugin.runtime === 'service';
	const labels = { load: '启用', reload: '重新启动', unload: '禁用', get: '刷新状态' };
	let revision = plugin.revision;
	let pending = false;
	let loaded = null;
	let closed = false;
	const controls = [];
	function busy(value) {
		pending = value;
		controls.forEach(function(control) {
			const action = control.getAttribute('data-action');
			control.hidden = (action === 'load' || action === 'unload') && (loaded === null || (action === 'load' ? loaded : !loaded));
			control.setAttribute('style', control.hidden ? 'display:none' : '');
			control.disabled = value || action !== 'get' && (controller.context?.readOnly || loaded === null || (action === 'unload' && managementRequired(plugin)) ||
				(action === 'load' ? loaded : !loaded));
		});
	}
	function show(result) {
		revision = result.revision || revision;
		loaded = typeof result.loaded === 'boolean' ? result.loaded : null;
		status.textContent = result.loaded === true ? (result.ready === true ? '已启用 · 运行就绪' : '已启用 · 尚未就绪') : result.loaded === false ? '已禁用' : '运行状态暂不可确认';
		function update(item) {
			item.enabled = loaded; item.revision = revision;
			delete item.stateReadError;
			if (service && loaded === true && result.ready === true) { item.state = 'available'; item.reason = null; }
		}
		update(plugin);
		const row = controller.components?.extensions?.find(item => item.id === plugin.id && (item.instance || 'default') === (plugin.instance || 'default'));
		if (row) update(row);
		controller.redraw();
		output.textContent = JSON.stringify(result, null, 2);
	}
	function run(action) {
		if (pending) return;
		const writing = action !== 'get';
		if (writing && (loaded === null || controller.context?.readOnly || (action === 'unload' && managementRequired(plugin)))) return;
		const execute = function() {
			busy(true);
			status.textContent = writing ? labels[action] + '中…' : '正在读取运行状态…';
			const request = { id: plugin.id, action: action, revision: revision, confirm: writing, params: {} };
			if (plugin.instance) request.instance = plugin.instance;
			return (writing ? api.pluginCall(request).then(function(result) {
				revision = result.revision || revision;
				// Lifecycle success already includes the host's authoritative readback.
				return typeof result.loaded === 'boolean' ? result : readPluginState({ ...request, action: 'get', revision, confirm: false });
			}) : readPluginState(request)).then(function(result) {
				if (!closed) show(result);
			}).catch(async function(error) {
				if (closed) return;
				loaded = null;
				if (!writing) { plugin.enabled = null; plugin.stateReadError = error.message || String(error); status.textContent = '状态读取失败：' + errorLabel(plugin.stateReadError); controller.redraw(); return; }
				try {
					const result = await readPluginState({ ...request, action: 'get', revision, confirm: false });
					if (closed) return;
					show(result);
					const reached = action !== 'reload' && typeof result.loaded === 'boolean' && result.loaded === (action !== 'unload');
					status.textContent = reached ? status.textContent + '。请求返回异常，已自动回读确认当前状态。'
						: (loaded === null || action === 'reload' ? labels[action] + '结果未确认' : '未' + labels[action]) + '；' + status.textContent + '。' + errorLabel(error.message || String(error));
				} catch (readError) {
					plugin.enabled = null;
					plugin.stateReadError = readError.message || String(readError);
					status.textContent = labels[action] + '结果未确认：请求失败，自动回读也未成功。' + errorLabel(error.message || String(error));
					controller.redraw();
				}
			}).finally(function() { busy(false); });
		};
		if (!writing) return execute();
		ui.showModal('确认' + labels[action], [ E('p', {}, (pluginLabel(plugin)) + '：' + (action === 'unload' ? '将停止此插件提供的功能，保留软件包和配置。正在使用此插件的连接可能中断。若仍被其他插件依赖，宿主会拒绝禁用。' : action === 'reload' ? '将重新启动此插件进程，相关功能会短暂中断。' : '将启用此插件并检查是否就绪。')),
			E('div', { 'class': 'right' }, [ button('取消', function() { pluginDialog(controller, plugin); }), ' ',
				button('确认', function() { open(); execute(); }) ]) ]);
	}
	(service ? ['get', 'load', 'unload'] : ['get', 'load', 'unload', 'reload']).forEach(function(action) {
		const control = button(labels[action], function() { return run(action); });
		control.setAttribute('data-action', action); controls.push(control);
	});
	const children = [E('p', {}, plugin.id + ' · ' + (service ? '服务插件' : '进程插件') + ' · ' + displayVersion(plugin.installed_version || plugin.version)),
		E('p', {}, pluginPurpose(plugin)), status,
		E('div', { 'class': 'netfleet-inline-actions' }, controls.slice(0, 3)),
		E('p', {}, managementRequired(plugin) ? '管理界面必需：此页面不提供禁用，避免失去管理和恢复入口。' : '开关由 NetFleet 宿主管理；禁用保留软件包和配置。')];
	if (plugin.id === 'activation') children.push(button('前往概览切换运行模式', function() {
		ui.hideModal(); controller.context.navigate('plugin:product-ui:overview');
	}));
	if (!service) children.push(E('details', {}, [E('summary', {}, '进程维护'), E('div', { 'class': 'netfleet-inline-actions' }, controls.slice(3))]));
	children.push(E('details', {}, [E('summary', {}, '技术详情'), E('p', {}, '软件包：' + (plugin.package || '未提供')),
		E('p', {}, '完整版本：' + (plugin.installed_version || plugin.version || '未记录')), output]));
	children.push(E('div', { 'class': 'right' }, button('关闭', function() { closed = true; ui.hideModal(); })));
	function open() { ui.showModal((pluginLabel(plugin)) + ' · 运行状态', E('div', { 'class': 'netfleet-plugin-runtime' }, children)); }
	open(); return run('get').then(function() {
		if (!closed && initialAction && loaded !== null && (initialAction === 'load' ? !loaded : loaded)) return run(initialAction);
	});
}

function startPackageOperation(controller, component, pluginRequest) {
	if (componentsLocked(controller)) return Promise.resolve();
	controller.componentsError = null;
	controller.componentsStarting = true;
	controller.packageTarget = component ? { component: component.id, version: component.available_version } : null;
	controller.redraw();
	const request = pluginRequest ? api.componentsPlugin(pluginRequest) : component ? api.componentsUpdate(component.id, component.available_version) : api.componentsCheck();
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

function pluginPackages(controller, snapshot) {
	const active = componentsLocked(controller);
	const rows = (snapshot.plugin_packages || []).map(function(item) {
		const plugin = (snapshot.extensions || []).find(function(row) { return row.package === item.name || (item.runtime_package && row.id === item.id); });
		const actions = [];
		function action(kind, label) {
			return button(label, function() {
				const request = { name: item.name, action: kind, before_version: item.installed_version, version: item.available_version, confirm: true };
				const planView = E('p', { role: 'status' }, '正在确认实际软件包变化…');
				let closed = false;
				const confirm = button('确认' + label, function() {
					closed = true; ui.hideModal(); return startPackageOperation(controller, null, request);
				}, true);
				ui.showModal(label + ' ' + (pluginLabel(plugin || item)), [
					E('p', {}, kind === 'remove' ? '卸载此插件的软件包，保留私有配置。设备会再次检查禁用状态与依赖，拒绝连带删除其他软件。' :
						'目标版本：' + displayVersion(item.available_version) + '。设备会校验签名并补齐缺少的依赖；必要的配套插件与运行包由 APK 自动解析，并列在下方；基础组件变化需要单独维护。安装不自动启用功能；提供共享服务的插件会排空并恢复其依赖资源。'),
					E('p', {}, '任务在设备后台执行，可离开页面；进度和结果会持续回读。'),
					planView, E('div', { 'class': 'right' }, [button('取消', function() { closed = true; ui.hideModal(); }), ' ', confirm])
				]);
				return api.componentsPluginPlan({ ...request, confirm: false }).then(function(plan) {
					if (closed) return;
					request.plan = plan;
					planView.replaceChildren(E('ul', {}, plan.names.map(function(name) {
						return E('li', {}, name + (plan.candidates[name] ? ' → ' + displayVersion(plan.candidates[name]) : '：卸载'));
					})));
					confirm.disabled = false;
				}).catch(function(error) { if (!closed) planView.textContent = errorLabel(error.message); });
			}, active || (kind === 'remove' ? plugin?.enabled !== false : !snapshot.feed.configured || !!snapshot.feed.error));
		}
		if (!item.runtime_package && !item.installed_version && item.available_version) actions.push(action('install', '安装'));
		if (item.update_available) actions.push(action('update', '更新'));
		if (!item.runtime_package && item.installed_version && !item.required) {
			actions.push(action('remove', '卸载'));
			if (plugin?.enabled !== false) actions.push(E('small', {}, '先在运行管理中禁用，再卸载'));
		}
		return E('tr', {}, [
			E('td', {}, [E('strong', {}, pluginLabel(plugin || item) + (item.runtime_package ? ' · 转发引擎' : '')), E('small', {}, plugin?.description || pluginPurpose(plugin || item)), E('small', {}, item.name)]),
			E('td', {}, [E('strong', {}, item.installed_version ? displayVersion(item.installed_version) : '未安装'),
				item.available_version ? E('small', {}, (item.update_available ? '可更新至 ' : '更新源版本 ') + displayVersion(item.available_version)) : E('small', {}, '检查更新以读取候选版本'),
				item.dependencies?.length ? E('details', {}, [E('summary', {}, '依赖'), E('p', {}, item.dependencies.join('、'))]) : '']),
			E('td', { 'class': 'netfleet-component-actions' }, actions)
		]);
	});
	return E('section', { 'class': 'netfleet-component-modules' }, [E('h3', {}, '安装与维护独立插件'),
		E('p', {}, '从设备已信任的软件源读取。插件和已安装的配套运行引擎统一在此更新，依赖由系统软件包管理器自动处理；必需插件不可单独卸载。'),
		button('检查插件更新', function() { return startPackageOperation(controller); }, active || !snapshot.feed.configured),
		rows.length ? E('div', { 'class': 'netfleet-component-table' }, E('table', { 'class': 'table' }, [
			E('thead', {}, E('tr', {}, ['插件', '安装与候选版本', '软件包操作'].map(label => E('th', {}, label)))), E('tbody', {}, rows)
		])) : E('p', {}, snapshot.feed.checked_at && !snapshot.feed.error ? '当前软件源没有额外插件。安装完整发行版可配置官方可选插件源。' : '检查更新后显示软件源中的独立插件。')
	]);
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



function componentMismatch(component) {
	return component.id === 'mihomo' && component.installed_version && component.running_version &&
		coreVersion(component.installed_version) !== coreVersion(component.running_version);
}

const PLUGIN_PRESENTATION = {
	'device-identity': ['设备识别', '识别网络设备，为按设备配置规则提供稳定身份'],
	activation: ['网络启停', '切换运行模式，应用或退出代理接管'],
	compilation: ['运行配置生成', '根据策略与节点来源生成代理运行配置'],
	components: ['组件更新', '检查并更新基础软件与面板资源'],
	configuration: ['运行策略', '读取、校验和保存出口与选路策略'],
	dashboard: ['Zashboard', '提供实时面板入口与资源更新'],
	events: ['操作与选路记录', '记录设备操作进度和选路事件'],
	'https-compat': ['HTTPS 兼容', '为指定设备和网站提供 HTTPS 协议兼容'],
	maintenance: ['配置文件与维护', '管理配置文件、备份与核心维护'],
	mihomo: ['Mihomo 接入', '连接代理核心并管理其运行配置'],
	models: ['策略数据', '提供机场、地区与出口的结构化配置'],
	network: ['网络接入', '管理设备代理、DNS 与监听设置'],
	platform: ['运行环境', '提供设备进程与运行环境能力'],
	'platform-openwrt': ['OpenWrt 设备设置', '接入系统配置与设备信息'],
	'platform-storage': ['文件存储', '读写配置文档与设备文件'],
	'product-ui': ['NetFleet 业务界面', '提供概览、出口与配置等页面的内容和交互；由 LuCI 接入组件加载'],
	recovery: ['网络恢复', '在退出或异常时恢复网络直连'],
	refresh: ['订阅更新', '更新订阅并准备最新节点'],
	scheduler: ['自动运行', '按计划执行订阅更新与自动选优'],
	selection: ['出口选优', '为各出口测速并选择可用路径'],
	'selection-algorithm': ['选优算法', '按策略比较地区与候选路径'],
	setup: ['首次接入', '准备运行基础并接入已有设置'],
	status: ['运行状态', '汇总当前出口、机场与设备运行状态'],
	subscriptions: ['节点来源', '管理机场订阅与节点缓存']
};
function pluginLabel(plugin) {
	return PLUGIN_PRESENTATION[plugin.id]?.[0] || plugin.label || plugin.id;
}
function pluginPurpose(plugin) {
	return plugin.description || PLUGIN_PRESENTATION[plugin.id]?.[1] ||
		(plugin.runtime === 'service' ? '为 NetFleet 提供 ' + (pluginLabel(plugin)) + ' 服务' : '通过独立进程提供 ' + (pluginLabel(plugin)) + ' 功能');
}

function componentsPage(controller) {
	const snapshot = controller.components;
	const section = controller.componentsSection || 'software';
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
	const content = [ E('div', { 'class': 'netfleet-section-heading' }, [ E('h3', {}, section === 'software' ? '版本与更新' : '插件目录'), E('div', { 'class': 'netfleet-inline-actions' }, [
		refresh, section === 'software' ? check : packageManagerLink(controller)
	]) ]) ];
	if (section === 'software') content.push(operationNode(controller, 'packages'));
	content.unshift(E('nav', { 'class': 'netfleet-subtabs', 'aria-label': '插件与更新分类' }, [['software', '基础组件'], ['plugins', '功能插件']].map(function(item) {
		return E('button', { 'type': 'button', 'aria-current': section === item[0] ? 'page' : null, 'click': function() { controller.componentsSection = item[0]; controller.redraw(); } }, item[1]);
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
	if (section === 'software' && feed.error && !sameFeedFailure && !isRunning(packageOperation)) content.push(resultNode(controller, 'feed', String(feed.checked_at || 0), '软件包源检查', [
		E('span', {}, errorLabel(feed.error)), E('span', {}, resultTime(feed.checked_at, '检查于') || '检查时间未记录')
	], true));
	const dashboardError = controller.dashboardError || dashboard && dashboard.error;
	if (section === 'software' && dashboard && dashboard.managed && !controller.dashboardBusy && !controller.componentsChecking && (dashboardError || controller.dashboardResultAt)) {
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
	const luci = snapshot.components.find(function(item) { return item.id === 'luci'; });
	const product = snapshot.product;
	if (section === 'software' && product) content.push(E('details', { 'class': 'netfleet-component-details', 'open': product.missing.length ? true : null }, [
		E('summary', { 'class': product.missing.length ? 'is-warning' : '' }, product.missing.length ? '默认产品缺少 ' + product.missing.length + ' 个软件包' : '默认产品软件包齐全'),
		E('p', {}, '此处核对安装组成；网络是否正常请查看概览，插件是否启用请查看功能插件。' + (product.updates.length ? '更新源有 ' + product.updates.length + ' 个产品包可更新。' : '')),
		product.missing.length ? E('p', {}, '请通过软件包管理重新安装 NetFleet 默认产品以补齐依赖。') : '',
		E('ul', { 'class': 'netfleet-dependencies' }, product.packages.map(function(item) { return E('li', {}, [E('strong', {}, item.name), E('span', {}, item.installed_version || '未安装'), product.updates.includes(item.name) ? E('small', {}, '可更新至 ' + item.available_version) : '']); }))
	]));
	const rows = snapshot.components.filter(function(item) { return item.id !== 'luci'; }).map(function(component) {
		const mismatch = componentMismatch(component);
		const hasUpdate = component.update_available || component.id === 'netfleet' && luci && luci.update_available;
		const uiOnly = component.id === 'netfleet' && !component.update_available && luci && luci.update_available;
		const canUpdate = snapshot.supported && feed.configured && !feed.error && component.managed && hasUpdate && component.available_version;
		const targetVersion = displayVersion(component.available_version) + (component.id === 'netfleet' && luci && luci.available_version ? '；LuCI 接入组件 ' + displayVersion(luci.available_version) : '');
		const update = canUpdate ? button(mismatch ? '更新软件包' : uiOnly ? '更新界面' : '更新', function() {
			ui.showModal('更新 ' + component.label, [ E('p', {}, (component.id === 'mihomo' ? '核心更新会中断已有代理连接，设备将校验当前配置并检查重启后的运行状态。' : '将更新 NetFleet 与 LuCI 接入组件；基础包更新会停止并恢复运行服务，已有连接可能中断。完成后重新载入页面，私有配置保留。') + '目标版本：' + targetVersion),
				mismatch ? E('p', { 'class': 'is-warning' }, '当前运行 ' + displayVersion(component.running_version) + '，安装记录 ' + displayVersion(component.installed_version) + '。本次将安装所列候选软件包，请核对版本。') : '',
				E('details', {}, [E('summary', {}, '完整包版本'), E('p', {}, component.available_version), luci && component.id === 'netfleet' ? E('p', {}, 'LuCI ' + luci.available_version) : '']),
				E('div', { 'class': 'right' }, [ button('取消', ui.hideModal), ' ', button('确认更新', function() { ui.hideModal(); return startPackageOperation(controller, component); }) ]) ]);
		}, active) : '';
		const current = [ E('strong', {}, component.id === 'mihomo' ? component.running_version ? displayVersion(component.running_version) : '核心运行版本暂不可读取' : component.installed_version ? displayVersion(component.installed_version) : '未安装') ];
		if (component.id === 'mihomo' && component.installed_version) current.push(E('small', {}, '安装记录 ' + displayVersion(component.installed_version)));
		current.push(E('details', {}, [E('summary', {}, '版本详情'), E('small', {}, '完整包版本：' + (component.installed_version || '未安装')), component.running_version ? E('small', {}, '运行版本：' + component.running_version) : '', component.available_version ? E('small', {}, '候选包版本：' + component.available_version) : '']));
		if (component.id === 'netfleet' && controller.status && controller.status.build && controller.status.build.source_commit)
			current.push(E('details', {}, [ E('summary', {}, '构建来源'), E('small', {}, controller.status.build.source_commit) ]));
		if (mismatch) current.push(E('span', { 'class': 'is-warning' }, '运行版本与安装记录不一致'));
		if (component.reason) current.push(E('small', {}, errorLabel(component.reason)));
		const available = component.available_version && !feed.error ? [ uiOnly ? '界面可更新至 ' + displayVersion(luci.available_version) : hasUpdate ? '候选版本 ' + displayVersion(component.available_version) : '当前更新源暂无新版' ] : [];
		if (hasUpdate && !feed.error) available.push(E('small', {}, component.id === 'mihomo' ? '更新核心会中断已有代理连接' : '基础包更新会停止并恢复服务，私有配置保留'));
		return E('tr', {}, [ E('td', {}, [ E('strong', {}, component.label), E('small', {}, component.id === 'netfleet' ? '管理运行策略、出口选优与网络恢复' : '执行代理连接与流量转发') ]),
			E('td', {}, current), E('td', { 'class': 'netfleet-component-actions' }, [ E('div', {}, available), update ]) ]);
	});
	if (luci) rows.splice(1, 0, E('tr', {}, [ E('td', {}, [ E('strong', {}, 'LuCI 接入组件'), E('small', {}, '提供 LuCI 菜单、权限与插件页面加载；业务页面由 product-ui 提供') ]),
		E('td', {}, [E('strong', {}, luci.installed_version ? displayVersion(luci.installed_version) : '未安装'), E('details', {}, [E('summary', {}, '版本详情'), E('small', {}, '完整包版本：' + (luci.installed_version || '未安装')), luci.available_version ? E('small', {}, '候选包版本：' + luci.available_version) : ''])]),
		E('td', {}, [ luci.available_version && !feed.error ? (luci.update_available ? '候选版本 ' + displayVersion(luci.available_version) : '当前更新源暂无新版') : '',
			E('small', {}, '由 NetFleet 更新入口管理') ]) ]));
	const moduleRows = [];
	(snapshot.extensions || []).filter(function(extension) { return extension.kind === 'plugin'; }).forEach(function(plugin) {
		const config = (plugin.ui || []).map(function(page) { return button(plugin.ui.length === 1 ? (plugin.configuration ? '配置' : '打开页面') : page.title, function() {
			controller.context.navigate('plugin:' + plugin.id + ':' + (plugin.instance && plugin.instance !== 'default' ? plugin.instance + ':' : '') + page.id);
		}, active || plugin.enabled === false); });
		const rawVersion = plugin.installed_version || plugin.version;
		const availability = typeof plugin.enabled !== 'boolean' ? '状态未确认' : plugin.enabled === false ? '已禁用' : plugin.reason || plugin.state === 'unavailable' || plugin.state === 'invalid' ? '已启用 · 异常' : '已启用';
		const state = [E('span', { 'class': 'netfleet-plugin-state' }, availability)];
		if (typeof plugin.enabled !== 'boolean') state.push(E('small', {}, plugin.stateReadError ? '暂时无法读取，请打开“查看状态”重试' : '请打开“查看状态”确认后操作'));
		if (plugin.reason && plugin.reason !== 'plugin_disabled') state.push(E('small', { 'class': 'is-warning' }, errorLabel(plugin.reason)));
		if (plugin.revision) state.push(button('查看状态', function() { pluginDialog(controller, plugin); }, active));
		if (plugin.revision && typeof plugin.enabled === 'boolean') state.push(button(plugin.enabled ? '禁用' : '启用', function() {
			return pluginDialog(controller, plugin, plugin.enabled ? 'unload' : 'load');
		}, active || plugin.enabled && managementRequired(plugin)));
		if (managementRequired(plugin)) state.push(E('small', {}, '不可禁用：管理界面必需'));
		moduleRows.push(E('tr', {}, [ E('td', {}, [ E('strong', {}, pluginLabel(plugin)), E('small', { 'class': 'netfleet-plugin-id' }, plugin.id),
			plugin.instance && plugin.instance !== 'default' ? E('small', {}, '实例：' + plugin.instance) : '' ]),
			E('td', {}, [E('span', { 'class': 'netfleet-plugin-kind' }, product ? product.packages.some(function(item) { return item.name === plugin.package; }) ? '默认产品能力' : '独立安装的插件' : plugin.runtime === 'service' ? '服务插件' : '进程插件'), E('small', {}, pluginPurpose(plugin))]),
			E('td', {}, [E('strong', {}, displayVersion(rawVersion)), E('details', {}, [E('summary', {}, '版本详情'), E('small', {}, rawVersion || '未记录'), E('small', {}, plugin.package || '')])]),
			E('td', { 'class': 'netfleet-component-actions' }, config.length ? config : E('small', {}, '无需单独配置')),
			E('td', { 'class': 'netfleet-component-actions' }, state) ]));
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
				dependency.id + '：' + (dependency.available == null ? '未确认' : dependency.available ? dependency.installed_version ? displayVersion(dependency.installed_version) : '已安装' : '缺少')); })
		)));
		moduleRows.push(E('tr', {}, [ E('td', {}, [ E('strong', {}, pluginLabel(extension)), E('small', {}, extension.id) ]),
			E('td', {}, [E('span', { 'class': 'netfleet-plugin-kind' }, '可选模块'), E('small', {}, pluginPurpose(extension))]),
			E('td', {}, [E('strong', {}, extension.installed_version ? displayVersion(extension.installed_version) : absent ? '未安装' : '安装版本未确认'), E('details', {}, [E('summary', {}, '版本详情'), E('small', {}, extension.installed_version || '未记录'), E('small', {}, extension.package)])]),
			E('td', {}, E('small', {}, '由对应功能插件配置')), E('td', {}, current.length ? current : E('small', {}, state)) ]));
	});
	if (dashboard) {
		const controls = [];
		if (dashboard.available && controller.dashboardUrl) controls.push(E('a', { 'class': 'netfleet-dashboard-link', 'href': controller.dashboardUrl, 'target': '_blank', 'rel': 'noopener' }, '打开面板 ↗'));
		if (dashboard.managed && dashboard.update_available && dashboard.available_version && !dashboard.error && !controller.dashboardError) controls.push(button(dashboard.available ? '更新面板' : '安装面板', function() {
			const version = dashboard.available_version;
			ui.showModal('更新 Zashboard', [ E('p', {}, '目标版本：' + displayVersion(version) + '。只更新面板资源，不重启核心；失败时保留当前面板。'),
				E('div', { 'class': 'right' }, [ button('取消', ui.hideModal), ' ', button('确认更新', function() { ui.hideModal(); return updateDashboard(controller, version); }) ]) ]);
		}, active));
		rows.push(E('tr', {}, [ E('td', {}, [ E('strong', {}, 'Zashboard'), E('small', {}, '查看实时连接、流量与代理组') ]),
			E('td', {}, [ E('strong', {}, dashboard.available ? dashboard.installed_version ? displayVersion(dashboard.installed_version) : '版本未记录' : '未安装'),
				dashboard.available ? E('small', {}, '已安装，可使用') : '', !dashboard.managed ? E('small', {}, errorLabel(dashboard.reason || 'dashboard_managed_externally')) : '' ]),
			E('td', { 'class': 'netfleet-component-actions' }, [ E('div', {}, dashboard.available_version && !dashboard.error && !controller.dashboardError ? dashboard.update_available ? '候选版本 ' + displayVersion(dashboard.available_version) : '当前更新源暂无新版' : '') ].concat(controls)) ]));
	}
	if (section === 'software') content.push(E('div', { 'class': 'netfleet-component-table netfleet-software-table' }, E('table', { 'class': 'table' }, [
		E('thead', {}, E('tr', {}, ['软件', '当前版本', '更新与操作'].map(function(label) { return E('th', {}, label); }))), E('tbody', {}, rows)
	])), E('div', { 'class': 'netfleet-component-checks', 'role': 'status' }, sourceStates));
	if (section === 'plugins') content.push(E('section', { 'class': 'netfleet-component-modules' }, [
		E('p', { 'class': 'netfleet-follow-note' }, '启用表示允许使用；禁用保留软件与配置。安装、更新和卸载独立插件请使用下方的软件包管理。'),
		E('div', { 'class': 'netfleet-component-table netfleet-plugin-table' }, E('table', { 'class': 'table' }, [
			E('thead', {}, E('tr', {}, ['插件', '分类与用途', '版本', '配置', '运行管理'].map(function(label) { return E('th', {}, label); }))), E('tbody', {}, moduleRows.length ? moduleRows : [E('tr', {}, E('td', { 'colspan': 5 }, '当前没有可管理的功能插件'))])
		])),
		pluginPackages(controller, snapshot),
		E('details', { 'class': 'netfleet-component-details' }, [E('summary', {}, '高级：服务组合与实例'),
			E('p', {}, '调整插件启停、服务提供者和实例配置。应用前会校验依赖并展示影响。'),
			button('编辑服务组合', function() { return compositionDialog(controller); }, active)])
	]));
	if (section === 'software') content.push(E('details', { 'class': 'netfleet-component-details' }, [ E('summary', {}, '技术详情：更新源与安装信息'),
		feed.error ? E('p', {}, '软件包源最近错误：' + errorLabel(feed.error)) : '',
		packageFailed ? E('p', {}, '最近组件操作：' + errorLabel(packageOperation.error) + (packageOperation.recovery ? '；' + ({ restored: '已恢复更新前状态', failed: '恢复失败', direct: '已恢复网络直通' })[packageOperation.recovery] : '')) : '',
		dashboardError ? E('p', {}, '面板最近错误：' + (controller.dashboardError ? failure(controller.dashboardError) : errorLabel(dashboard.error))) : '',
		E('dl', { 'class': 'netfleet-component-meta' }, [].concat(
		snapshot.architecture ? [ E('dt', {}, '设备架构'), E('dd', {}, snapshot.architecture) ] : '',
		feed.url ? [ E('dt', {}, '软件包源'), E('dd', {}, feed.url) ] : '',
		dashboard && dashboard.release_url && dashboard.release_url.startsWith('https://github.com/') ? [ E('dt', {}, '面板发行说明'), E('dd', {}, E('a', { 'href': dashboard.release_url, 'target': '_blank', 'rel': 'noopener' }, 'Zashboard 发行说明 ↗')) ] : ''
	)) ]));
	const missing = (snapshot.dependencies || []).filter(function(item) { return !item.available; });
	if (section === 'software' && snapshot.supported && (snapshot.dependencies || []).length) content.push(E('details', { 'open': missing.length ? true : null, 'class': 'netfleet-component-details' }, [ E('summary', { 'class': missing.length ? 'is-warning' : '' }, missing.length ? '缺少 ' + missing.length + ' 项运行依赖' : '运行依赖正常'),
		missing.length ? E('p', {}, '请通过 OpenWrt 软件包管理安装缺少的依赖。') : '',
		E('ul', { 'class': 'netfleet-dependencies' }, (snapshot.dependencies || []).map(function(item) { return E('li', {}, [E('strong', {}, item.label), E('span', { 'class': item.available ? '' : 'is-warning' }, item.available ? item.installed_version || '已安装' : '缺少')]); }))
	]));
	return E('section', { 'class': 'cbi-section netfleet-components' }, content);
}


return baseclass.extend({ components: componentsPage, loadComponents });
