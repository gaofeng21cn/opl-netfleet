/* SPDX-License-Identifier: Apache-2.0 */
'use strict';
'require baseclass';
'require ui';
'require netfleet.managed as managed';

const EVENTS_PAGE_SIZE = 20;

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

function finite(value) {
	return value !== null && value !== undefined && Number.isFinite(Number(value));
}

function text(value, fallback) {
	return value !== null && value !== undefined && String(value).trim() ? String(value) : fallback;
}

function pageHeading(title, status, dashboard, actions) {
	return E('div', { 'class': 'netfleet-page-heading' }, [
		E('h2', {}, title),
		E('div', { 'class': 'netfleet-page-tools' }, [ ...(actions || []), dashboard ])
	]);
}

function delay(value, missing) {
	return finite(value) ? String(Number(value)) + ' ms' : (missing || '未测量');
}

function averageDelay(value, samples) {
	if (!finite(samples))
		return '统计暂不可读';
	return Number(samples) === 0 ? '暂无有效测量' : Number(samples) < 2 ? '仅 1 次测量' : delay(value);
}

function countPair(available, total) {
	return finite(available) && finite(total)
		? String(Number(available)) + '/' + String(Number(total))
		: '未提供';
}

function dashboardReady(status) {
	const runtime = status && status.runtime || {};
	const lan = runtime.lan_runtime || {};
	return runtime.mihomo_running === true && runtime.controller_available === true && lan.dashboard_lan_ready === true;
}

function dashboardUnavailableReason(status) {
	const runtime = status && status.runtime || {};
	const lan = runtime.lan_runtime || {};
	if (runtime.mihomo_running !== true)
		return 'Mihomo 当前未运行';
	if (runtime.controller_available !== true)
		return 'Mihomo 控制接口当前不可读取';
	if (lan.dashboard_lan_ready !== true)
		return 'Zashboard 的局域网访问条件尚未就绪';
	return 'Zashboard 当前不可用';
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
	if (capability.data_path === 'passthrough') return '原生直连';
	if (capability.data_path === 'native_profile')
		return '原生配置';
	const mode = capability.user_mode || capability.mode;
	return ({
		automatic: '自动选优',
		manual_region: '手动保持地区',
		direct: '手动直连',
		manual: '手动选择',
		manual_only: '仅手动'
	})[mode] || text(mode, '未知');
}

function pathHealthLabel(capability) {
	if (capability.data_path === 'passthrough') return capability.alive ? '已直连' : '状态未确认';
	return capability.alive ? '健康' : '不可用';
}

function reasonText(status, capability) {
	const reason = capability.reason;
	if (!reason)
		return status.active ? '设备未提供本次选择原因。' : 'NetFleet 未启用，当前使用 原生配置。';
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
		passthrough: '代理后端已停止，网络已恢复直通。',
		disabled: '该出口已关闭，原始策略组保持原有行为。',
		not_compiled: '该出口尚未进入当前运行配置。'
	})[reason.kind] || '当前链来自设备状态，页面不会触发额外测速。';
}

function quota(provider) {
	const value = provider.quota || {};
	if (value.state === 'exhausted')
		return '已耗尽';
	if (value.state !== 'available' || !finite(value.remaining_bytes))
		return '机场未返回用量';
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
		return '计费方式未确认';
	const value = provider.quota && provider.quota.expires_at;
	return value ? String(value).slice(0, 10) : '机场未返回到期时间';
}

function sampledAt(value) {
	return finite(value) && Number(value) > 0 ? new Date(Number(value) * 1000).toLocaleString() : '暂无有效测量';
}

function executionAt(value) {
	return finite(value) && Number(value) > 0 ? sampledAt(value) : '尚未执行';
}

