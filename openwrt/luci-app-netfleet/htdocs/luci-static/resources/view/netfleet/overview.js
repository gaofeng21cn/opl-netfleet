/* SPDX-License-Identifier: MIT */

'use strict';
'require view';
'require ui';
'require netfleet.api as netfleet';
'require netfleet.config as netfleetConfig';

const NAVIGATION = [
	[ 'overview', '概览' ],
	[ 'exits', '出口' ],
	[ 'providers', '机场' ],
	[ 'regions', '地区' ],
	[ 'config', '配置' ],
	[ 'events', '事件与诊断' ]
];

const DISPLAY_CACHE_KEY = 'opl-netfleet:luci-display:v1';
const DISPLAY_CACHE_SCHEMA = 1;
const EVENTS_PAGE_SIZE = 20;

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
		cachedEvents.nikki_lines = [];
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

function ageLabel(value) {
	const ageSeconds = Math.max(0, Math.floor((Date.now() - value.getTime()) / 1000));
	if (ageSeconds < 10)
		return '刚刚';
	if (ageSeconds < 60)
		return String(ageSeconds) + ' 秒前';
	if (ageSeconds < 3600)
		return String(Math.floor(ageSeconds / 60)) + ' 分钟前';
	if (ageSeconds < 86400)
		return String(Math.floor(ageSeconds / 3600)) + ' 小时前';
	return String(Math.floor(ageSeconds / 86400)) + ' 天前';
}

