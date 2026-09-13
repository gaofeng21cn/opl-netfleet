/* SPDX-License-Identifier: Apache-2.0 */

'use strict';
'require baseclass';
'require ui';
'require netfleet.managed as managed';
'require netfleet.management as management';
'require netfleet.api as netfleet';
'require netfleet.config as netfleetConfig';
'require netfleet.product as product';
'require poll';

const DISPLAY_CACHE_KEY = 'opl-netfleet:luci-display:v1';
const DISPLAY_CACHE_SCHEMA = 1;

function discardDisplayCache() {
	try {
		window.localStorage.removeItem(DISPLAY_CACHE_KEY);
	}
	catch (error) {}
}

function readDisplayCache() {
	let cached;
	try {
		cached = JSON.parse(window.localStorage.getItem(DISPLAY_CACHE_KEY));
	}
	catch (error) {
		discardDisplayCache();
		return null;
	}
	if (!cached || cached.schema !== DISPLAY_CACHE_SCHEMA || !cached.status || !cached.events ||
		!finite(cached.fetched_at_ms) || Number(cached.fetched_at_ms) <= 0) {
		discardDisplayCache();
		return null;
	}
	return cached;
}

function writeDisplayCache(status, events, fetchedAt, readDurationMs) {
	try {
		const cachedEvents = JSON.parse(JSON.stringify(events || {}));
		cachedEvents.core_lines = [];
		window.localStorage.setItem(DISPLAY_CACHE_KEY, JSON.stringify({
			schema: DISPLAY_CACHE_SCHEMA,
			status: status,
			events: cachedEvents,
			fetched_at_ms: fetchedAt.getTime(),
			read_duration_ms: finite(readDurationMs) ? Number(readDurationMs) : null
		}));
	}
	catch (error) {}
}

function ensureStyles() {
	// Argon dark mode has no semantic colour tokens. Follow the rendered host,
	// including an explicit theme choice that differs from the OS preference.
	const background = getComputedStyle(document.body).backgroundColor.match(/[\d.]+/g);
	if (background && background.length >= 3) {
		const brightness = Number(background[0]) * .2126 + Number(background[1]) * .7152 + Number(background[2]) * .0722;
		document.documentElement.dataset.netfleetTheme = brightness < 128 && background[3] !== '0' ? 'dark' : 'light';
	}
	const href = resourceUrl('native.css');
	let link = document.getElementById('netfleet-native-style');
	if (!link) {
		link = E('link', {
			'id': 'netfleet-native-style',
			'rel': 'stylesheet',
			'type': 'text/css'
		});
		document.head.appendChild(link);
	}
	if (link.getAttribute('href') !== href)
		link.setAttribute('href', href);
}

const { ageLabel, finite, text, pageHeading, dashboardReady, dashboardUnavailableReason, regionalDisplayName, regionName, capabilityName, route, modeName, pathHealthLabel, section, metricGrid, onboardingPage, statusSummary, operatingModeLabel, operatingModeControls, currentRegion, regionChoiceBlocked, overviewPage, exitsPage, providersPage, regionsPage, eventsPage } = productViews;