function refreshResult(value) {
	return ({
		updated: '更新完成并已重载',
		cache_updated: '缓存已更新',
		partially_updated: '部分机场更新成功',
		unchanged: '订阅无变化',
		failed: '更新失败，继续使用旧版本',
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
		current_profile_missing: '尚未选择可用的原生配置，请先完成后端接入。',
		netfleet_profile_already_selected: '当前已选择 NetFleet 运行配置，不能重新执行首次接管。',
		current_profile_unreadable: '当前配置无法读取，请先修复或重新选择。',
		backend_disabled: '运行后端当前未启用，请先启用并确认网络可用。',
		backend_runtime_unhealthy: '运行后端或 Mihomo 当前状态异常，请先恢复网络。',
		native_sources_missing: '请先添加机场订阅。',
		mihomo_controller_unavailable: 'Mihomo 控制接口不可读取，请检查控制接口和密钥配置。',
		existing_generated_artifacts: '设备存在未受 policy 管理的 NetFleet 生成文件，请先完成恢复或清理。',
		existing_policy_unreadable: '设备已有无法读取的 NetFleet 配置，首次设置不会覆盖它。',
		entry_group_unresolved: '无法唯一识别当前配置的主入口组，请在原生配置中保留明确的默认出口。',
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

function backendName(status) {
	return text(status && status.runtime && status.runtime.backend && status.runtime.backend.display_name, '当前代理后端');
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
		section('接管预检', '读取当前配置和本地订阅缓存，不修改网络。', [
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
		E('dl', {}, [ E('dt', {}, '最终退路'), E('dd', {}, '原生配置恢复失败时，停止代理后端并恢复网络直通') ])
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
		[ '运行模式', operatingModeLabel(status.operating_mode) ],
		[ 'Mihomo', status.runtime.mihomo_running ? '运行中' : '未运行' ],
		[ 'LAN 透明代理', lanRuntime.transparent_proxy_ready ? '可用' : status.active ? '不可用' : '未接管' ],
		[ 'DNS 接管', lanRuntime.dns_ready ? '可用' : status.active ? '不可用' : '未接管' ],
		[ '控制接口', status.runtime.controller_available ? '可读取' : '不可用' ],
		[ 'Dashboard', lanRuntime.dashboard_lan_ready ? 'LAN 可访问' : 'LAN 不可访问' ],
		[ '周期选优', supervisor.running ? (status.selection && status.selection.automation_paused ? '手动暂停' : '运行中') : '未运行' ],
		[ '当前配置', status.active ? 'NetFleet 运行配置' : text(status.recovery_profile_display_name, '当前原生配置') ]
	];
	return E('div', { 'class': 'netfleet-status-line', 'aria-label': '运行状态' }, items.map(function(item) {
		return E('span', {}, [ E('span', {}, item[0]), E('strong', {}, item[1]) ]);
	}));
}

const OPERATING_MODES = { openwrt: 'OpenWrt 原生直连', mihomo: 'Mihomo 原生代理', netfleet: 'NetFleet 增强代理' };

function operatingModeLabel(mode) {
	return OPERATING_MODES[mode] || '状态未确认';
}

function operatingModeControls(owner) {
	const current = owner.status.operating_mode ?? null;
	const selected = owner.modeDraft ?? current;
	const disabled = owner.busy || owner.refreshing || owner.modeSwitching || !owner.liveDataReady || owner.context.readOnly;
	const descriptions = {
		openwrt: '停止代理与网络接管，使用 OpenWrt 原生网络。',
		mihomo: '保留 Mihomo 代理，暂停 NetFleet 自动选优与调度。',
		netfleet: '运行代理、自动选优与故障恢复，由 NetFleet 统一管理。'
	};
	return E('details', { 'class': 'netfleet-operating-mode', 'aria-label': '网络运行模式', 'open': owner.modeExpanded || owner.modeSwitching || null, 'toggle': function(event) { owner.modeExpanded = event.currentTarget.open; } }, [
		E('summary', {}, [ E('strong', {}, '网络运行模式 · ' + operatingModeLabel(current)), E('span', { 'class': 'netfleet-inline-link' }, '切换运行模式') ]),
		E('fieldset', { 'disabled': disabled || null }, [
			E('legend', { 'class': 'netfleet-mode-legend' }, '选择运行模式'),
			E('div', { 'class': 'netfleet-mode-options' }, Object.keys(OPERATING_MODES).map(function(mode) {
				return E('label', { 'class': 'netfleet-mode-option' + (mode === selected ? ' is-selected' : '') }, [
					E('input', { 'type': 'radio', 'name': 'netfleet-operating-mode', 'value': mode, 'checked': mode === selected || null,
						'change': function() { owner.modeDraft = mode; owner.redraw(); } }),
					E('span', { 'class': 'netfleet-mode-copy' }, [ E('strong', {}, OPERATING_MODES[mode]),
						E('span', { 'class': 'netfleet-mode-description' }, descriptions[mode]),
						mode === current ? E('span', { 'class': 'netfleet-mode-current' }, '当前运行') : E('span', { 'aria-hidden': 'true' }, '') ])
				]);
			})),
			E('div', { 'class': 'netfleet-mode-footer' }, [
				E('span', { 'role': 'status' }, owner.modeSwitching ? '正在应用，请稍候…' : selected && selected !== current ? '待切换至' + operatingModeLabel(selected) : current ? '当前模式已生效' : '当前运行模式暂不可确认'),
				E('button', { 'type': 'button', 'class': 'btn cbi-button cbi-button-action', 'disabled': disabled || !selected || selected === current || null,
					'click': function() { return owner.runMode(selected, current); } }, owner.modeSwitching ? '正在切换…' : '切换模式')
			])
		])
	]);
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
		// Node inventory is an optional diagnostic projection.  A region is
		// usable when at least one measured candidate group and provider are
		// available; an unknown node inventory must not hide a real route.
		return Number(region.available_count) > 0 && Number(region.available_provider_count) > 0;
	});
}

function currentRegion(status, capability) {
	if (capability.data_path === 'passthrough') return '直连';
	if (capability.data_path === 'native_profile')
		return '原生配置';
	if (capability.data_path === 'provider_fallback')
		return '机场退路';
	if (capability.data_path === 'direct_fallback' || capability.data_path === 'direct_manual')
		return '直连';
	return regionName(status, capability.region_id);
}

function currentProvider(status, capability) {
	if (capability.data_path === 'passthrough') return '不经过机场';
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
			E('td', {}, E('button', { 'class': 'netfleet-name-link', 'type': 'button', 'click': function() { navigate('exits'); } }, capabilityName(capability))),
			E('td', {}, currentRegion(status, capability)),
			E('td', {}, currentProvider(status, capability)),
			E('td', {}, delay(capability.reason && capability.reason.delay_ms)),
			E('td', { 'class': capability.alive ? 'is-ok' : 'is-warning' }, pathHealthLabel(capability)),
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

	const latest = latestDecision(events.events || []);

	const providerFacts = [
		overviewFact('当前使用', joined(selectedProviders.map(function(provider) { return providerName(status, provider.id); }))),
		overviewFact('最近测量最快', fastestProvider ? providerName(status, fastestProvider.id) + ' · ' + delay(fastestProvider.last_best_delay_ms ?? fastestProvider.best_delay_ms) : '未测量'),
		overviewFact('历史平均最低', fastestAverageProvider ? providerName(status, fastestAverageProvider.id) + ' · ' + averageDelay(fastestAverageProvider.average_best_delay_ms, fastestAverageProvider.delay_sample_count) : '样本不足')
	];
	const regionFacts = [
		overviewFact('当前使用', joined(selectedRegions.map(function(region) { return regionName(status, region.id); }))),
		overviewFact('最近测量最快', fastestRegion ? regionName(status, fastestRegion.id) + ' · ' + delay(fastestRegion.last_best_delay_ms) : '未测量'),
		overviewFact('历史平均最低', fastestAverageRegion ? regionName(status, fastestAverageRegion.id) + ' · ' + averageDelay(fastestAverageRegion.average_best_delay_ms, fastestAverageRegion.delay_sample_count) : '样本不足')
	];
	const decision = latest ? [
		E('time', {}, finite(latest.at) ? new Date(Number(latest.at) * 1000).toLocaleString() : '未提供'),
		E('strong', {}, displayEventName(events, 'capabilities', latest.capability)),
		E('p', {}, eventResult(events, latest)),
		E('dl', { 'class': 'netfleet-overview-decision-meta' }, [
			overviewFact('延迟', eventDelay(latest)),
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
		return provider.quota && provider.quota.state === 'exhausted' ? false :
			provider.available_count != null && Number(provider.available_count) === 0 ||
			provider.available_region_count != null && Number(provider.available_region_count) === 0;
	});
	const exhaustedProviders = providers.filter(function(provider) { return provider.quota && provider.quota.state === 'exhausted'; });
	const unavailableSelectedRegions = regions.filter(function(region) {
		return region.selected && region.available_count != null && region.available_provider_count != null &&
			(Number(region.available_count) === 0 || Number(region.available_provider_count) === 0);
	});
	const lanRuntime = status.runtime.lan_runtime || {};
	const attention = [
		status.operating_mode !== 'openwrt' && !status.runtime.mihomo_running ? 'Mihomo 未运行' : null,
		status.operating_mode !== 'openwrt' && !status.runtime.controller_available ? '设备控制接口不可用' : null,
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
		result.push(E('div', { 'class': 'netfleet-overview-attention', 'role': 'note', 'aria-label': '需要关注' }, [
			E('strong', {}, '需要关注'),
			E('ul', {}, attention.map(function(item) { return E('li', {}, item); }))
		]));
	}
	return result;
}

function regionChoiceBlocked(controller, capability, region) {
	if (!controller || controller.context?.readOnly) return '当前为只读模式';
	if (!controller.liveDataReady || controller.refreshing) return '等待读取设备当前状态';
	if (controller.busy) return '已有操作正在执行';
	const choices = capability ? [capability] : controller.status.capabilities || [];
	return choices.some(function(item) {
		return item.can_select_region === true && (item.selectable_regions || []).some(function(id) { return !region || id === region; });
	}) ? null : '当前没有可切换的授权地区';
}

function regionChoiceButton(controller, capability, region) {
	const blocked = regionChoiceBlocked(controller, capability, region);
	return E('button', { 'type': 'button', 'class': 'btn cbi-button netfleet-region-choice',
		'disabled': blocked ? true : null, 'title': blocked || '手动保持指定地区，地区内节点继续由核心选择',
		'click': function() { controller.chooseRegion(capability?.id, region); }
	}, region ? '改用此地区' : '指定地区');
}

function selectionExplanation(status, capability) {
	const manual = capability.user_mode === 'manual_region';
	const message = manual ? '手动保持 ' + regionName(status, capability.manual_region_id || capability.region_id) + ' · 后台自动选优已暂停' :
		capability.user_mode === 'automatic' ? (status.selection?.automation_paused ? '自动路径保持中 · 后台选优暂停 · 切换门槛 ' : '自动选优 · 地区切换门槛 ') + delay(capability.region_switch_margin_ms ?? status.selection?.region_switch_margin_ms) : modeName(capability);
	return E('p', { 'class': 'netfleet-selection-note' + (manual ? ' is-manual' : '') }, message);
}

function selectionToolbar(status, controller) {
	return E('section', { 'class': 'netfleet-selection-summary' }, [
		E('div', {}, [ E('h3', {}, '地区选择'), E('p', {}, '测速排名供比较；实际出口还受地区资格、主备用层级和切换门槛约束。') ]),
		E('div', { 'class': 'netfleet-selection-exits' }, (status.capabilities || []).filter(function(item) { return item.enabled; }).map(function(item) {
			return E('div', {}, [ E('strong', {}, capabilityName(item) + ' · ' + currentRegion(status, item)), selectionExplanation(status, item), E('p', { 'class': 'netfleet-decision-reason' }, reasonText(status, item)), regionChoiceButton(controller, item) ]);
		}))
	]);
}

function capabilityPanel(status, capability, controller) {
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
			]),
			regionChoiceButton(controller, capability)
		]),
		E('div', { 'class': 'netfleet-exit-current' }, [
			E('dl', { 'class': 'netfleet-current-route' }, [
				E('dt', {}, '当前路径'),
				E('dd', {}, [ currentRegion(status, capability), E('small', {}, currentProvider(status, capability)) ])
			]),
			E('dl', {}, [ E('dt', {}, '当前延迟'), E('dd', {}, delay(capability.reason && capability.reason.delay_ms)) ]),
			E('dl', {}, [
				E('dt', {}, '健康状态'),
				E('dd', { 'class': capability.alive ? 'is-ok' : 'is-warning' }, [
					E('span', { 'class': 'netfleet-health-dot' + (capability.alive ? '' : ' is-bad') }),
					pathHealthLabel(capability)
				])
			]),
			E('dl', {}, [ E('dt', {}, '选择方式'), E('dd', {}, modeName(capability)) ])
		]),
		selectionExplanation(status, capability),
		E('details', { 'class': 'netfleet-exit-details' }, [ E('summary', {}, '节点、业务与恢复详情'), E('p', {}, route(status, capability).join(' → ')),
		business.length ? E('div', { 'class': 'netfleet-business-routing' }, [
			E('h4', {}, '业务路由')
		].concat(business)) : null,
		E('dl', { 'class': 'netfleet-exit-fallback' }, [
			E('dt', {}, '故障退路'),
			E('dd', {}, runtimeFallback(capability).join(' → '))
		]) ].filter(Boolean))
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