function ensureStyles(status) {
	const build = status && status.build || {};
	const cacheKey = text(build.source_commit, text(build.version, 'unknown'));
	const base = L.resource('netfleet/native.css');
	const href = base + (base.indexOf('?') >= 0 ? '&' : '?') + 'v=' + encodeURIComponent(cacheKey);
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

function finite(value) {
	return value !== null && value !== undefined && Number.isFinite(Number(value));
}

function text(value, fallback) {
	return value !== null && value !== undefined && String(value).trim() ? String(value) : fallback;
}

function buildLabel(status) {
	const build = status && status.build || {};
	const version = text(build.version, null);
	const commit = text(build.source_commit, null);
	if (!version && !commit)
		return '版本未提供';
	return 'NetFleet' + (version ? ' v' + version : '') + (commit ? ' · ' + commit.slice(0, 7) : '');
}

function pageHeading(title, status) {
	return E('div', { 'class': 'netfleet-page-heading' }, [
		E('h2', {}, title),
		E('span', { 'class': 'netfleet-build' }, buildLabel(status))
	]);
}

function delay(value, missing) {
	return finite(value) ? String(Number(value)) + ' ms' : (missing || '未测量');
}

function averageDelay(value, samples) {
	if (!finite(samples))
		return '样本未提供';
	return Number(samples) < 2 ? '样本不足' : delay(value);
}

function countPair(available, total) {
	return finite(available) && finite(total)
		? String(Number(available)) + '/' + String(Number(total))
		: '未提供';
}

function regionalDisplayName(value) {
	const source = text(value, '未提供').trim();
	const chars = Array.from(source);
	if (chars.length < 2)
		return source;
	const first = chars[0].codePointAt(0);
	const second = chars[1].codePointAt(0);
	if (first < 0x1F1E6 || first > 0x1F1FF || second < 0x1F1E6 || second > 0x1F1FF)
		return source;
	const code = String.fromCharCode(65 + first - 0x1F1E6, 65 + second - 0x1F1E6);
	const name = chars.slice(2).join('').trim();
	return name ? code + ' ' + name : code;
}

function byId(items, id) {
	return (items || []).find(function(item) { return item.id === id; });
}

function providerName(status, id) {
	const provider = byId(status.providers, id);
	return text(provider && provider.display_name, text(id, '未提供'));
}

function regionName(status, id) {
	const region = byId(status.regions, id);
	return regionalDisplayName(text(region && region.display_name, text(id, '未提供')));
}

function capabilityName(capability) {
	return text(capability && capability.display_name, text(capability && capability.id, '未提供'));
}

function route(status, capability) {
	if (capability.data_path === 'native_profile')
		return capability.runtime_path || [ capability.base_group || '原生配置' ];
	if (capability.data_path === 'disabled')
		return [ capability.base_group || '原始策略组', '保持原始行为' ];
	if (capability.data_path === 'not_compiled')
		return [ capability.base_group || '原始策略组', '尚未编译' ];
	if (capability.data_path === 'direct_fallback' || capability.data_path === 'direct_manual')
		return [ capability.base_group || '出口', '直连' ];
	if (capability.data_path === 'provider_fallback')
		return [ capability.base_group || '出口', '机场退路', providerName(status, capability.provider_id), text(capability.leaf, '未提供') ];
	if (capability.data_path === 'passthrough')
		return [ '网络直通' ];
	return [
		capability.base_group || '出口',
		regionName(status, capability.region_id),
		providerName(status, capability.provider_id),
		text(capability.leaf, '未提供')
	];
}

function runtimeFallback(capability) {
	const stages = capability.fail_open_stages || [];
	const primary = stages.find(function(stage) { return stage.kind === 'provider_tier' && stage.role !== 'reserve'; });
	const reserve = stages.find(function(stage) { return stage.kind === 'provider_tier' && stage.role === 'reserve'; });
	return [
		'当前优选',
		primary && (primary.provider_ids || []).length ? '主用机场' : '主用机场（未配置）',
		reserve && (reserve.provider_ids || []).length ? '备用机场' : '备用机场（未配置）',
		'直连'
	];
}

function modeName(capability) {
	if (capability.data_path === 'native_profile')
		return 'Nikki 原生';
	const mode = capability.user_mode || capability.mode;
	return ({
		automatic: '自动选优',
		manual_region: '手动保持地区',
		direct: '手动直连',
		manual: '手动选择',
		manual_only: '仅手动'
	})[mode] || text(mode, '未知');
}

function reasonText(status, capability) {
	const reason = capability.reason;
	if (!reason)
		return status.active ? '设备未提供本次选择原因。' : 'NetFleet 未启用，当前使用 Nikki 原生配置。';
	if (reason.kind === 'automatic_decision') {
		const parent = byId(status.capabilities, capability.prefer_region_from);
		let choice = '选择同轮最快合格地区';
		if (reason.decision_reason === 'followed_capability_region')
			choice = '跟随' + (parent ? capabilityName(parent) : '依赖出口') + '的合规地区';
		else if (reason.decision_reason === 'kept_current_region')
			choice = '切换收益不足，保持当前地区';
		return choice + '；' + (reason.changed_region ? '已切换地区' : '保持当前地区') + '；保护探针' + (reason.protected_probes_ok ? '通过' : '未记录') + '。';
	}
	return ({
		provider_fallback: '当前优选不可用，Mihomo 已进入机场退路层。',
		direct_fallback: '代理路径不可用，Mihomo 已切换到直连退路。',
		direct_manual: '用户已选择直连，周期选优暂停。',
		passthrough: 'Nikki 已停止，网络已恢复直通。',
		disabled: '该出口已关闭，原始策略组保持原有行为。',
		not_compiled: '该出口尚未进入当前运行配置。'
	})[reason.kind] || '当前链来自设备状态，页面不会触发额外测速。';
}

function quota(provider) {
	const value = provider.quota || {};
	if (value.state === 'exhausted')
		return '已耗尽';
	if (value.state !== 'available' || !finite(value.remaining_bytes))
		return '未知';
	let amount = Number(value.remaining_bytes);
	const units = [ 'B', 'KiB', 'MiB', 'GiB', 'TiB' ];
	let unit = 0;
	while (amount >= 1024 && unit < units.length - 1) {
		amount /= 1024;
		unit++;
	}
	return (amount >= 100 ? amount.toFixed(0) : amount.toFixed(1)) + ' ' + units[unit];
}

function providerExpiry(provider) {
	if (provider.billing === 'buyout')
		return '不限时间';
	if (provider.billing !== 'subscription')
		return '未提供';
	const value = provider.quota && provider.quota.expires_at;
	return text(value, '未提供').slice(0, 10);
}

function sampledAt(value) {
	return finite(value) && Number(value) > 0 ? new Date(Number(value) * 1000).toLocaleString() : '未提供';
}

function refreshResult(value) {
	return ({
		updated: '更新完成并已重载',
		cache_updated: '缓存已更新',
		partially_updated: '部分机场更新成功',
		unchanged: '订阅无变化',
		update_failed: '更新失败，继续使用旧缓存',
		upstream_unavailable: '上游不可用，未更新',
		active_precondition_failed: '运行状态不满足安全更新条件',
		rollback_restored: '更新失败，已恢复更新前运行状态',
		rollback_failed: '更新与回滚均失败'
	})[value] || (value ? text(value, '未提供') : '尚未执行');
}

function simpleTable(headers, rows, emptyText, extraClass) {
	const body = rows.length ? rows : [ E('tr', {}, [
		E('td', { 'colspan': headers.length }, emptyText || '暂无数据')
	]) ];
	return E('div', { 'class': 'table cbi-section-table' + (extraClass ? ' ' + extraClass : '') }, [
		E('table', { 'class': 'table' }, [
			E('thead', {}, E('tr', {}, headers.map(function(header) { return E('th', {}, header); }))),
			E('tbody', {}, body)
		])
	]);
}

function section(title, description, children, extraClass) {
	const heading = [ E('h3', {}, title) ];
	if (description)
		heading.push(E('div', { 'class': 'cbi-section-descr' }, description));
	return E('div', { 'class': 'cbi-section' + (extraClass ? ' ' + extraClass : '') }, heading.concat(children || []));
}

function metricGrid(items, extraClass) {
	return E('div', { 'class': 'netfleet-metrics' + (extraClass ? ' ' + extraClass : '') }, items.map(function(item) {
		return E('dl', {}, [ E('dt', {}, item[0]), E('dd', {}, item[1]) ]);
	}));
}

function onboardingMessage(code, detail) {
	const messages = {
		current_profile_missing: '请先在 Nikki 选择并验证一个原生配置。',
		netfleet_profile_already_selected: 'Nikki 当前已选择 NetFleet 运行配置，不能重新执行首次接管。',
		current_profile_unreadable: 'Nikki 当前配置无法读取，请先在 Nikki 中修复或重新选择。',
		nikki_disabled: 'Nikki 当前未启用，请先在 Nikki 中启用并确认网络可用。',
		nikki_runtime_unhealthy: 'Nikki 或 Mihomo 当前运行状态异常，请先恢复原生网络。',
		mihomo_controller_unavailable: 'Mihomo 控制接口不可读取，请检查 Nikki 的控制接口和密钥配置。',
		existing_generated_artifacts: '设备存在未受 policy 管理的 NetFleet 生成文件，请先完成恢复或清理。',
		existing_policy_unreadable: '设备已有无法读取的 NetFleet 配置，首次设置不会覆盖它。',
		entry_group_unresolved: '无法唯一识别当前配置的主入口组，请在 Nikki 配置中保留明确的 MATCH 目标。',
		subscription_cache_missing: '没有发现可读取的稳定命名机场订阅缓存。',
		recognized_region_missing: '订阅缓存中没有识别到可用于自动选优的地区节点。',
		generated_policy_invalid: '设备生成的推荐配置未通过校验。',
		revision_unavailable: '无法绑定本次发现结果，请刷新后重试。',
		subscription_has_no_known_region: '未识别到地区节点，首次接管将忽略该机场'
	};
	const base = messages[code] || '设备返回了未识别的首次设置状态：' + text(code, '未知');
	return detail && code === 'subscription_has_no_known_region' ? text(detail, '该机场') + '：' + base : base;
}

function nativeProfileLabel(value) {
	const label = text(value, '当前原生配置');
	return label.endsWith('原生配置') ? label : label + ' 原生配置';
}

function onboardingPage(onboarding, showDetails) {
	const preview = onboarding.preview || {};
	const regions = preview.regions || [];
	const regionNames = {};
	regions.forEach(function(region) { regionNames[region.id] = region.display_name; });
	const providerRows = (preview.providers || []).map(function(provider) {
		return E('tr', {}, [
			E('td', {}, text(provider.display_name, provider.id)),
			E('td', {}, (provider.region_ids || []).map(function(id) { return regionNames[id] || id; }).join('、') || '未识别')
		]);
	});
	const stateClass = onboarding.ready ? 'is-ok' : 'is-warning';
	const blockers = (onboarding.blockers || []).map(function(item) {
		return E('li', {}, onboardingMessage(item.code, item.detail));
	});
	const warnings = (onboarding.warnings || []).map(function(item) {
		return E('li', {}, onboardingMessage(item.code, item.detail));
	});
	const content = [
		section('接管预检', '只读取 Nikki 当前配置和本地订阅缓存，不下载订阅、不修改网络。', [
			metricGrid([
				[ '预检状态', E('span', { 'class': stateClass }, onboarding.ready ? '可以接管' : '暂不能接管') ],
				[ '优先恢复', text(preview.recovery_profile_display_name, '当前原生配置') ],
				[ '主入口组', text(preview.entry_group, '尚未识别') ],
				[ '机场', String((preview.providers || []).length) + ' 个' ],
				[ '地区', String(regions.length) + ' 个' ]
			], 'is-five')
		])
	];
	if (blockers.length)
		content.push(section('需要先处理', '以下条件未满足，NetFleet 不会写入设备。', [ E('ul', { 'class': 'netfleet-onboarding-list is-blocking' }, blockers) ]));
	if (warnings.length)
		content.push(section('发现说明', null, [ E('ul', { 'class': 'netfleet-onboarding-list' }, warnings) ]));
	content.push(section('接管范围', '所有识别到的机场先进入主用层；备用角色、地区范围和自动周期可在接管后调整。', [
		simpleTable([ '机场', '真实可用地区' ], providerRows, '没有可用于首次接管的机场'),
		E('div', { 'class': 'netfleet-inline-actions' }, E('button', { 'class': 'btn cbi-button', 'click': showDetails }, '检查详细配置'))
	]));
	content.push(section('退出与故障恢复', null, [ E('div', { 'class': 'netfleet-recovery' }, [
		E('dl', {}, [ E('dt', {}, '优先恢复'), E('dd', {}, nativeProfileLabel(preview.recovery_profile_display_name)) ]),
		E('dl', {}, [ E('dt', {}, '最终退路'), E('dd', {}, '原生配置恢复失败时，停止 Nikki 并恢复网络直通') ])
	]) ]));
	return content;
}

function detailGrid(items) {
	return E('div', { 'class': 'netfleet-details' }, items.map(function(item) {
		return E('dl', { 'class': item[2] ? 'is-wide' : '' }, [ E('dt', {}, item[0]), E('dd', {}, item[1]) ]);
	}));
}

function statusSummary(status) {
	const supervisor = status.runtime.supervisor || {};
	const lanRuntime = status.runtime.lan_runtime || {};
	const items = [
		[ 'NetFleet', status.active ? '已启用' : status.runtime.netfleet_present ? '待清理' : '已关闭' ],
		[ 'Mihomo', status.runtime.mihomo_running ? '运行中' : '未运行' ],
		[ 'LAN 透明代理', lanRuntime.transparent_proxy_ready ? '可用' : status.active ? '不可用' : '未接管' ],
		[ 'DNS 接管', lanRuntime.dns_ready ? '可用' : status.active ? '不可用' : '未接管' ],
		[ '控制接口', status.runtime.controller_available ? '可读取' : '不可用' ],
		[ 'Dashboard', lanRuntime.dashboard_lan_ready ? 'LAN 可访问' : 'LAN 不可访问' ],
		[ '周期选优', supervisor.running ? (status.selection && status.selection.automation_paused ? '手动暂停' : '运行中') : '未运行' ],
		[ '当前配置', status.active ? 'NetFleet 运行配置' : text(status.recovery_profile_display_name, '当前原生配置') ]
	];
	return section('运行状态', null, [ metricGrid(items) ]);
}

function fastest(items, value) {
	return (items || []).reduce(function(best, item) {
		if (!finite(value(item)))
			return best;
		return !best || Number(value(item)) < Number(value(best)) ? item : best;
	}, null);
}

function joined(values) {
	return values.length ? values.join('、') : '暂无';
}

function currentRegionPlan(status) {
	return (status.regions || []).filter(function(region) {
		return Number(region.available_node_count) > 0 && Number(region.available_provider_count) > 0;
	});
}

function currentRegion(status, capability) {
	if (capability.data_path === 'native_profile')
		return '原生配置';
	if (capability.data_path === 'provider_fallback')
		return '机场退路';
	if (capability.data_path === 'direct_fallback' || capability.data_path === 'direct_manual')
		return '直连';
	return regionName(status, capability.region_id);
}

function currentProvider(status, capability) {
	if (capability.data_path === 'native_profile')
		return text(status.recovery_profile_display_name, '当前原生配置');
	if (capability.data_path === 'direct_fallback' || capability.data_path === 'direct_manual')
		return '不经过机场';
	return providerName(status, capability.provider_id);
}

function overviewLink(label, target, navigate) {
	return E('button', {
		'class': 'btn cbi-button netfleet-summary-link',
		'type': 'button',
		'click': function() { navigate(target); }
	}, label);
}

function overviewExitSummary(status, navigate) {
	const capabilities = (status.capabilities || []).filter(function(capability) { return capability.enabled; });
	const rows = capabilities.map(function(capability) {
		return E('tr', {}, [
			E('td', {}, capabilityName(capability)),
			E('td', {}, currentRegion(status, capability)),
			E('td', {}, currentProvider(status, capability)),
			E('td', {}, delay(capability.reason && capability.reason.delay_ms)),
			E('td', { 'class': capability.alive ? 'is-ok' : 'is-warning' }, capability.alive ? '健康' : '不可用'),
			E('td', {}, modeName(capability))
		]);
	});
	return E('div', { 'class': 'cbi-section netfleet-overview-exits' }, [
		E('div', { 'class': 'netfleet-section-heading' }, [
			E('div', {}, [ E('h3', {}, '出口态势'), E('div', { 'class': 'cbi-section-descr' }, '当前地区、机场和运行状态') ]),
			overviewLink('查看详情', 'exits', navigate)
		]),
		simpleTable([ '出口', '当前地区', '当前机场', '当前延迟', '健康状态', '模式' ], rows, '当前没有已启用出口', 'netfleet-overview-exit-table')
	]);
}

function overviewFact(label, value) {
	return E('div', {}, [ E('dt', {}, label), E('dd', {}, value) ]);
}

function overviewDigest(status, events, navigate) {
	const providers = status.providers || [];
	const availabilityMeasured = Boolean(status.active && status.runtime.netfleet_present && status.runtime.controller_available);
	const availableProviders = providers.filter(function(provider) {
		return availabilityMeasured && Number(provider.available_count) > 0 && Number(provider.available_region_count) > 0;
	});
	const selectedProviders = availabilityMeasured ? providers.filter(function(provider) { return provider.selected; }) : [];
	const fastestProvider = fastest(availableProviders, function(provider) { return provider.last_best_delay_ms ?? provider.best_delay_ms; });
	const fastestAverageProvider = fastest(availableProviders.filter(function(provider) {
		return Number(provider.delay_sample_count) >= 2;
	}), function(provider) { return provider.average_best_delay_ms; });

	const regions = status.regions || [];
	const availableRegions = availabilityMeasured ? currentRegionPlan(status) : [];
	const selectedRegions = availabilityMeasured ? regions.filter(function(region) { return region.selected; }) : [];
	const fastestRegion = fastest(availableRegions, function(region) { return region.last_best_delay_ms; });
	const fastestAverageRegion = fastest(availableRegions.filter(function(region) {
		return Number(region.delay_sample_count) >= 2;
	}), function(region) { return region.average_best_delay_ms; });

	const latest = (events.events || []).reduce(function(current, event) {
		return !current || Number(event.at) > Number(current.at) ? event : current;
	}, null);
	const latestRoute = latest ? [
		displayEventName(events, 'regions', latest.region_id),
		displayEventName(events, 'providers', latest.provider_id),
		latest.leaf
	].filter(function(item) { return item && item !== '全局'; }).join(' / ') : '';

	const providerFacts = [
		overviewFact('当前使用', joined(selectedProviders.map(function(provider) { return providerName(status, provider.id); }))),
		overviewFact('最近最优', fastestProvider ? providerName(status, fastestProvider.id) + ' · ' + delay(fastestProvider.last_best_delay_ms ?? fastestProvider.best_delay_ms) : '未测量'),
		overviewFact('平均最优', fastestAverageProvider ? providerName(status, fastestAverageProvider.id) + ' · ' + averageDelay(fastestAverageProvider.average_best_delay_ms, fastestAverageProvider.delay_sample_count) : '样本不足')
	];
	const regionFacts = [
		overviewFact('当前使用', joined(selectedRegions.map(function(region) { return regionName(status, region.id); }))),
		overviewFact('最近最优', fastestRegion ? regionName(status, fastestRegion.id) + ' · ' + delay(fastestRegion.last_best_delay_ms) : '未测量'),
		overviewFact('平均最优', fastestAverageRegion ? regionName(status, fastestAverageRegion.id) + ' · ' + averageDelay(fastestAverageRegion.average_best_delay_ms, fastestAverageRegion.delay_sample_count) : '样本不足')
	];
	const decision = latest ? [
		E('time', {}, finite(latest.at) ? new Date(Number(latest.at) * 1000).toLocaleString() : '未提供'),
		E('strong', {}, displayEventName(events, 'capabilities', latest.capability)),
		E('p', {}, latestRoute || 'Nikki 原生配置'),
		E('dl', { 'class': 'netfleet-overview-decision-meta' }, [
			overviewFact('延迟', delay(latest.delay_ms)),
			overviewFact('原因', eventReason(status, latest))
		])
	] : [ E('p', { 'class': 'netfleet-overview-empty' }, '暂无决策记录') ];

	const card = function(title, target, count, countDetail, facts, extraClass) {
		return E('article', { 'class': 'netfleet-overview-card' + (extraClass ? ' ' + extraClass : '') }, [
			E('div', { 'class': 'netfleet-overview-card-heading' }, [ E('h3', {}, title), overviewLink('查看', target, navigate) ]),
			E('strong', { 'class': 'netfleet-overview-count' }, [ String(count), E('small', {}, countDetail) ]),
			E('dl', { 'class': 'netfleet-overview-facts' }, facts)
		]);
	};
	const decisionCard = E('article', { 'class': 'netfleet-overview-card netfleet-overview-decision' }, [
		E('div', { 'class': 'netfleet-overview-card-heading' }, [ E('h3', {}, '最近决策'), overviewLink('查看', 'events', navigate) ])
	].concat(decision));

	const unavailableProviders = providers.filter(function(provider) {
		return provider.available_count != null && Number(provider.available_count) === 0 ||
			provider.available_region_count != null && Number(provider.available_region_count) === 0;
	});
	const exhaustedProviders = providers.filter(function(provider) { return provider.quota && provider.quota.state === 'exhausted'; });
	const unavailableSelectedRegions = regions.filter(function(region) {
		return region.selected && region.available_node_count != null && region.available_provider_count != null &&
			(Number(region.available_node_count) === 0 || Number(region.available_provider_count) === 0);
	});
	const lanRuntime = status.runtime.lan_runtime || {};
	const attention = [
		!status.runtime.mihomo_running ? 'Mihomo 未运行' : null,
		!status.runtime.controller_available ? '设备控制接口不可用' : null,
		status.active && !lanRuntime.transparent_proxy_ready ? 'LAN 透明代理不可用' : null,
		status.active && !lanRuntime.dns_ready ? 'DNS 接管不可用' : null,
		availabilityMeasured && unavailableProviders.length ? '不可用机场：' + unavailableProviders.map(function(provider) { return providerName(status, provider.id); }).join('、') : null,
		exhaustedProviders.length ? '流量已耗尽：' + exhaustedProviders.map(function(provider) { return providerName(status, provider.id); }).join('、') : null,
		unavailableSelectedRegions.length ? '当前使用地区已无可用路径：' + unavailableSelectedRegions.map(function(region) { return regionName(status, region.id); }).join('、') : null
	].filter(Boolean);

	const result = [ E('div', { 'class': 'netfleet-overview-digest' }, [
		card('机场态势', 'providers', availabilityMeasured ? availableProviders.length : '未测量', availabilityMeasured ? ' / ' + String(providers.length) + ' 可用' : ' NetFleet 未接管', providerFacts),
		card('地区态势', 'regions', availabilityMeasured ? availableRegions.length : '未测量', availabilityMeasured ? ' 个当前可用' : ' NetFleet 未接管', regionFacts),
		decisionCard
	]) ];
	if (!availabilityMeasured)
		result.push(E('p', { 'class': 'netfleet-overview-empty' }, 'NetFleet 当前未接管，机场和地区的实时可用性未测量。'));
	if (attention.length) {
		result.push(E('div', { 'class': 'alert-message warning netfleet-overview-attention' }, [
			E('strong', {}, '需要关注'),
			E('ul', {}, attention.map(function(item) { return E('li', {}, item); }))
		]));
	}
	return result;
}

function capabilityPanel(status, capability) {
	const businessRoutes = capability.business_routes || [];
	const defaultRoutes = businessRoutes.filter(function(item) { return item.default_route === 'capability'; });
	const optionalRoutes = businessRoutes.filter(function(item) { return item.default_route === 'direct'; });
	const unknownRoutes = businessRoutes.filter(function(item) { return item.default_route !== 'capability' && item.default_route !== 'direct'; });

	function businessList(items) {
		return E('ul', { 'class': 'netfleet-business-list' }, items.map(function(item) {
			return E('li', {}, item.name);
		}));
	}

	const business = [];
	if (defaultRoutes.length) {
		business.push(E('div', { 'class': 'netfleet-business-row is-default' }, [
			E('div', { 'class': 'netfleet-business-label' }, [
				E('strong', {}, '默认走此出口'),
				E('span', {}, '无需手动调整')
			]),
			businessList(defaultRoutes)
		]));
	}
	if (optionalRoutes.length) {
		business.push(E('div', { 'class': 'netfleet-business-row is-optional' }, [
			E('div', { 'class': 'netfleet-business-label' }, [
				E('strong', {}, '可临时切换'),
				E('span', {}, '默认直连，可在 Zashboard 临时切换')
			]),
			businessList(optionalRoutes)
		]));
	}
	if (unknownRoutes.length) {
		business.push(E('div', { 'class': 'netfleet-business-row' }, [
			E('div', { 'class': 'netfleet-business-label' }, [
				E('strong', {}, '可用业务'),
				E('span', {}, '当前设备未提供默认方式')
			]),
			businessList(unknownRoutes)
		]));
	}

	return E('section', { 'class': 'cbi-section netfleet-exit-section' }, [
		E('div', { 'class': 'netfleet-exit-heading' }, [
			E('div', {}, [
				E('h3', {}, capabilityName(capability)),
				E('p', {}, reasonText(status, capability))
			])
		]),
		E('div', { 'class': 'netfleet-exit-current' }, [
			E('dl', { 'class': 'netfleet-current-route' }, [
				E('dt', {}, '当前路径'),
				E('dd', {}, route(status, capability).join(' → '))
			]),
			E('dl', {}, [ E('dt', {}, '当前延迟'), E('dd', {}, delay(capability.reason && capability.reason.delay_ms)) ]),
			E('dl', {}, [
				E('dt', {}, '健康状态'),
				E('dd', { 'class': capability.alive ? 'is-ok' : 'is-warning' }, [
					E('span', { 'class': 'netfleet-health-dot' + (capability.alive ? '' : ' is-bad') }),
					capability.alive ? '健康' : '不可用'
				])
			]),
			E('dl', {}, [ E('dt', {}, '选择方式'), E('dd', {}, modeName(capability)) ])
		]),
		business.length ? E('div', { 'class': 'netfleet-business-routing' }, [
			E('h4', {}, '业务路由')
		].concat(business)) : null,
		E('dl', { 'class': 'netfleet-exit-fallback' }, [
			E('dt', {}, '故障退路'),
			E('dd', {}, runtimeFallback(capability).join(' → '))
		])
	].filter(Boolean));
}

function overviewPage(status, events, navigate) {
	return [ statusSummary(status), overviewExitSummary(status, navigate) ].concat(overviewDigest(status, events, navigate));
}

function seconds(value) {
	if (!finite(value))
		return '未提供';
	if (Number(value) >= 86400 && Number(value) % 86400 === 0)
		return String(Number(value) / 86400) + ' 天';
	if (Number(value) >= 3600 && Number(value) % 3600 === 0)
		return String(Number(value) / 3600) + ' 小时';
	return Number(value) >= 60 && Number(value) % 60 === 0 ? String(Number(value) / 60) + ' 分钟' : String(Number(value)) + ' 秒';
}

function exitsPage(status) {
	const content = [];
	(status.capabilities || []).forEach(function(capability) { content.push(capabilityPanel(status, capability)); });
	const automation = status.selection && status.selection.automation || {};
	content.push(section('运行口径', '全部读取自当前设备策略，不参与前端决策。', [ metricGrid([
		[ '自动选优周期', seconds(automation.selection_interval_seconds) ],
		[ '启动收敛等待', seconds(automation.startup_grace_seconds) ],
		[ '地区切换门槛', delay(status.selection && status.selection.region_switch_margin_ms, '未提供') ],
		[ '节点切换门槛', delay(status.selection && status.selection.leaf_switch_margin_ms, '未提供') ],
		[ '运行失联保护', seconds(automation.runtime_grace_seconds) ]
	], 'is-five') ]));
	const preferred = text(status.recovery_profile_display_name, null);
	content.push(section('退出与故障恢复', '优先恢复与失败条件下的最终退路，不是连续执行步骤。', [
		E('div', { 'class': 'netfleet-recovery' }, [
			E('dl', {}, [ E('dt', {}, '优先恢复'), E('dd', {}, preferred ? preferred + ' 原生配置' : '当前原生配置') ]),
			E('dl', {}, [ E('dt', {}, '最终退路'), E('dd', {}, '原生配置恢复失败时，停止 Nikki 并恢复网络直通') ])
		])
	]));
	return content;
}

function cacheDigest(value) {
	const digest = value && value.cache_sha256;
	if (!digest)
		return value && value.cache_present ? '已缓存' : '无缓存';
	return String(digest).slice(0, 12);
}

function subscriptionExpiry(entry) {
	const value = entry && entry.quota && entry.quota.expires_at;
	return text(value, '未提供').slice(0, 10);
}

function providersPage(status) {
	const refresh = status.subscription_refresh || {};
	const subscriptions = status.subscriptions || refresh.subscriptions || [];
	const availabilityMeasured = Boolean(status.active && status.runtime.netfleet_present && status.runtime.controller_available);
	const providers = (status.providers || []).slice().sort(function(a, b) {
		return Number(Boolean(b.selected)) - Number(Boolean(a.selected)) ||
			(Number(b.available_region_count) || -1) - (Number(a.available_region_count) || -1) ||
			(Number(a.last_best_delay_ms ?? a.best_delay_ms) || Infinity) - (Number(b.last_best_delay_ms ?? b.best_delay_ms) || Infinity) ||
			providerName(status, a.id).localeCompare(providerName(status, b.id), 'zh-CN');
	});
	const rows = providers.map(function(provider) {
		return E('tr', { 'class': provider.selected ? 'cbi-rowstyle-1' : '' }, [
			E('td', {}, providerName(status, provider.id) + (provider.selected ? '（当前使用）' : '')),
			E('td', {}, provider.role === 'reserve' ? '备用' : '主用'),
			E('td', {}, ({ subscription: '订阅制', buyout: '买断制' })[provider.billing] || text(provider.billing, '未知')),
			E('td', {}, availabilityMeasured ? countPair(provider.available_region_count, provider.region_count) : '未测量'),
			E('td', {}, availabilityMeasured ? countPair(provider.available_count, provider.candidate_count) : '未测量'),
				E('td', {}, delay(provider.last_best_delay_ms ?? provider.best_delay_ms)),
				E('td', {}, averageDelay(provider.average_best_delay_ms, provider.delay_sample_count)),
				E('td', {}, finite(provider.delay_sample_count) ? String(Number(provider.delay_sample_count)) : '未提供'),
				E('td', {}, sampledAt(provider.delay_sampled_at)),
				E('td', {}, quota(provider)),
				E('td', {}, providerExpiry(provider))
			]);
		});
	const subscriptionRows = subscriptions.map(function(entry) {
		return E('tr', {}, [
			E('td', {}, text(entry.display_name, entry.section)),
			E('td', {}, text(entry.section, '未提供')),
			E('td', {}, cacheDigest(entry)),
			E('td', {}, sampledAt(entry.last_attempt)),
			E('td', {}, refreshResult(entry.last_result)),
			E('td', {}, quota(entry)),
			E('td', {}, subscriptionExpiry(entry))
		]);
	});
	return [
		section('订阅更新', 'NetFleet 只读发现并调度同一 refresh owner；下载、格式校验和单机场缓存仍由 Nikki 官方更新器负责。', [ metricGrid([
			[ '自动更新', refresh.enabled ? '已启用' : '已关闭' ],
			[ '更新周期', seconds(refresh.interval_seconds) ],
			[ '最近执行', sampledAt(refresh.last_run_at) ],
			[ '最近结果', refreshResult(refresh.last_result) ],
			[ '缓存变化', finite(refresh.last_changed_count) ? String(Number(refresh.last_changed_count)) + ' 个机场' : '未提供' ],
			[ '更新失败', finite(refresh.last_failed_count) ? String(Number(refresh.last_failed_count)) + ' 个机场' : '未提供' ]
		], 'is-six') ]),
		section('订阅缓存', '只显示稳定 section、缓存摘要、配额和最近一次 refresh 结果，不包含 URL、token 或订阅正文。', [
			simpleTable([ '机场', '订阅', '缓存', '最近更新', '结果', '剩余流量', '到期时间' ], subscriptionRows, '当前没有已启用的订阅', 'netfleet-data-table')
		]),
		section('机场', availabilityMeasured ? '运行资格、配额和到期时间来自同一次设备状态读取；历史按稳定机场 ID 持久化，平均最优至少汇总 2 个有效样本。' : 'NetFleet 当前未接管，实时可用性未测量；历史延迟、配额和到期时间仍可查看。', [
			simpleTable([ '机场', '层级', '计费', '可用地区', '候选组', '最近最优', '平均最优', '样本', '最后测量', '剩余流量', '到期时间' ], rows, '设备未提供机场数据', 'netfleet-data-table')
		])
	];
}

function regionsPage(status) {
	const regions = currentRegionPlan(status).sort(function(a, b) {
		return Number(Boolean(b.selected)) - Number(Boolean(a.selected)) ||
			(Number(a.last_best_delay_ms) || Infinity) - (Number(b.last_best_delay_ms) || Infinity) ||
			(Number(a.average_best_delay_ms) || Infinity) - (Number(b.average_best_delay_ms) || Infinity) ||
			(Number(b.available_node_count) || -1) - (Number(a.available_node_count) || -1) ||
			regionName(status, a.id).localeCompare(regionName(status, b.id), 'zh-CN');
	});
	const rows = regions.map(function(region) {
		return E('tr', { 'class': region.selected ? 'cbi-rowstyle-1' : '' }, [
			E('td', {}, regionName(status, region.id) + (region.selected ? '（当前使用）' : '')),
			E('td', {}, countPair(region.available_provider_count, region.provider_count)),
			E('td', {}, countPair(region.available_node_count, region.node_count)),
			E('td', {}, delay(region.last_best_delay_ms)),
			E('td', {}, averageDelay(region.average_best_delay_ms, region.delay_sample_count)),
			E('td', {}, finite(region.delay_sample_count) ? String(Number(region.delay_sample_count)) : '未提供'),
			E('td', {}, sampledAt(region.delay_sampled_at)),
			E('td', {}, ({ automatic: '自动选优', manual: '手动选择', manual_only: '仅手动' })[region.mode] || text(region.mode, '未知'))
		]);
	});
	return [ section('地区', '当前 ' + regions.length + ' 个地区有真实可用路径；历史按稳定地区 ID 持久化，平均最优至少汇总 2 个有效样本。', [
		simpleTable([ '地区', '可用机场', '节点', '最近最优', '平均最优', '样本', '最后测量', '模式' ], rows, '当前没有真实可用路径的地区', 'netfleet-data-table')
	]) ];
}

function displayEventName(events, kind, id) {
	if (!id)
		return '全局';
	const names = events.display_names && events.display_names[kind] || {};
	const value = names[id] || id;
	return kind === 'regions' ? regionalDisplayName(value) : value;
}

function eventReason(status, event) {
	if (event.reason === 'followed_capability_region') {
		const capability = byId(status.capabilities, event.capability);
		const parent = byId(status.capabilities, capability && capability.prefer_region_from);
		return '跟随' + (parent ? capabilityName(parent) : '依赖出口') + '地区';
	}
		return ({
		fastest_eligible: '同轮最快合格候选',
		kept_current_region: '收益不足，保持当前地区',
		current_region_fastest: '当前地区仍为最快',
			native_restored: '已恢复 Nikki 原生配置',
			updated: '订阅更新完成并重载',
			cache_updated: '订阅缓存已更新',
			partially_updated: '部分机场更新成功',
			unchanged: '订阅无变化',
			update_failed: '更新失败，旧缓存保持生效',
			rollback_restored: '已恢复更新前运行状态'
	})[event.reason] || text(event.reason, '未提供');
}

function eventsPage(status, events, connections, connectionsLoading, connectionsError, requestedPage, onPageChange) {
	const orderedEvents = (events.events || []).slice().reverse();
	const pageCount = Math.max(1, Math.ceil(orderedEvents.length / EVENTS_PAGE_SIZE));
	const currentPage = Math.min(Math.max(0, requestedPage || 0), pageCount - 1);
	const eventRows = orderedEvents.slice(currentPage * EVENTS_PAGE_SIZE, (currentPage + 1) * EVENTS_PAGE_SIZE).map(function(event) {
		const action = event.action === 'select'
			? (event.trigger === 'scheduled' ? '定期选优' : '手动选优')
				: ({ enable: '启用', refresh: '更新订阅', disable: '关闭' })[event.action] || text(event.action, '未提供');
		const initiator = ({ luci: 'LuCI', cli: '命令行', deployer: '部署流程', supervisor: '后台选优' })[event.initiator] || text(event.initiator, '未提供');
		const result = [
			displayEventName(events, 'regions', event.region_id),
			displayEventName(events, 'providers', event.provider_id),
			event.leaf
		].filter(function(item) { return item && item !== '全局'; }).join(' / ') || 'Nikki 原生配置';
		return E('tr', {}, [
			E('td', {}, finite(event.at) ? new Date(Number(event.at) * 1000).toLocaleString() : '未提供'),
			E('td', {}, action), E('td', {}, initiator),
			E('td', {}, displayEventName(events, 'capabilities', event.capability)),
			E('td', {}, result), E('td', {}, delay(event.delay_ms, '未记录')),
			E('td', {}, eventReason(status, event))
		]);
	});
	const diagnostics = [
		[ '设备控制接口', status.runtime.controller_available ? '可读取' : '不可用' ],
		[ '事件存储', events.store_valid === false ? '异常' : '有效' ],
		[ '决策事件', String((events.events || []).length) + ' 条' ],
		[ '当前连接', connectionsLoading ? '正在读取' : connectionsError ? '读取失败' : String((connections.connections || []).length) + ' 条' ]
	];
	const logRetention = events.nikki_lines_persistent === false ? '临时窗口' : '设备保留';
	const connectionRows = (connections.connections || []).map(function(connection) {
		const rule = [ connection.rule, connection.rule_payload ].filter(Boolean).join(' / ') || '未提供';
		return E('tr', {}, [
			E('td', {}, connection.destination || '未提供'),
			E('td', {}, finite(connection.destination_port) || typeof connection.destination_port === 'string' ? String(connection.destination_port) : '未提供'),
			E('td', {}, text(connection.network, '未提供').toUpperCase()),
			E('td', {}, rule),
			E('td', {}, (connection.chains || []).join(' → ') || 'DIRECT')
		]);
	});
	const connectionDescription = connectionsError
		? '当前连接读取失败：' + connectionsError
		: connections.truncated ? '仅显示最近读取到的前 50 条活动连接。' : '由 Mihomo 返回当前活动连接的实际命中结果；不会写入展示缓存。';
	const previousAttrs = {
		'class': 'btn cbi-button',
		'click': function() { onPageChange(currentPage - 1); }
	};
	const nextAttrs = {
		'class': 'btn cbi-button',
		'click': function() { onPageChange(currentPage + 1); }
	};
	if (currentPage === 0)
		previousAttrs.disabled = true;
	if (currentPage >= pageCount - 1)
		nextAttrs.disabled = true;
	const pagination = E('div', { 'class': 'cbi-page-actions netfleet-event-pagination' }, [
		E('span', {}, '第 ' + String(currentPage + 1) + ' / ' + String(pageCount) + ' 页，共 ' + String(orderedEvents.length) + ' 条'),
		' ',
		E('button', previousAttrs, '上一页'),
		' ',
		E('button', nextAttrs, '下一页')
	]);
	const eventContent = [ simpleTable([ '时间', '操作', '来源', '出口', '结果', '延迟', '原因' ], eventRows, '暂无决策事件') ];
	if (orderedEvents.length > EVENTS_PAGE_SIZE)
		eventContent.push(pagination);
	const connectionContent = E('details', { 'class': 'netfleet-connection-details' }, [
		E('summary', {}, connectionsLoading ? '正在读取当前活动连接…' : '展开当前活动连接快照'),
		E('p', { 'class': 'netfleet-connection-note' }, connectionDescription + ' 详细规则命中链、连接流量和实时代理组观察请使用 Zashboard；NetFleet 不把瞬时连接快照累计为持久化统计。'),
		simpleTable([ '目标', '端口', '网络', '命中规则 / 规则集', '实际链路' ], connectionRows, connectionsLoading ? '正在读取当前活动连接…' : '当前没有活动连接', 'netfleet-connection-table')
	]);
	return [
		section('选路事件', '只展示设备已确认完成的事件。', eventContent),
		section('诊断状态', null, [
			metricGrid(diagnostics),
			E('div', { 'class': 'netfleet-diagnostic-note' }, [
				E('strong', {}, '原始日志：' + logRetention),
				E('span', {}, events.nikki_lines_persistent === false ? '仅展示 Nikki 当前保留的最近日志，不作为持久事件记录。' : '由设备日志策略负责保留。')
			])
		]),
		section('当前活动连接', '辅助诊断快照，不代表完整的 Mihomo 观察面。', [ connectionContent ]),
		section('Mihomo 原始日志', null, [ E('pre', {}, (events.nikki_lines || []).join('\n') || '暂无相关原始日志。') ])
	];
}

return view.extend({
	load: function() {
		const self = this;
		const onboardingStarted = Date.now();
		return netfleet.onboardingGet().then(function(onboarding) {
			if (onboarding.required)
				return { onboarding: onboarding, fetchedAt: new Date(), readDurationMs: Date.now() - onboardingStarted, cached: false };
			const cached = readDisplayCache();
			const started = Date.now();
			self.initialRefresh = Promise.all([ netfleet.status(), netfleet.events(), netfleet.configGet() ]).then(function(result) {
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
		this.status = initial.status || null;
		ensureStyles(this.status);
		this.events = initial.events || { events: [] };
		this.connections = { connections: [], count: 0, truncated: false };
		this.connectionsLoading = false;
		this.connectionsError = null;
		this.config = initial.config;
		this.configDraft = initial.config ? netfleetConfig.clone(initial.config) : null;
		this.configSection = 'foundation';
		this.currentView = 'overview';
		this.eventPage = 0;
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
		if (initial.cached)
			this.initialRefresh.then(function(refresh) {
				self.refreshing = false;
				if (refresh.error) {
					self.liveDataReady = false;
					self.refreshError = refresh.error;
					ui.addNotification(null, E('p', {}, '后台读取失败，当前继续显示上次成功数据。'), 'error');
				}
				else {
					self.acceptLiveData(refresh.result, refresh.readDurationMs);
				}
				self.redraw();
			});
		return this.root;
	},

	acceptLiveData: function(result, readDurationMs) {
		this.status = result[0];
		ensureStyles(this.status);
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
		if (this.onboarding && this.onboarding.required) {
			const source = section('数据来源', null, [ metricGrid([
				[ '数据来源', '设备实时 RPC' ], [ '目标', '当前设备' ],
				[ '最后读取', this.fetchedAt.toLocaleString() ], [ '新鲜度', '刚刚更新' ],
				[ '读取耗时', finite(this.readDurationMs) ? String(this.readDurationMs) + ' ms' : '未提供' ],
				[ '设备控制', this.onboarding.ready ? '等待确认' : '只读预检' ]
			], 'is-six') ], 'netfleet-source');
			const buttons = [
				E('button', { 'class': 'btn cbi-button', 'disabled': this.busy || null, 'click': function() { return self.refreshOnboarding(); } }, this.busy ? '正在读取…' : '刷新'),
				' ',
				E('button', { 'class': 'btn cbi-button cbi-button-action', 'disabled': this.busy || !this.onboarding.ready || null, 'click': function() { self.confirmOnboarding(); } }, '按推荐配置开始接管')
			];
			this.root.replaceChildren(E('h2', {}, '首次设置 NetFleet'), source,
				E('div', {}, onboardingPage(this.onboarding, function() { self.showOnboardingDetails(); })),
				E('div', { 'class': 'cbi-page-actions' }, buttons));
			return;
		}
		const title = ({ overview: '网络概览', exits: '出口', providers: '机场', regions: '地区', config: '配置', events: '事件与诊断' })[this.currentView];
		const tabs = E('ul', { 'class': 'cbi-tabmenu' }, NAVIGATION.map(function(item) {
			return E('li', { 'class': self.currentView === item[0] ? 'cbi-tab' : 'cbi-tab-disabled' }, [
				E('a', { 'href': '#', 'click': function(event) {
					event.preventDefault();
					self.currentView = item[0];
					if (item[0] === 'events')
						self.refreshConnections();
					else
						self.redraw();
				} }, item[1])
			]);
		}));

		const actions = this.status.actions || {};
		const buttonAttrs = function(attrs, requiresLiveData) {
			if (self.busy || self.refreshing || (requiresLiveData && !self.liveDataReady))
				attrs.disabled = true;
			return attrs;
		};
		const buttons = [
			E('button', buttonAttrs({ 'class': 'btn cbi-button', 'click': function() { return self.refreshData(); } }, false), this.busy || this.refreshing ? '正在读取…' : '刷新')
		];
		if (this.currentView !== 'config' && actions.can_enable === true)
			buttons.push(E('button', buttonAttrs({ 'class': 'btn cbi-button cbi-button-action', 'click': function() { self.confirmAction('enable'); } }, true), '启用 NetFleet'));
		if (this.currentView !== 'config' && actions.can_select_auto === true)
			buttons.push(E('button', buttonAttrs({ 'class': 'btn cbi-button cbi-button-action', 'click': function() { self.confirmAction('select'); } }, true), '重新选优'));
		if (this.currentView !== 'config' && actions.can_refresh === true)
			buttons.push(E('button', buttonAttrs({ 'class': 'btn cbi-button cbi-button-action', 'click': function() { self.confirmAction('refresh'); } }, true), '立即更新订阅'));
		if (this.currentView !== 'config' && actions.can_disable === true)
			buttons.push(E('button', buttonAttrs({ 'class': 'btn cbi-button cbi-button-negative', 'click': function() { self.confirmAction('disable'); } }, true), '关闭 NetFleet'));

		let content;
		if (this.currentView === 'exits') content = exitsPage(this.status);
		else if (this.currentView === 'providers') content = providersPage(this.status);
		else if (this.currentView === 'regions') content = regionsPage(this.status);
		else if (this.currentView === 'config') content = [ netfleetConfig.render(this) ];
		else if (this.currentView === 'events') content = eventsPage(this.status, this.events, this.connections, this.connectionsLoading, this.connectionsError, this.eventPage, function(page) {
			self.eventPage = page;
			self.redraw();
		});
		else content = overviewPage(this.status, this.events, function(target) {
			self.currentView = target;
			self.redraw();
		});

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

		this.root.replaceChildren(pageHeading(title, this.status), tabs, E('div', {}, content), source, E('div', { 'class': 'cbi-page-actions' }, buttons));
	},

	refreshOnboarding: function() {
		const self = this;
		const started = Date.now();
		this.busy = true;
		this.redraw();
		return netfleet.onboardingGet().then(function(result) {
			if (!result.required) {
				window.location.reload();
				return;
			}
			self.onboarding = result;
			self.fetchedAt = new Date();
			self.readDurationMs = Date.now() - started;
		}).catch(function(error) {
			ui.addNotification(null, E('p', {}, '首次设置预检失败：' + text(error && error.message, '设备未返回可用结果')), 'error');
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
			E('p', {}, '自动选优默认每 30 分钟执行；机场订阅默认每 12 小时由 Nikki 官方更新器刷新。'),
			E('p', {}, '首次设置不会复制订阅 URL、节点正文、DNS、nft 或路由配置。'),
			E('div', { 'class': 'right' }, E('button', { 'class': 'btn', 'click': ui.hideModal }, '关闭'))
		]);
	},

	confirmOnboarding: function() {
		const self = this;
		const preview = this.onboarding.preview || {};
		ui.showModal('开始接管网络出口', [
			E('p', {}, 'NetFleet 将基于当前 Nikki 配置生成运行配置并切换 Profile。设备会先完成编译和网络检查；任一步失败都会恢复 ' + text(preview.recovery_profile_display_name, '当前原生配置') + '。'),
			E('p', {}, '这不是连续执行的退路链：只有原生配置确实无法恢复时，才会停止 Nikki 并恢复网络直通。'),
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
			ui.addNotification(null, E('p', {}, 'NetFleet 已接管，运行状态已从设备重新读取。'), 'info');
		}).catch(function(error) {
			ui.hideModal();
			ui.addNotification(null, E('p', {}, '接管失败：' + text(error && error.message, '设备未返回成功结果')), 'error');
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
		if (forceConfig || !this.configDraft || !netfleetConfig.dirty(this))
			requests.push(netfleet.configGet());
		return Promise.all(requests).then(function(result) {
			self.acceptLiveData(result, Date.now() - started);
			if (self.currentView === 'events')
				return self.refreshConnections();
		}).then(function() {
			if (!silent)
				ui.addNotification(null, E('p', {}, '设备状态已刷新。'), 'info');
		}).catch(function(error) {
			self.liveDataReady = false;
			self.refreshError = error;
			ui.addNotification(null, E('p', {}, '读取失败：' + text(error && error.message, '设备未返回可用状态')), 'error');
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

	validateConfig: function() {
		const self = this;
		this.busy = true;
		this.redraw();
		return this.currentConfigRequest().then(function(request) {
			return netfleet.configValidate(request);
		}).then(function(result) {
			ui.addNotification(null, E('p', {}, result.change_count ? '配置校验通过，共 ' + String(result.change_count) + ' 项变更。' : '配置校验通过，没有待处理变更。'), 'info');
		}).catch(function(error) {
			ui.addNotification(null, E('p', {}, '配置校验失败：' + self.configFailure(error)), 'error');
		}).finally(function() {
			self.busy = false;
			self.redraw();
		});
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
			ui.addNotification(null, E('p', {}, '无法生成变更摘要：' + self.configFailure(error)), 'error');
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
			ui.addNotification(null, E('p', {}, '配置已保存；当前网络数据面没有变化。'), 'info');
		}).catch(function(error) {
			ui.addNotification(null, E('p', {}, '保存失败：' + self.configFailure(error)), 'error');
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
				E('p', {}, '设备将先保存旧配置和运行字节，再复用现有退出、编译和启用流程完成切换；任何一步失败都会恢复上一份配置。'),
				changeSummary,
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'btn', 'click': ui.hideModal }, '取消'), ' ',
					E('button', { 'class': 'btn cbi-button-action', 'click': function() { self.runConfigApply(preview.request); } }, '确认应用')
				])
			]);
		}).catch(function(error) {
			self.busy = false;
			self.redraw();
			ui.addNotification(null, E('p', {}, '应用前校验失败：' + self.configFailure(error)), 'error');
		});
	},

	runConfigApply: function(request) {
		const self = this;
		this.busy = true;
		ui.showModal('应用 NetFleet 配置', [ E('p', { 'class': 'spinning' }, '正在切换并等待设备回读…') ]);
		return netfleet.configApply(request).then(function() {
			return self.refreshData(true, true);
		}).then(function() {
			ui.hideModal();
			ui.addNotification(null, E('p', {}, '配置已应用，设备运行状态已重新读取。'), 'info');
		}).catch(function(error) {
			ui.hideModal();
			ui.addNotification(null, E('p', {}, '应用失败：' + self.configFailure(error)), 'error');
			self.busy = false;
			self.redraw();
		});
	},

	showConfigWizard: function(step) {
		ui.hideModal();
		ui.showModal('首次设置 NetFleet', netfleetConfig.wizard(this, step));
	},

	confirmAction: function(action) {
		const self = this;
		const copy = {
			enable: [ '启用 NetFleet', '将按当前设备策略生成运行配置，并在网络检查和设备状态确认通过后接管网络出口。', '确认启用' ],
			select: [ '重新自动选优', '将按依赖顺序执行一轮有界测速和原子选择，并恢复后台周期选优。', '开始选优' ],
			refresh: [ '立即更新机场订阅', '将逐个调用 Nikki 官方更新器；失败的机场继续使用旧缓存，发生变化时才重载并重新选优。', '开始更新' ],
			disable: [ '关闭 NetFleet', '将优先恢复原生配置；只有原生配置无法恢复时，才停止 Nikki 并恢复网络直通。', '确认关闭' ]
			}[action];
		ui.showModal(copy[0], [
			E('p', {}, copy[1]),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, '取消'),
				' ',
				E('button', { 'class': action === 'disable' ? 'btn cbi-button-negative' : 'btn cbi-button-action', 'click': function() {
					return self.runAction(action);
				} }, copy[2])
			])
		]);
	},

	runAction: function(action) {
		const self = this;
		const automaticCapability = this.status.selection && this.status.selection.automatic_capability_id;
		let request;
			if (action === 'enable') request = netfleet.enable();
			else if (action === 'select') request = netfleet.selectAuto(automaticCapability);
			else if (action === 'refresh') request = netfleet.refresh();
			else request = netfleet.disable();
		ui.showModal('NetFleet', [ E('p', { 'class': 'spinning' }, '正在执行并等待设备确认…') ]);
		this.busy = true;
		return request.then(function() {
			return self.refreshData(true);
		}).then(function() {
			ui.hideModal();
				ui.addNotification(null, E('p', {}, ({ enable: 'NetFleet 已启用。', select: '自动选优已完成。', refresh: '机场订阅更新已完成。', disable: 'NetFleet 已关闭。' })[action]), 'info');
		}).catch(function(error) {
			ui.hideModal();
			ui.addNotification(null, E('p', {}, '操作失败：' + text(error && error.message, '设备未返回成功结果')), 'error');
			self.busy = false;
			self.redraw();
		});
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