const productController = {
	load: function() {
		const self = this;
		const onboardingStarted = Date.now();
		return netfleet.onboardingGet().then(function(onboarding) {
			if (onboarding.required)
				return netfleet.nativeSetupGet().catch(function() { return null; }).then(function(setup) {
					return { onboarding: onboarding, nativeSetup: setup, fetchedAt: new Date(), readDurationMs: Date.now() - onboardingStarted, cached: false };
				});
			const cached = readDisplayCache();
			const started = Date.now();
			self.initialRefresh = Promise.all([ netfleet.status(), netfleet.events() ]).then(function(result) {
				return { result: result, readDurationMs: Date.now() - started };
			}, function(error) {
				return { error: error };
			});
			if (cached)
				return {
					status: cached.status,
					events: cached.events,
					fetchedAt: new Date(Number(cached.fetched_at_ms)),
					readDurationMs: cached.read_duration_ms,
					config: null,
					cached: true
				};
			return self.initialRefresh.then(function(refresh) {
				if (refresh.error) throw refresh.error;
				return {
					status: refresh.result[0], events: refresh.result[1], fetchedAt: new Date(),
					readDurationMs: refresh.readDurationMs, config: refresh.result[2], cached: false
				};
			});
		});
	},

	render: function(initial) {
		const self = this;
		this.onboarding = initial.onboarding || null;
		this.nativeSetup = initial.nativeSetup || null;
		this.status = initial.status || null;
		ensureStyles();
		this.events = initial.events || { events: [] };
		this.connections = { connections: [], count: null, truncated: false };
		this.connectionsLoading = false;
		this.connectionsError = null;
		this.config = initial.config;
		this.configDraft = initial.config ? netfleetConfig.clone(initial.config) : null;
		this.configSection = 'foundation';
		this.currentView = this.pageId;
		this.eventPage = 0;
		this.diagnosticSection = 'events';
		this.componentsSection = 'plugins';
		this.fetchedAt = initial.fetchedAt;
		this.readDurationMs = initial.readDurationMs;
		this.liveDataReady = !initial.cached;
		this.refreshing = initial.cached;
		this.refreshError = null;
		this.busy = false;
		this.root = E('div', { 'class': 'netfleet-native' });
		if (!initial.cached && !this.onboarding)
			writeDisplayCache(this.status, this.events, this.fetchedAt, this.readDurationMs);
		this.redraw();
		this.loadManagement();
		if (this.currentView === 'components') managed.loadComponents(this);
		if (initial.cached)
			this.initialRefresh.then(function(refresh) {
				self.refreshing = false;
				if (refresh.error) {
					self.liveDataReady = false;
					self.refreshError = refresh.error;
					managed.notify(null, E('p', {}, '后台读取失败，当前继续显示上次成功数据。'), 'error');
				}
				else {
					self.acceptLiveData(refresh.result, refresh.readDurationMs);
				}
				self.redraw();
			});
		return this.root;
	},

	loadManagement: function() {
		managed.preloadSubscriptions(this).catch(function() {});
		managed.readOperations(this);
		this.loadConfig();
		return this.prepareDashboard();
	},

	loadConfig: function() {
		const self = this;
		self.configError = null;
		return netfleet.configGet().then(function(config) {
			self.config = config;
			if (!self.configDraft) self.configDraft = netfleetConfig.clone(config);
			if (self.currentView === 'config') self.redraw();
		}).catch(function(error) {
			self.configError = error;
			if (self.currentView === 'config') self.redraw();
		});
	},

	prepareDashboard: function() {
		const self = this;
		return netfleet.dashboardGet().then(function(result) {
			if (!result.available || !Number.isInteger(result.port) || result.port < 1 || result.port > 65535 || ![ 'http', 'https' ].includes(result.protocol)) {
				self.dashboardUrl = null;
				return;
			}
			const host = window.location.hostname;
			const url = new URL(result.protocol + '://' + host + ':' + result.port + '/ui/' + (result.ui_name ? encodeURIComponent(result.ui_name) + '/' : ''));
			url.search = new URLSearchParams({ hostname: host, host: host, port: String(result.port), secret: result.secret || '' }).toString();
			// Zashboard only accepts a new connection on setup when a saved backend already exists.
			url.hash = '/setup';
			self.dashboardUrl = url.toString();
		}).catch(function() { self.dashboardUrl = null; }).finally(function() { self.redraw(); });
	},

	acceptLiveData: function(result, readDurationMs) {
		this.status = result[0];
		ensureStyles();
		this.events = result[1];
		this.fetchedAt = new Date();
		this.readDurationMs = readDurationMs;
		this.liveDataReady = true;
		this.refreshError = null;
		this.eventPage = 0;
		if (result[2]) {
			this.config = result[2];
			this.configDraft = netfleetConfig.clone(result[2]);
		}
		writeDisplayCache(this.status, this.events, this.fetchedAt, this.readDurationMs);
	},

	redraw: function() {
		const self = this;
		if (this.context.signal.aborted) return;
		if (this.onboarding && this.onboarding.required) {
			const source = section('数据来源', null, [ metricGrid([
				[ '数据来源', '设备实时 RPC' ], [ '目标', '当前设备' ],
				[ '最后读取', this.fetchedAt.toLocaleString() ], [ '新鲜度', '刚刚更新' ],
				[ '读取耗时', finite(this.readDurationMs) ? String(this.readDurationMs) + ' ms' : '未提供' ],
				[ '设备控制', this.onboarding.ready ? '等待确认' : '只读预检' ]
			], 'is-six') ], 'netfleet-source');
			const buttons = [
				this.nativeSetup && !this.nativeSetup.present && !(this.nativeSetup.missing || []).includes('existing_backend_owner') ? E('button', { 'class': 'btn cbi-button', 'disabled': this.busy || this.context.readOnly || null, 'click': function() { return managed.nativeSetup(self); } }, '首次接入 Mihomo') : E('span'),
				' ',
				E('button', { 'class': 'btn cbi-button', 'disabled': this.busy || null, 'click': function() { return self.manageSubscriptions(); } }, '管理订阅'),
				' ',
				E('button', { 'class': 'btn cbi-button', 'disabled': this.busy || null, 'click': function() { return self.refreshOnboarding(); } }, this.busy ? '正在读取…' : '刷新'),
				' ',
				E('button', { 'class': 'btn cbi-button cbi-button-action', 'disabled': this.busy || !this.onboarding.ready || this.context.readOnly || null, 'click': function() { self.confirmOnboarding(); } }, '按推荐配置开始接管')
			];
			this.root.replaceChildren(E('h2', {}, '首次设置 NetFleet'), source,
				E('div', {}, onboardingPage(this.onboarding, function() { self.showOnboardingDetails(); })),
				E('div', { 'class': 'cbi-page-actions' }, buttons));
			return;
		}
		const title = ({ overview: '网络概览', exits: '出口', providers: '机场', regions: '地区', config: '配置', components: '插件与更新', events: '诊断' })[this.currentView];
		const actions = this.status.actions || {};
		const buttonAttrs = function(attrs, requiresLiveData) {
			if (self.busy || self.refreshing || (requiresLiveData && (!self.liveDataReady || self.context.readOnly)))
				attrs.disabled = true;
			return attrs;
		};
		const buttons = this.currentView === 'components' ? [] : [
			E('button', buttonAttrs({ 'class': 'btn cbi-button', 'click': function() { return self.currentView === 'components' ? managed.loadComponents(self) : self.refreshData(); } }, false), this.busy || this.refreshing ? '正在读取…' : '刷新')
		];
		if ([ 'overview', 'exits', 'regions' ].includes(this.currentView) && actions.can_select_auto === true)
			buttons.push(E('button', buttonAttrs({ 'class': 'btn cbi-button cbi-button-action', 'click': function() { self.confirmAction('select'); } }, true), this.status.selection?.automation_paused ? '恢复自动选优' : '重新选优'));
		if (this.currentView === 'providers' && actions.can_refresh === true)
			buttons.push(E('button', buttonAttrs({ 'class': 'btn cbi-button cbi-button-action', 'click': function() { self.confirmAction('refresh'); } }, true), '立即更新订阅'));

		let content;
		if (this.currentView === 'exits') content = exitsPage(this.status, this);
		else if (this.currentView === 'providers') content = providersPage(this.status, this);
		else if (this.currentView === 'regions') content = regionsPage(this.status, this);
		else if (this.currentView === 'config') content = [ netfleetConfig.render(this) ];
		else if (this.currentView === 'components') content = [ managed.components(this) ];
		else if (this.currentView === 'events') {
			const sections = eventsPage(this.status, this.events, this.connections, this.connectionsLoading, this.connectionsError, this.eventPage, function(page) {
				self.eventPage = page; self.redraw();
			});
			const tabs = E('nav', { 'class': 'netfleet-subtabs', 'aria-label': '诊断分类' }, [['events', '选路记录'], ['website', '网站诊断'], ['core', '核心与日志']].map(function(item) {
				return E('button', { 'type': 'button', 'aria-current': self.diagnosticSection === item[0] ? 'page' : null, 'click': function() {
					if (self.diagnosticSection === item[0]) return;
					self.diagnosticSection = item[0];
					if (item[0] === 'website') self.refreshConnections();
					if (item[0] === 'core') management.load(self, 'maintenance');
					self.redraw();
				} }, item[1]);
			}));
			content = [tabs].concat(this.diagnosticSection === 'website' ? [product.diagnosis(this, regionalDisplayName), sections[2]] :
				this.diagnosticSection === 'core' ? [sections[1], sections[3], management.maintenance(this)] : [sections[0]]);
		}
		else content = overviewPage(this.status, this.events, function(target) {
			self.context.navigate(target);
		});
		if (this.currentView === 'overview') content.splice(2, 0, operatingModeControls(this));
		if (this.currentView !== 'components' && this.currentView !== 'config')
			content.unshift(managed.operationNode(this, 'selection'), managed.operationNode(this, 'subscription'));

		let sourceName = '设备实时 RPC';
		let freshness = '刚刚更新';
		let deviceControl = '可写入';
		if (!this.liveDataReady) {
			sourceName = '上次设备读取';
			freshness = '缓存数据，' + (this.refreshing ? '正在更新（' + ageLabel(this.fetchedAt) + '）' : '刷新失败（' + ageLabel(this.fetchedAt) + '）');
			deviceControl = '等待读取';
		}
		const source = section('数据来源', null, [ metricGrid([
			[ '数据来源', sourceName ], [ '目标', '当前设备' ],
			[ '最后读取', this.fetchedAt.toLocaleString() ], [ '新鲜度', freshness ],
			[ '读取耗时', finite(this.readDurationMs) ? String(this.readDurationMs) + ' ms' : '未提供' ],
			[ '设备控制', deviceControl ]
		], 'is-six') ], 'netfleet-source' + (this.liveDataReady ? '' : ' is-stale'));

		const dashboard = dashboardReady(this.status) && this.dashboardUrl ? E('a', {
			'class': 'netfleet-dashboard-link', 'href': this.dashboardUrl, 'target': '_blank', 'rel': 'noopener',
			'title': '在新标签页打开完整 Zashboard'
		}, 'Zashboard ↗') : E('button', {
			'class': 'netfleet-dashboard-link', 'type': 'button', 'disabled': true,
			'title': dashboardReady(this.status) ? '正在读取连接信息' : dashboardUnavailableReason(this.status)
		}, 'Zashboard ↗');
		this.root.replaceChildren(pageHeading(title, this.status, dashboard), E('div', { 'class': 'netfleet-page-actions' }, buttons), E('div', { 'class': 'netfleet-page-content' }, content), source);
	},

	openDashboard: function() {
		if (!dashboardReady(this.status)) {
			managed.notify(null, E('p', {}, dashboardUnavailableReason(this.status)), 'warning');
			return Promise.resolve();
		}
		if (this.dashboardUrl) {
			window.open(this.dashboardUrl, '_blank', 'noopener');
			return Promise.resolve();
		}
		const self = this;
		return this.prepareDashboard().then(function() {
			managed.notify(null, self.dashboardUrl ? E('a', { 'href': self.dashboardUrl, 'target': '_blank', 'rel': 'noopener' }, '打开 Zashboard') : E('p', {}, '无法打开 Zashboard，请检查核心及控制接口状态。'), self.dashboardUrl ? 'info' : 'error');
		});
	},

	manageSubscriptions: function() { return managed.subscriptions(this); },
	migrateBackend: function() { return managed.migration(this); },

	refreshOnboarding: function() {
		const self = this;
		const started = Date.now();
		this.busy = true;
		this.redraw();
		return Promise.all([ netfleet.onboardingGet(), netfleet.nativeSetupGet().catch(function() { return null; }) ]).then(function(results) {
			const result = results[0];
			self.nativeSetup = results[1];
			if (!result.required) {
				window.location.reload();
				return;
			}
			self.onboarding = result;
			self.fetchedAt = new Date();
			self.readDurationMs = Date.now() - started;
		}).catch(function(error) {
			managed.notify(null, E('p', {}, '首次设置预检失败：' + text(error && error.message, '设备未返回可用结果')), 'error');
		}).finally(function() {
			self.busy = false;
			self.redraw();
		});
	},

	showOnboardingDetails: function() {
		const preview = this.onboarding.preview || {};
		ui.showModal('推荐接管配置', [
			E('p', {}, '正常策略来源与优先恢复目标：' + text(preview.recovery_profile_display_name, '当前原生配置')),
			E('p', {}, '准备接管的主入口组：' + text(preview.entry_group, '尚未识别')),
			E('p', {}, '自动选优默认每 30 分钟执行；机场订阅默认每 12 小时刷新。'),
			E('p', {}, '首次设置不会复制订阅 URL、节点正文、DNS、nft 或路由配置。'),
			E('div', { 'class': 'right' }, E('button', { 'class': 'btn', 'click': ui.hideModal }, '关闭'))
		]);
	},

	confirmOnboarding: function() {
		const self = this;
		const preview = this.onboarding.preview || {};
		ui.showModal('开始接管网络出口', [
			E('p', {}, 'NetFleet 将基于当前配置生成运行配置并切换。设备会先完成编译和网络检查；任一步失败都会恢复 ' + text(preview.recovery_profile_display_name, '当前原生配置') + '。'),
			E('p', {}, '只有原生配置确实无法恢复时，才会停止代理后端并恢复网络直通。'),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, '取消'), ' ',
				E('button', { 'class': 'btn cbi-button-action', 'click': function() { return self.runOnboarding(); } }, '确认接管')
			])
		]);
	},

	runOnboarding: function() {
		const self = this;
		const revision = this.onboarding.revision;
		this.busy = true;
		ui.showModal('首次设置 NetFleet', [ E('p', { 'class': 'spinning' }, '正在编译、切换并等待设备回读…') ]);
		return netfleet.onboardingApply({ revision: revision, confirmed: true }).then(function() {
			discardDisplayCache();
			const started = Date.now();
			return Promise.all([ netfleet.status(), netfleet.events(), netfleet.configGet() ]).then(function(result) {
				self.onboarding = null;
				self.acceptLiveData(result, Date.now() - started);
			});
		}).then(function() {
			ui.hideModal();
			managed.notify(null, E('p', {}, 'NetFleet 已接管，运行状态已从设备重新读取。'), 'info');
		}).catch(function(error) {
			ui.hideModal();
			managed.notify(null, E('p', {}, '接管失败：' + text(error && error.message, '设备未返回成功结果')), 'error');
		}).finally(function() {
			self.busy = false;
			self.redraw();
		});
	},

	refreshConnections: function() {
		const self = this;
		this.connectionsLoading = true;
		this.connectionsError = null;
		this.redraw();
		return netfleet.connections().then(function(result) {
			self.connections = result;
		}).catch(function(error) {
			self.connections = { connections: [], count: 0, truncated: false };
			self.connectionsError = text(error && error.message, '设备未返回当前连接');
		}).finally(function() {
			self.connectionsLoading = false;
			self.redraw();
		});
	},

	refreshData: function(silent, forceConfig) {
		const self = this;
		const started = Date.now();
		this.busy = true;
		this.refreshing = true;
		this.redraw();
		const requests = [ netfleet.status(), netfleet.events() ];
		if (forceConfig)
			requests.push(netfleet.configGet());
		return Promise.all(requests).then(function(result) {
			self.acceptLiveData(result, Date.now() - started);
			self.prepareDashboard();
			if (self.currentView === 'events' && self.diagnosticSection === 'website')
				return self.refreshConnections();
			if (self.currentView === 'events' && self.diagnosticSection === 'core')
				return management.load(self, 'maintenance');
		}).then(function() {
			if (!silent)
				managed.notify(null, E('p', {}, '设备状态已刷新。'), 'info');
		}).catch(function(error) {
			self.liveDataReady = false;
			self.refreshError = error;
			managed.notify(null, E('p', {}, '读取失败：' + text(error && error.message, '设备未返回可用状态')), 'error');
			if (silent)
				throw error;
		}).finally(function() {
			self.busy = false;
			self.refreshing = false;
			self.redraw();
		});
	},

	discardConfig: function() {
		this.configDraft = netfleetConfig.clone(this.config);
		this.redraw();
	},

	currentConfigRequest: function() {
		const self = this;
		return netfleet.configGet().then(function(fresh) {
			if (!self.config || fresh.revision !== self.config.revision) {
				self.config = fresh;
				self.configDraft = netfleetConfig.clone(fresh);
				self.redraw();
				throw new Error('设备配置已经变化，已重新读取；请检查后再操作。');
			}
			return netfleetConfig.request(self.configDraft);
		});
	},

	configFailure: function(error) {
		const details = error && error.detail && error.detail.errors;
		return details && details.length ? details.join('；') : text(error && error.message, '设备未返回可用结果');
	},

	previewConfigChanges: function() {
		const self = this;
		this.busy = true;
		this.redraw();
		return this.currentConfigRequest().then(function(request) {
			return netfleet.configValidate(request);
		}).then(function(result) {
			ui.showModal('配置变更', result.changes.length ? [
				E('ul', { 'class': 'netfleet-change-list' }, result.changes.map(function(change) { return E('li', {}, netfleetConfig.changeText(change, self)); })),
				E('div', { 'class': 'right' }, E('button', { 'class': 'btn', 'click': ui.hideModal }, '关闭'))
			] : [ E('p', {}, '当前没有待处理变更。'), E('div', { 'class': 'right' }, E('button', { 'class': 'btn', 'click': ui.hideModal }, '关闭')) ]);
		}).catch(function(error) {
			managed.notify(null, E('p', {}, '无法生成变更摘要：' + self.configFailure(error)), 'error');
		}).finally(function() {
			self.busy = false;
			self.redraw();
		});
	},

	saveConfig: function() {
		const self = this;
		this.busy = true;
		this.redraw();
		return this.currentConfigRequest().then(function(request) { return netfleet.configSave(request); }).then(function(result) {
			self.config = result.config;
			self.configDraft = netfleetConfig.clone(result.config);
			managed.notify(null, E('p', {}, product.resultText('保存配置', result)), 'info');
		}).catch(function(error) {
			managed.notify(null, E('p', {}, '保存失败：' + self.configFailure(error)), 'error');
		}).finally(function() {
			self.busy = false;
			self.redraw();
		});
	},

	confirmConfigApply: function() {
		const self = this;
		this.busy = true;
		this.redraw();
		return this.currentConfigRequest().then(function(request) {
			return netfleet.configValidate(request).then(function(result) { return { request: request, result: result }; });
		}).then(function(preview) {
			self.busy = false;
			self.redraw();
			const changeSummary = preview.result.changes.length ?
				E('ul', { 'class': 'netfleet-change-list' }, preview.result.changes.map(function(change) { return E('li', {}, netfleetConfig.changeText(change, self)); })) :
				E('p', {}, '没有新的草稿变更；将应用已保存配置并重新读取运行状态。');
			ui.showModal('应用 NetFleet 配置', [
				E('p', {}, '应用会重新生成运行配置并切换网络出口，已有连接可能中断。设备会保留旧配置；失败时尝试恢复，并报告恢复结果。配置未变化且已生效时不重载。'),
				changeSummary,
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'btn', 'click': ui.hideModal }, '取消'), ' ',
					E('button', { 'class': 'btn cbi-button-action', 'click': function() { self.runConfigApply(preview.request); } }, '确认应用')
				])
			]);
		}).catch(function(error) {
			self.busy = false;
			self.redraw();
			managed.notify(null, E('p', {}, '应用前校验失败：' + self.configFailure(error)), 'error');
		});
	},

	runConfigApply: function(request) {
		const self = this;
		this.busy = true;
		ui.showModal('应用 NetFleet 配置', [ E('p', { 'class': 'spinning' }, '正在切换并等待设备回读…') ]);
		return netfleet.configApply(request).then(function(result) {
			ui.hideModal();
			const completed = product.resultText('应用配置', result);
			return self.refreshData(true, true).then(function() {
				managed.notify(null, E('p', {}, completed + (self.refreshError ? '；状态读取失败，请重新读取，不要重复应用。' : '；设备运行状态已重新读取。')), self.refreshError ? 'warning' : 'info');
			}, function() { managed.notify(null, E('p', {}, completed + '；状态读取失败，请重新读取，不要重复应用。'), 'warning'); });
		}).catch(function(error) {
			ui.hideModal();
			managed.notify(null, E('p', {}, '应用失败：' + self.configFailure(error)), 'error');
		}).finally(function() { self.busy = false; self.redraw(); });
	},

	showConfigWizard: function(step) {
		ui.hideModal();
		ui.showModal('首次设置 NetFleet', netfleetConfig.wizard(this, step));
	},

	runMode: async function(mode, expectedMode) {
		if (this.busy || this.refreshing || this.modeSwitching || !this.liveDataReady || this.context.readOnly) return;
		this.modeSwitching = true;
		this.busy = true;
		this.redraw();
		ui.showModal('切换网络运行模式', [ E('p', { 'class': 'spinning' }, '正在切换至' + operatingModeLabel(mode) + '…') ]);
		let failure = null;
		try {
			const inventory = await netfleet.pluginsList();
			const plugin = (inventory.plugins || []).find(function(item) { return item.id === 'activation' && (item.instance || 'default') === 'default'; });
			if (!plugin || !plugin.revision) throw new Error('运行模式插件不可用');
			await netfleet.pluginCall({ id: 'activation', instance: 'default', action: 'set-mode',
				revision: plugin.revision, confirm: true, params: { mode: mode, expected_mode: expectedMode } });
		} catch (error) { failure = error; }
		try { await this.refreshData(true); }
		catch (error) { failure = failure || error; }
		this.modeDraft = null;
		this.modeSwitching = false;
		this.busy = false;
		ui.hideModal();
		this.redraw();
		const confirmed = this.liveDataReady && this.status.operating_mode === mode;
		const actual = this.liveDataReady ? operatingModeLabel(this.status.operating_mode) : '设备状态暂不可读';
		const reason = failure && failure.netfleetKind === 'request_aborted' ? '浏览器连接已中止' : text(failure && failure.message, '设备未确认');
		managed.notify(null, E('p', {}, failure ? '切换未完成：' + reason + '；当前：' + actual :
			confirmed ? '当前：' + actual : '切换结果尚未确认；当前：' + actual), failure || !confirmed ? 'warning' : 'info');
	},

	chooseRegion: function(capabilityId, regionId) {
		const self = this;
		if (regionChoiceBlocked(this, null, regionId)) return;
		const capabilities = (this.status.capabilities || []).filter(function(item) {
			return item.can_select_region && (!regionId || (item.selectable_regions || []).includes(regionId));
		});
		let capability = capabilities.find(function(item) { return item.id === capabilityId; }) || capabilities[0];
		let region = regionId || capability.manual_region_id || capability.region_id;
		const details = E('div');
		const submit = E('button', { 'type': 'button', 'class': 'btn cbi-button-action', 'click': function() {
			if (regionChoiceBlocked(self, capability, region) || !(capability.selectable_regions || []).includes(region)) return;
			return managed.runSelection(self, function() { return netfleet.selectRegion(capability.id, region); }, '切换并保持地区');
		}}, '确认切换');
		function render() {
			const options = capability.selectable_regions || [];
			if (!options.includes(region)) region = options[0];
			details.replaceChildren(
				E('label', { 'class': 'netfleet-choice-field' }, [ E('span', {}, '出口'), E('select', { 'change': function(event) {
					capability = capabilities.find(function(item) { return item.id === event.target.value; }); render();
				}}, capabilities.map(function(item) { return E('option', { 'value': item.id, 'selected': item.id === capability.id ? true : null }, capabilityName(item)); })) ]),
				E('p', { 'class': 'netfleet-selection-note' }, '当前路径：' + route(self.status, capability).join(' → ')),
				E('label', { 'class': 'netfleet-choice-field' }, [ E('span', {}, '保持地区'), E('select', { 'change': function(event) { region = event.target.value; render(); } }, options.map(function(id) {
					return E('option', { 'value': id, 'selected': id === region ? true : null }, regionName(self.status, id));
				})) ]),
				E('p', {}, '仅切换此出口，其他出口保持当前路径。地区内继续自动选择节点；整轮后台自动选优暂停，直到恢复自动选优。重新应用配置或启用时会按策略重新选择。'),
				E('p', {}, '切换后验证业务连通性；验证失败则恢复此前健康选择。')
			);
			submit.disabled = !region || !!regionChoiceBlocked(self, capability, region);
		}
		render();
		ui.showModal('指定地区', [ E('div', { 'class': 'netfleet-native netfleet-region-dialog' }, [details,
			E('div', { 'class': 'right' }, [ E('button', { 'type': 'button', 'class': 'btn', 'click': ui.hideModal }, '取消'), ' ', submit ]) ]) ]);
	},

	confirmAction: function(action) {
		const self = this;
		const copy = {
			select: this.status.selection?.automation_paused ? [ '恢复自动选优', '将解除各自动出口的手动保持，重新测速，并按地区切换门槛恢复整轮自动选优。', '恢复自动选优' ] : [ '重新选优', '将统一测速，再按各出口资格和地区切换门槛选择。当前地区健康时，小幅延迟差异不会导致换区；如需立即改用某地区，请使用“指定地区”。', '开始选优' ],
			refresh: [ '立即更新机场订阅', '将更新当前配置相关的机场；内容未变化时不重载。使用中的内容变化后会重启核心并重新选优，已有连接可能中断；失败的机场保留旧缓存。', '开始更新' ]
			}[action];
		ui.showModal(copy[0], [
			E('p', {}, copy[1]),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, '取消'),
				' ',
				E('button', { 'class': 'btn cbi-button-action', 'click': function() {
					return self.runAction(action);
				} }, copy[2])
			])
		]);
	},

	runAction: function(action) {
		if (action === 'refresh') return managed.runSubscription(this, function() { return netfleet.refresh(); });
		const automaticCapability = this.status.selection && this.status.selection.automatic_capability_id;
		if (action === 'select') return managed.runSelection(this, function() { return netfleet.selectAuto(automaticCapability); });
	},

};

return baseclass.extend({
	mount: async function(context, pageId) {
		const controller = Object.create(productController);
		controller.context = context;
		controller.pageId = pageId;
		context.scope.effect(function() {
			ui.hideModal();
			clearTimeout(controller.operationTimer);
			if (controller.root) controller.root.remove();
			const style = document.getElementById('netfleet-native-style');
			if (style) style.remove();
		});
		const initial = await controller.load();
		if (context.signal.aborted) return;
		context.container.replaceChildren(controller.render(initial));
	}
});