function exitsPage(status, controller) {
	const content = [];
	(status.capabilities || []).forEach(function(capability) { content.push(capabilityPanel(status, capability, controller)); });
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
			E('dl', {}, [ E('dt', {}, '最终退路'), E('dd', {}, '原生配置恢复失败时，停止 ' + backendName(status) + ' 并恢复网络直通') ])
		])
	]));
	return content;
}

function cacheDigest(value) {
	const digest = value && value.cache_sha256;
	if (!digest)
		return value && value.cache_present ? '已缓存' : '无可用缓存';
	return String(digest).slice(0, 12);
}

function subscriptionForProvider(subscriptions, provider) {
	const section = provider && provider.subscription_section;
	if (!section)
		return null;
	return subscriptions.find(function(entry) { return entry.section === section; }) || null;
}

function subscriptionFailed(entry) {
	return !entry || entry.cache_present !== true || [
		'failed', 'update_failed', 'upstream_unavailable', 'active_precondition_failed',
		'rollback_restored', 'rollback_failed'
	].indexOf(entry.last_result) >= 0;
}

function subscriptionState(entry) {
	if (!entry)
		return '订阅信息暂不可读';
	if (entry.pending_update || entry.last_result === 'pending')
		return entry.cache_present ? '待更新，沿用上次缓存' : '等待首次更新';
	if (entry.cache_present !== true)
		return '没有可用缓存';
	return entry.last_result === 'updated' ? '缓存已更新' :
		(entry.last_result ? refreshResult(entry.last_result) : '缓存可用');
}

function subscriptionSummary(refresh, subscriptions) {
	if (!subscriptions.length)
		return '暂无订阅';
	const healthy = subscriptions.filter(function(entry) { return !subscriptionFailed(entry); }).length;
	return String(healthy) + ' / ' + String(finite(refresh.provider_count) ? Number(refresh.provider_count) : subscriptions.length) + ' 正常';
}

function providerNodes(provider, subscription) {
	if (provider.node_count_known !== true)
		return '节点清单暂不可读';
	const loaded = countPair(provider.available_node_count, provider.node_count) + ' 节点';
	return finite(subscription && subscription.node_count) && Number(subscription.node_count) !== Number(provider.node_count) ?
		loaded + ' · 订阅 ' + String(Number(subscription.node_count)) + ' 条' : loaded;
}

function quotaMeter(provider) {
	const value = provider.quota || {};
	if (!finite(value.total_bytes) || !finite(value.remaining_bytes) || value.total_bytes <= 0 || value.remaining_bytes < 0 || value.remaining_bytes > value.total_bytes)
		return '';
	return E('meter', { 'class': 'netfleet-quota-meter', 'min': 0, 'max': value.total_bytes, 'value': value.remaining_bytes,
		'aria-label': '剩余流量比例', 'title': '剩余 ' + Math.round(value.remaining_bytes / value.total_bytes * 100) + '%' });
}

function tableTools(label, state, update, defaultLabel) {
	return E('div', { 'class': 'netfleet-table-tools' }, [
		E('input', { 'type': 'search', 'aria-label': '搜索' + label, 'placeholder': '搜索' + label, 'value': state.query || '',
			'input': function(event) { state.query = event.target.value; update(); } }),
		E('select', { 'aria-label': label + '排序', 'change': function(event) { state.sort = event.target.value; update(); } },
			[ ['default', defaultLabel || '默认排序'], ['name', '名称'], ['latest', '最近测量最快'], ['average', '历史平均最低'] ].map(function(item) {
				return E('option', { 'value': item[0], 'selected': (state.sort || 'default') === item[0] ? true : null }, item[1]);
			})),
		E('label', {}, [ E('input', { 'type': 'checkbox', 'checked': state.selectedOnly || null,
			'change': function(event) { state.selectedOnly = event.target.checked; update(); } }), ' 仅当前使用' ])
	]);
}

function tableItems(items, state, name) {
	const rows = items.filter(function(item) {
		return (!state.selectedOnly || item.selected) && name(item).toLocaleLowerCase().includes((state.query || '').toLocaleLowerCase());
	});
	if (state.sort && state.sort !== 'default') rows.sort(function(a, b) {
		if (state.sort === 'name') return name(a).localeCompare(name(b), 'zh-CN');
		const value = function(item) { return state.sort === 'average' ?
			(Number(item.delay_sample_count) >= 2 ? item.average_best_delay_ms : null) : item.last_best_delay_ms ?? item.best_delay_ms; };
		return (finite(value(a)) ? Number(value(a)) : Infinity) - (finite(value(b)) ? Number(value(b)) : Infinity);
	});
	return rows;
}

const measurementReasons = {
  "quota_exhausted": "流量已耗尽，不参与选优",
  "group_unavailable": "候选线路尚未加载",
  "group_members_unavailable": "候选线路的节点列表不可读",
  "selected_leaf_unavailable": "候选线路未选中有效成员",
  "no_proxy_leaf": "候选线路未选中代理节点",
  "provider_nodes_unavailable": "机场的节点清单不可读",
  "leaf_not_in_provider": "所选节点不在该机场的节点清单中",
  "leaf_identity_ambiguous": "机场内存在同名节点，无法确认归属",
  "leaf_type_unavailable": "所选节点缺少类型信息",
  "group_latency_failed": "候选线路的测速健康记录为失败（未提供底层错误）",
  "group_latency_unrecorded": "候选线路缺少该测速目标的健康记录",
  "leaf_latency_failed": "所选节点的测速健康记录为失败（未提供底层错误）",
  "leaf_latency_unrecorded": "所选节点缺少该测速目标的健康记录",
  "delay_unavailable": "未取得本轮新增的有效延迟记录",
  "latency_health_failed": "未取得候选线路的测速成功记录；旧记录未保留细节",
  "no_verified_leaf": "未能确认节点归属或测速健康；旧记录未保留细节",
  "measurement_unavailable": "未取得有效测速，记录未提供具体原因"
};
function measurementCell(value, status) {
	if (!value) return E('td', {}, '尚无测速记录');
	const entries = value.entries || [];
	const exhausted = (value.exclusions || {}).quota_exhausted || 0;
	const unmeasured = entries.filter(function(entry) { return !entry.ok && entry.quota_state !== 'exhausted'; }).length;
	const explanation = function(reason) { return measurementReasons[reason || 'measurement_unavailable'] || '未取得有效测速，原因暂无法解释'; };
	const details = [ E('summary', {}, '查看测速详情' + (entries.length ? '（' + entries.length + ' 项）' : '')),
		E('p', {}, '每项对应一个机场在一个地区的候选线路，不代表节点数。流量状态来自最近一次订阅更新，不随测速刷新；测速结果不等于业务保护检查结果。') ];
	if (entries.length) details.push(E('ul', {}, entries.map(function(entry) {
		const provider = (status.providers || []).find(function(item) { return item.id === entry.provider_id; });
		const subscription = provider && (status.subscriptions || []).find(function(item) { return item.section === provider.subscription_section; });
		const currentQuota = provider && provider.quota;
		const content = [ E('strong', {}, providerName(status, entry.provider_id) + ' · ' + regionName(status, entry.region_id)) ];
		if (currentQuota && currentQuota.state === 'exhausted')
			content.push(E('div', {}, measurementReasons.quota_exhausted));
		else if (currentQuota)
			content.push(E('div', {}, '订阅配额记录：' + (currentQuota.state === 'available' && finite(currentQuota.remaining_bytes) ? '剩余 ' : '') + quota(provider)));
		if (currentQuota) content.push(E('small', { 'class': 'netfleet-measurement-note' }, '订阅更新于 ' + executionAt(subscription && subscription.last_success)));
		if (entry.quota_state === 'exhausted' && (!currentQuota || currentQuota.state !== 'exhausted'))
			content.push(E('div', {}, '该次测速时流量已耗尽，不参与选优'));
		content.push(E('div', {}, '该次测速记录：' + (entry.ok ? '测速成功 · ' + delay(entry.delay_ms) : explanation(entry.measurement_reason))));
		return E('li', {}, content);
	})));
	else details.push(E('p', {}, '此记录没有逐项详情。' + Object.entries(value.exclusions || {}).map(function(item) {
		return explanation(item[0]) + '：' + item[1] + ' 项';
	}).join('；')));
	return E('td', { 'class': 'netfleet-measurement' }, [
		E('span', {}, delay(value.best_delay_ms, '未取得有效测速')),
		E('small', { 'class': 'netfleet-measurement-note' }, '该次测速：' + value.measured_count + ' 项测速成功' + (exhausted ? ' · ' + exhausted + ' 项流量耗尽' : '') + (unmeasured ? ' · ' + unmeasured + ' 项无有效结果' : '')),
		E('small', { 'class': 'netfleet-measurement-note' }, '采样于 ' + sampledAt(value.sampled_at)),
		E('details', {}, details)
	]);
}

function providersPage(status, controller) {
	const refresh = status.subscription_refresh || {};
	const subscriptions = status.subscriptions || [];
	const availabilityMeasured = Boolean(status.active && status.runtime.netfleet_present && status.runtime.controller_available);
	const providers = (status.providers || []).slice().sort(function(a, b) {
		return Number(Boolean(b.selected)) - Number(Boolean(a.selected)) ||
			(Number(b.available_region_count) || -1) - (Number(a.available_region_count) || -1) ||
			(Number(a.last_best_delay_ms ?? a.best_delay_ms) || Infinity) - (Number(b.last_best_delay_ms ?? b.best_delay_ms) || Infinity) ||
			providerName(status, a.id).localeCompare(providerName(status, b.id), 'zh-CN');
	});
	const rows = [];
	const state = controller.providerTableState || (controller.providerTableState = {});
	const inspector = E('aside', { 'class': 'netfleet-inspector', 'id': 'netfleet-provider-inspector', 'aria-label': '机场详情', 'hidden': true });
	const workspace = E('div', { 'class': 'netfleet-master-detail' });
	const list = E('div', { 'class': 'netfleet-list-pane' });
	let opener;
	function close() {
		state.detail = null;
		inspector.hidden = true;
		workspace.classList.remove('has-detail');
		rows.forEach(function(row) { row.classList.remove('is-inspected'); });
		if (opener) { opener.setAttribute('aria-expanded', 'false'); opener.focus({ preventScroll: true }); }
	}
	function open(provider, toggle, row, focus) {
		const subscription = subscriptionForProvider(subscriptions, provider);
		state.detail = provider.id;
		if (opener) opener.setAttribute('aria-expanded', 'false');
		opener = toggle;
		toggle.setAttribute('aria-expanded', 'true');
		rows.forEach(function(item) { item.classList.remove('is-inspected'); });
		row.classList.add('is-inspected');
		const dismiss = E('button', { 'type': 'button', 'class': 'netfleet-icon-button', 'title': '关闭机场详情', 'aria-label': '关闭机场详情', 'click': close }, '×');
		const facts = function(items) { return E('dl', { 'class': 'netfleet-inspector-facts' }, items.map(function(item) {
			return E('div', {}, [ E('dt', {}, item[0]), E('dd', {}, item[1]) ]);
		})); };
		inspector.replaceChildren(
			E('div', { 'class': 'netfleet-inspector-heading' }, [ E('h3', {}, providerName(status, provider.id)), dismiss ]),
			E('p', {}, (provider.role === 'reserve' ? '备用' : '主用') + ' · ' + (provider.billing === 'buyout' ? '买断制' : '订阅制')),
			E('h4', {}, '运行质量'), facts([
				[ '可用资源', availabilityMeasured ? providerNodes(provider, subscription) : status.active ? '暂不可读' : '未接管' ],
				[ '最近测量最快', delay(provider.last_best_delay_ms ?? provider.best_delay_ms) ],
				[ '历史平均最低', averageDelay(provider.average_best_delay_ms, provider.delay_sample_count) ],
				[ '有效测量', finite(provider.delay_sample_count) ? provider.delay_sample_count + ' 次' : '统计暂不可读' ],
				[ '最后测量', sampledAt(provider.delay_sampled_at) ]
			]), E('h4', {}, '订阅与用量'), facts([
				[ '订阅状态', subscriptionState(subscription) ], [ '剩余流量', E('div', {}, [ quota(provider), quotaMeter(provider) ]) ],
				[ '到期时间', providerExpiry(provider) ]
			].concat(provider.billing === 'subscription' && managed.quotaResetLabel((provider.quota || {}).reset_day) ? [
				[ '流量重置', managed.quotaResetLabel(provider.quota.reset_day) ]
			] : [])),
			E('button', { 'class': 'netfleet-inline-link', 'type': 'button', 'click': function() { controller.manageSubscriptions(); } }, '管理订阅'),
			E('h4', {}, '更新记录'), facts([
				[ '订阅标识', subscription ? subscription.section : '未关联订阅' ],
				[ '缓存版本', cacheDigest(subscription) ], [ '最近尝试', executionAt(subscription && subscription.last_attempt) ],
				[ '订阅更新时间', executionAt(subscription && subscription.last_success) ]
			]), E('button', { 'class': 'netfleet-inline-link', 'type': 'button', 'click': function() {
				controller.context.navigate('events');
			} }, '事件与诊断')
		);
		inspector.hidden = false;
		workspace.classList.add('has-detail');
		if (focus) dismiss.focus({ preventScroll: true });
	}
	inspector.addEventListener('keydown', function(event) { if (event.key === 'Escape') close(); });
	providers.forEach(function(provider) {
		const subscription = subscriptionForProvider(subscriptions, provider);
		let row;
		const toggle = E('button', { 'class': 'netfleet-name-link', 'type': 'button', 'aria-expanded': 'false', 'aria-controls': 'netfleet-provider-inspector',
			'click': function() { open(provider, toggle, row, true); } }, providerName(status, provider.id));
		row = E('tr', { 'class': provider.selected ? 'cbi-rowstyle-1' : '' }, [
			E('td', {}, [ toggle, provider.selected ? E('small', {}, '当前使用') : '' ]),
			E('td', {}, (provider.role === 'reserve' ? '备用' : '主用') + ' · ' + (({ subscription: '订阅制', buyout: '买断制' })[provider.billing] || text(provider.billing, '未知'))),
			E('td', {}, availabilityMeasured ? [
				E('span', {}, countPair(provider.available_region_count, provider.region_count) + ' 地区'),
				E('small', {}, providerNodes(provider, subscription))
			] : status.active ? '暂不可读' : '未接管'),
			measurementCell(provider.measurement, status)
		].concat([
			E('td', { 'class': subscriptionFailed(subscription) ? 'is-warning' : '' }, subscriptionState(subscription)),
			E('td', {}, [ quota(provider), quotaMeter(provider), provider.billing === 'subscription' && provider.quota && managed.quotaResetLabel(provider.quota.reset_day) ?
				E('small', { 'title': '手动设置，仅供套餐参考；实际结算以机场为准' }, managed.quotaResetLabel(provider.quota.reset_day)) : '' ]),
			E('td', {}, providerExpiry(provider))
		]));
		rows.push(row);
		if (state.detail === provider.id) open(provider, toggle, row, false);
	});
	const update = function() {
		const visible = tableItems(providers, state, function(provider) { return providerName(status, provider.id); });
		list.replaceChildren(simpleTable([ '机场', '定位', '可用资源', '最近一次测速', '订阅状态', '剩余流量', '到期时间' ],
			visible.map(function(provider) { return rows[providers.indexOf(provider)]; }), '没有匹配的机场', 'netfleet-data-table netfleet-provider-table'));
	};
	update();
	workspace.replaceChildren(list, inspector);
	return [
		E('div', { 'class': 'cbi-section netfleet-subscription-summary' }, [
			E('div', { 'class': 'netfleet-section-heading' }, [
				E('div', {}, [
					E('h3', {}, '订阅更新')
				]),
				E('button', {
					'class': 'netfleet-inline-link',
					'type': 'button',
					'click': function() { controller.manageSubscriptions(); }
				}, '管理订阅')
			]),
			metricGrid([
			[ '自动更新', refresh.enabled ? '已启用' : '已关闭' ],
			[ '更新周期', seconds(refresh.interval_seconds) ],
			[ '最近全部更新', executionAt(refresh.last_success_at) ],
			[ '最近尝试', executionAt(refresh.last_run_at) ],
			[ '下次更新', refresh.enabled ? (refresh.next_run_at ? sampledAt(refresh.next_run_at) : '等待首次更新') : '已关闭' ],
			[ '订阅状态', subscriptionSummary(refresh, subscriptions) ],
			[ '最近结果', refreshResult(refresh.last_result) ]
			], 'is-five')
		]),
		E('section', {}, [ tableTools('机场', state, update), E('p', { 'class': 'netfleet-table-caption' }, availabilityMeasured ?
			'资源数：当前可用 / 已加载。延迟：每轮最快的有效测量。' : status.active ? '控制接口暂不可读；以下延迟为历史有效测量。' : 'NetFleet 未接管；以下延迟为历史有效测量。'), workspace ])
	];
}

function regionsPage(status, controller) {
	const state = controller.regionTableState || (controller.regionTableState = {});
	const regions = (status.regions || []).slice().sort(function(a, b) {
		return (finite(a.measurement?.best_delay_ms) ? Number(a.measurement.best_delay_ms) : Infinity) -
			(finite(b.measurement?.best_delay_ms) ? Number(b.measurement.best_delay_ms) : Infinity) ||
			(Number(b.available_node_count) || -1) - (Number(a.available_node_count) || -1) ||
			(Number(b.available_provider_count) || -1) - (Number(a.available_provider_count) || -1) ||
			regionName(status, a.id).localeCompare(regionName(status, b.id), 'zh-CN');
	});
	const rows = regions.map(function(region) {
		return E('tr', { 'class': region.selected ? 'cbi-rowstyle-1' : '' }, [
			E('td', {}, [regionName(status, region.id), E('small', {}, (status.capabilities || []).filter(function(cap) { return cap.enabled && cap.region_id === region.id && ['preferred', 'manual_region'].includes(cap.data_path); }).map(capabilityName).join('、'))]),
			E('td', {}, status.active && status.runtime.controller_available ? countPair(region.available_provider_count, region.provider_count) : '未测量'),
			E('td', {}, !status.active || !status.runtime.controller_available ? '未测量' : region.node_count == null ? '节点清单暂不可读' : countPair(region.available_node_count, region.node_count)),
			measurementCell(region.measurement, status)
		].concat([
			E('td', {}, E('details', { 'class': 'netfleet-measurement-history' }, [ E('summary', {}, '历史测量'),
				E('div', {}, '最近 ' + delay(region.last_best_delay_ms)),
				E('div', {}, '平均 ' + averageDelay(region.average_best_delay_ms, region.delay_sample_count)),
				E('small', {}, (finite(region.delay_sample_count) ? region.delay_sample_count + ' 次 · ' : '') + sampledAt(region.delay_sampled_at))
			])),
			E('td', {}, ({ automatic: '自动选优', manual: '手动选择', manual_only: '仅手动' })[region.mode] || text(region.mode, '未知')),
			E('td', {}, regionChoiceButton(controller, null, region.id))
		]));
	});
	const list = E('div');
	const caption = E('p', { 'class': 'netfleet-table-caption' });
	const update = function() {
		const visible = tableItems(regions, state, function(region) { return regionName(status, region.id); });
		caption.replaceChildren('已配置 ' + regions.length + ' 个地区 · ' + (status.active && status.runtime.controller_available ? currentRegionPlan(status).length + ' 个有健康记录' : '实时状态未测量') + ' · 显示 ' + visible.length + ' 个');
		list.replaceChildren(simpleTable([ '地区', '机场健康记录', '节点健康记录', '最近一次候选测速', '历史测量', '参与方式', '操作' ],
			visible.map(function(region) { return rows[regions.indexOf(region)]; }), '没有匹配的地区', 'netfleet-data-table'));
	};
	update();
	return [ selectionToolbar(status, controller), E('section', {}, [ tableTools('地区', state, update, '最近一次测速（从低到高）'), caption,
		E('p', { 'class': 'netfleet-measurement-note' }, '健康记录为核心标记的健康数 / 已加载总数；候选测速每个机场在该地区核验一条线路。两者的测速目标与采样时间可能不同，健康数量不代表本轮测速成功数量；流量耗尽的机场仍不参与选优。'), list ]) ];
}

function displayEventName(events, kind, id) {
	if (!id)
		return '全局';
	const names = events.display_names && events.display_names[kind] || {};
	const value = names[id] || id;
	return kind === 'regions' ? regionalDisplayName(value) : value;
}

function latestDecision(events) {
	return events.reduce(function(latest, event) {
		return ['enable', 'select', 'disable'].indexOf(event.action) >= 0 &&
			(!latest || Number(event.at) >= Number(latest.at)) ? event : latest;
	}, null);
}

function eventResult(events, event) {
	if (event.action === 'refresh') {
		if (event.reason === 'rollback_restored') return '更新未生效，已恢复更新前状态';
		return finite(event.changed_count) && finite(event.failed_count)
			? '更新 ' + event.changed_count + ' 个机场，失败 ' + event.failed_count + ' 个' : '订阅更新';
	}
	if (event.action === 'disable' && event.reason === 'native_restored') return '已恢复原生配置';
	if (event.action === 'disable' && event.reason === 'native_restore_failed_passthrough') return '已恢复网络直通';
	if (event.to_group === 'DIRECT') return '直连';
	return [displayEventName(events, 'regions', event.region_id), displayEventName(events, 'providers', event.provider_id), event.leaf]
		.filter(function(item) { return item && item !== '全局'; }).join(' / ') || '未记录选路结果';
}

function eventDelay(event) {
	return event.action === 'refresh' || event.action === 'disable' ? '不适用' : delay(event.delay_ms, '未记录');
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
			native_restored: '已恢复原生配置',
			native_restore_failed_passthrough: '原生配置恢复失败，已停止代理后端 并恢复网络直通',
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
			? (event.trigger === 'scheduled' ? '定期选优' : event.trigger === 'refresh' ? '订阅更新后选优' : '手动选优')
				: ({ enable: '启用', refresh: '更新订阅', disable: '关闭' })[event.action] || text(event.action, '未提供');
		const initiator = ({ luci: 'LuCI', cli: '命令行', deployer: '部署流程', supervisor: '后台选优' })[event.initiator] || text(event.initiator, '未提供');
		const result = eventResult(events, event);
		return E('tr', {}, [
			E('td', {}, finite(event.at) ? new Date(Number(event.at) * 1000).toLocaleString() : '未提供'),
			E('td', {}, action), E('td', {}, initiator),
			E('td', {}, displayEventName(events, 'capabilities', event.capability)),
			E('td', {}, result), E('td', {}, eventDelay(event)),
			E('td', {}, eventReason(status, event))
		]);
	});
	const diagnostics = [
		[ '设备控制接口', status.runtime.controller_available ? '可读取' : '不可用' ],
		[ '事件存储', events.store_valid === false ? '异常' : '有效' ],
		[ '决策事件', String((events.events || []).length) + ' 条' ],
		[ '当前连接', connectionsLoading ? '正在读取' : connectionsError ? '读取失败' : connections.count == null ? '尚未读取' : String((connections.connections || []).length) + ' 条' ]
	];
	const logRetention = events.core_lines_persistent === false ? '临时窗口' : '设备保留';
	const connectionRows = (connections.connections || []).map(function(connection) {
		const rule = [ connection.rule, connection.rule_payload ].filter(Boolean).join(' / ') || '未提供';
		return E('tr', {}, [
			E('td', {}, connection.destination || '未提供'),
			E('td', {}, finite(connection.destination_port) || typeof connection.destination_port === 'string' ? String(connection.destination_port) : '未提供'),
			E('td', {}, text(connection.network, '未提供').toUpperCase()),
			E('td', {}, rule),
			E('td', {}, (connection.chains || []).map(function(item) { return item === 'DIRECT' ? '直连' : regionalDisplayName(item); }).join(' → ') || '未记录链路')
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
				E('span', {}, events.core_lines_persistent === false ? '仅展示核心当前保留的最近日志，不作为持久事件记录。' : '由设备日志策略负责保留。')
			])
		]),
		section('当前活动连接', '辅助诊断快照，不代表完整的 Mihomo 观察面。', [ connectionContent ]),
		section('Mihomo 原始日志', null, [ E('pre', {}, (events.core_lines || []).join('\n') || '暂无相关原始日志。') ])
	];
}

return baseclass.extend({ ageLabel, finite, text, pageHeading, delay, averageDelay, countPair, dashboardReady, dashboardUnavailableReason, regionalDisplayName, byId, providerName, regionName, capabilityName, route, runtimeFallback, modeName, pathHealthLabel, reasonText, quota, providerExpiry, sampledAt, executionAt, refreshResult, simpleTable, section, metricGrid, onboardingMessage, nativeProfileLabel, backendName, onboardingPage, detailGrid, statusSummary, operatingModeLabel, operatingModeControls, fastest, joined, currentRegionPlan, currentRegion, currentProvider, overviewLink, overviewExitSummary, overviewFact, overviewDigest, regionChoiceBlocked, regionChoiceButton, selectionExplanation, selectionToolbar, capabilityPanel, overviewPage, seconds, exitsPage, cacheDigest, subscriptionForProvider, subscriptionFailed, subscriptionState, subscriptionSummary, providerNodes, quotaMeter, tableTools, tableItems, measurementCell, providersPage, regionsPage, displayEventName, latestDecision, eventResult, eventDelay, eventReason, eventsPage });
