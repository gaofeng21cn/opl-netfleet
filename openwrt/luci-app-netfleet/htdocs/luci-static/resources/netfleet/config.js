/* SPDX-License-Identifier: MIT */

'use strict';
'require baseclass';
'require ui';

const SECTIONS = [
	[ 'foundation', '基础接入' ],
	[ 'providers', '机场' ],
	[ 'regions', '地区映射' ],
	[ 'capabilities', '出口策略' ],
	[ 'automation', '自动运行' ],
	[ 'safety', '安全与恢复' ]
];

function clone(value) {
	return JSON.parse(JSON.stringify(value));
}

function statusById(items, id) {
	return (items || []).find(function(item) { return item.id === id; }) || {};
}

function regionalDisplayName(flag, name) {
	const chars = Array.from(String(flag || ''));
	if (chars.length >= 2) {
		const first = chars[0].codePointAt(0);
		const second = chars[1].codePointAt(0);
		if (first >= 0x1F1E6 && first <= 0x1F1FF && second >= 0x1F1E6 && second <= 0x1F1FF)
			return (String.fromCharCode(65 + first - 0x1F1E6, 65 + second - 0x1F1E6) + ' ' + name).trim();
	}
	return String(name || '').trim();
}

function visibleRegions(controller) {
	return controller.configDraft.regions.filter(function(region) {
		const status = statusById(controller.status.regions, region.id);
		return Number(status.available_node_count || 0) > 0 && Number(status.available_provider_count || 0) > 0;
	});
}

function fieldRow(label, help, control) {
	const description = [ E('strong', {}, label) ];
	if (help)
		description.push(E('p', {}, help));
	return E('div', { 'class': 'netfleet-config-row' }, [
		E('div', {}, description),
		E('div', { 'class': 'netfleet-config-control' }, control)
	]);
}

function sectionHeading(title, help) {
	return E('div', { 'class': 'netfleet-config-heading' }, [ E('h3', {}, title), E('p', {}, help) ]);
}

function select(value, options, onchange, disabled) {
	const attrs = { 'class': 'cbi-input-select', 'change': onchange };
	if (disabled) attrs.disabled = true;
	return E('select', attrs, options.map(function(option) {
		const optionAttrs = { 'value': String(option[0]) };
		if (String(option[0]) === String(value)) optionAttrs.selected = true;
		return E('option', optionAttrs, option[1]);
	}));
}

function checkbox(checked, label, onchange, disabled) {
	const attrs = { 'type': 'checkbox', 'change': onchange };
	if (checked) attrs.checked = true;
	if (disabled) attrs.disabled = true;
	return E('label', { 'class': 'netfleet-check' }, [ E('input', attrs), E('span', {}, label) ]);
}

function update(controller, callback) {
	const next = clone(controller.configDraft);
	callback(next);
	controller.configDraft = next;
	controller.redraw();
}

function foundation(controller) {
	const draft = controller.configDraft;
	const runtime = controller.status.runtime || {};
	const checks = [
		[ 'Nikki 服务', runtime.nikki_enabled === true ],
		[ 'Mihomo 核心', runtime.mihomo_running === true ],
		[ '控制接口', runtime.controller_available === true ],
		[ '网络接管', Boolean(runtime.lan_runtime && runtime.lan_runtime.transparent_proxy_ready && runtime.lan_runtime.dns_ready) ]
	];
	const sourceOptions = (draft.policy_source_options || []).map(function(option) {
		return [ option.kind + '|' + option.ref, option.display_name ];
	});
	const recoveryOptions = (draft.recovery_profile_options || []).map(function(option) {
		return [ option.ref, option.display_name ];
	});
	return E('section', {}, [
		sectionHeading('基础接入', '确认当前运行环境，并选择策略基础和退出目标。'),
		E('div', { 'class': 'netfleet-environment' }, checks.map(function(item) {
			return E('div', {}, [ E('span', { 'class': item[1] ? 'is-ok' : 'is-warning' }, item[1] ? '正常' : '检查'), E('strong', {}, item[0]) ]);
		})),
		E('div', { 'class': 'netfleet-config-rows' }, [
			fieldRow('当前运行后端', '当前版本由 Nikki 管理 OpenWrt 数据面，Mihomo 负责代理核心。',
				E('span', { 'class': 'netfleet-readonly' }, draft.backend.display_name)),
			fieldRow('策略基础', '决定规则和稳定出口组从哪里开始生成。',
				select(draft.policy_source.kind + '|' + draft.policy_source.ref, sourceOptions, function(event) {
					const parts = event.target.value.split('|');
					update(controller, function(next) {
						const option = next.policy_source_options.find(function(item) { return item.kind === parts[0] && item.ref === parts.slice(1).join('|'); });
						next.policy_source = clone(option);
					});
				})),
			fieldRow('退出与故障恢复', '关闭或启用失败时优先恢复这份原生配置。',
				select(draft.recovery_profile.ref, recoveryOptions, function(event) {
					update(controller, function(next) {
						const option = next.recovery_profile_options.find(function(item) { return item.ref === event.target.value; });
						next.recovery_profile = clone(option);
					});
				}))
		])
	]);
}

function providers(controller) {
	const rows = controller.configDraft.providers.map(function(provider) {
		const status = statusById(controller.status.providers, provider.id);
		const enabledAttrs = { 'type': 'checkbox', 'aria-label': provider.display_name + ' 参与 NetFleet', 'change': function(event) {
			update(controller, function(next) { next.providers.find(function(item) { return item.id === provider.id; }).enabled = event.target.checked; });
		} };
		if (provider.enabled) enabledAttrs.checked = true;
		return E('tr', {}, [
			E('td', {}, E('input', enabledAttrs)),
			E('td', {}, [ E('strong', {}, provider.display_name), E('small', {}, provider.id) ]),
			E('td', {}, String(status.available_region_count ?? 0) + ' 个地区 / ' + (status.node_count_known === true ? String(status.available_node_count ?? 0) + ' 个节点' : '节点未提供')),
			E('td', {}, select(provider.role, [ [ 'primary', '主用机场' ], [ 'reserve', '备用机场' ] ], function(event) {
				update(controller, function(next) { next.providers.find(function(item) { return item.id === provider.id; }).role = event.target.value; });
			}, !provider.enabled)),
			E('td', {}, select(provider.billing, [ [ 'subscription', '订阅制' ], [ 'buyout', '买断制' ] ], function(event) {
				update(controller, function(next) { next.providers.find(function(item) { return item.id === provider.id; }).billing = event.target.value; });
			}, !provider.enabled))
		]);
	});
	return E('section', {}, [
		sectionHeading('机场', '只选择 Nikki 已有订阅；订阅地址、节点和下载不在此页面编辑。'),
		E('div', { 'class': 'table netfleet-config-table' }, [
			E('table', {}, [ E('thead', {}, E('tr', {}, [ E('th', {}, '参与'), E('th', {}, '机场'), E('th', {}, '真实资源'), E('th', {}, '故障层级'), E('th', {}, '计费方式') ])), E('tbody', {}, rows) ])
		])
	]);
}

function regions(controller) {
	const visible = visibleRegions(controller);
	const rows = visible.map(function(region) {
		const status = statusById(controller.status.regions, region.id);
		const input = E('input', {
			'class': 'cbi-input-text', 'value': region.display_name,
			'aria-label': regionalDisplayName(region.flag, region.display_name) + ' 地区名称',
			'change': function(event) { update(controller, function(next) { next.regions.find(function(item) { return item.id === region.id; }).display_name = event.target.value; }); }
		});
		return E('tr', {}, [
			E('td', {}, E('span', { 'class': 'netfleet-mapping-ok' }, '已识别')),
			E('td', {}, [ E('strong', { 'class': 'netfleet-region-code' }, regionalDisplayName(region.flag, '')), input ]),
			E('td', {}, String(status.available_provider_count) + ' 个机场 / ' + String(status.available_node_count) + ' 个节点'),
			E('td', {}, select(region.mode, [ [ 'automatic', '参与自动选优' ], [ 'manual_only', '仅手动使用' ] ], function(event) {
				update(controller, function(next) { next.regions.find(function(item) { return item.id === region.id; }).mode = event.target.value; });
			}))
		]);
	});
	return E('section', {}, [
		sectionHeading('地区映射', '地区来自当前机场的真实节点；只修正识别结果，不预设必须存在的地区。'),
		E('div', { 'class': 'table netfleet-config-table' }, [
			E('table', {}, [ E('thead', {}, E('tr', {}, [ E('th', {}, '识别状态'), E('th', {}, '地区名称'), E('th', {}, '真实覆盖'), E('th', {}, '自动选优') ])), E('tbody', {}, rows) ])
		])
	]);
}

function capabilities(controller) {
	const draft = controller.configDraft;
	return E('section', {}, [
		sectionHeading('出口策略', '决定哪些业务出口由 NetFleet 增强，以及自动选择可以使用哪些地区。'),
		E('div', { 'class': 'netfleet-capability-config' }, draft.capabilities.map(function(capability) {
			const rows = [
				E('div', { 'class': 'netfleet-capability-head' }, [
					E('div', {}, [ E('strong', {}, capability.display_name), E('small', {}, '接管：' + (capability.base_groups || []).join('、')) ]),
					checkbox(capability.enabled, capability.enabled ? '已启用' : '已关闭', function(event) {
						update(controller, function(next) { next.capabilities.find(function(item) { return item.id === capability.id; }).enabled = event.target.checked; });
					})
				]),
				fieldRow('运行方式', null, select(capability.mode, [ [ 'automatic', '自动选优' ], [ 'manual', '手动选择' ] ], function(event) {
					update(controller, function(next) { next.capabilities.find(function(item) { return item.id === capability.id; }).mode = event.target.value; });
				}, !capability.enabled)),
				fieldRow('地区限制', '取消选择的地区不会进入该出口的候选集合。',
					E('div', { 'class': 'netfleet-region-checks' }, visibleRegions(controller).map(function(region) {
						const selected = capability.region_ids.indexOf(region.id) >= 0;
						return checkbox(selected, regionalDisplayName(region.flag, region.display_name), function(event) {
							update(controller, function(next) {
								const target = next.capabilities.find(function(item) { return item.id === capability.id; });
								target.region_ids = event.target.checked ? target.region_ids.concat([ region.id ]) : target.region_ids.filter(function(id) { return id !== region.id; });
							});
						}, !capability.enabled);
						})))
			];
			if (capability.prefer_region_from)
				rows.push(E('p', { 'class': 'netfleet-follow-note' }, '优先跟随其他自动出口的合规地区；不合规时独立选择。'));
			return E('div', { 'class': 'netfleet-capability-editor' }, rows);
		}))
	]);
}

function automation(controller) {
	const value = controller.configDraft.automation;
	return E('section', {}, [
		sectionHeading('自动运行', '设置重新比较出口和请求 Nikki 更新已有订阅的周期。'),
		E('div', { 'class': 'netfleet-config-rows' }, [
			fieldRow('周期选优', '关闭后仍可手动执行单次选优。', checkbox(value.enabled, value.enabled ? '已开启' : '已关闭', function(event) {
				update(controller, function(next) { next.automation.enabled = event.target.checked; });
			})),
			fieldRow('选优周期', '只在自动模式下执行同一套有界选择。', select(value.selection_interval_seconds,
				[ [ 900, '15 分钟' ], [ 1800, '30 分钟' ], [ 3600, '1 小时' ], [ 7200, '2 小时' ] ], function(event) {
					update(controller, function(next) { next.automation.selection_interval_seconds = Number(event.target.value); });
				}, !value.enabled)),
			fieldRow('定期更新订阅', '实际下载和缓存仍由 Nikki 官方更新器负责。', checkbox(value.subscription_refresh_enabled,
				value.subscription_refresh_enabled ? '已开启' : '已关闭', function(event) {
					update(controller, function(next) { next.automation.subscription_refresh_enabled = event.target.checked; });
				})),
			fieldRow('订阅更新周期', '只有内容摘要变化时才重新生成和选优。', select(value.subscription_refresh_interval_seconds,
				[ [ 21600, '6 小时' ], [ 43200, '12 小时' ], [ 86400, '24 小时' ] ], function(event) {
					update(controller, function(next) { next.automation.subscription_refresh_interval_seconds = Number(event.target.value); });
				}, !value.subscription_refresh_enabled))
		])
	]);
}

function safety(controller) {
	const value = controller.configDraft.safety;
	function numberField(field, min, max) {
		return E('input', { 'class': 'cbi-input-text', 'type': 'number', 'min': min, 'max': max, 'value': value[field], 'change': function(event) {
			update(controller, function(next) { next.safety[field] = Number(event.target.value); });
		} });
	}
	function urlField(field) {
		return E('input', { 'class': 'cbi-input-text', 'type': 'url', 'value': value[field], 'change': function(event) {
			update(controller, function(next) { next.safety[field] = event.target.value; });
		} });
	}
	return E('section', {}, [
		sectionHeading('安全与恢复', '默认值适合日常使用；只有明确需要时再调整高级参数。'),
		E('div', { 'class': 'netfleet-recovery-summary' }, [
			E('strong', {}, '优先恢复：' + controller.configDraft.recovery_profile.display_name + ' 原生配置'),
			E('p', {}, '最终退路：原生配置恢复失败时，停止 Nikki 并恢复网络直通。')
		]),
		E('details', { 'class': 'netfleet-advanced' }, [
			E('summary', {}, '高级设置'),
			E('div', { 'class': 'netfleet-config-rows' }, [
				fieldRow('地区切换门槛', '替代地区至少快到该数值才切换。', numberField('region_switch_margin_ms', 0, 5000)),
				fieldRow('节点切换门槛', '避免同一地区内因微小差异频繁换节点。', numberField('leaf_switch_margin_ms', 0, 5000)),
				fieldRow('运行失联保护', '连续失联超过该时间后进入受保护恢复。', numberField('runtime_grace_seconds', 15, 300)),
				fieldRow('测速地址', '只用于同轮延迟比较。', urlField('latency_url')),
				fieldRow('代理路径检查地址', '用于机场故障层的运行时健康确认。', urlField('path_probe_url')),
				fieldRow('最终保护地址', '用于启用、切换和最终退路的业务确认。', urlField('guard_probe_url'))
			])
		])
	]);
}

function content(controller) {
	return ({
		foundation: foundation,
		providers: providers,
		regions: regions,
		capabilities: capabilities,
		automation: automation,
		safety: safety
	})[controller.configSection](controller);
}

function request(config) {
	const providers = {};
	(config.providers || []).forEach(function(item) { providers[item.id] = { enabled: item.enabled, role: item.role, billing: item.billing }; });
	const regions = {};
	(config.regions || []).forEach(function(item) { regions[item.id] = { display_name: item.display_name, mode: item.mode }; });
	const capabilities = {};
	(config.capabilities || []).forEach(function(item) { capabilities[item.id] = { enabled: item.enabled, mode: item.mode, region_ids: item.region_ids.slice() }; });
	return {
		revision: config.revision,
		policy_source: { kind: config.policy_source.kind, ref: config.policy_source.ref },
		recovery_profile_ref: config.recovery_profile.ref,
		providers: providers,
		regions: regions,
		capabilities: capabilities,
		automation: clone(config.automation),
		safety: clone(config.safety)
	};
}

function dirty(controller) {
	return JSON.stringify(request(controller.configDraft)) !== JSON.stringify(request(controller.config));
}

function render(controller) {
	if (!controller.configDraft)
		return E('div', { 'class': 'alert-message warning' }, '正在读取设备配置；读取完成前不会开放配置操作。');
	const changed = dirty(controller);
	const active = controller.configDraft.active === true;
	const canApply = changed || controller.config.pending_apply === true || !active;
	return E('div', { 'class': 'netfleet-config-page' }, [
		E('div', { 'class': 'netfleet-config-intro' }, [
			E('div', {}, [ E('strong', {}, '设备配置'), E('span', {}, active ? '当前已接管，应用会执行受保护切换。' : '当前未接管，可先保存配置或直接应用。') ]),
			E('button', { 'class': 'btn cbi-button', 'click': function() { controller.showConfigWizard(0); } }, '首次设置向导')
		]),
		E('div', { 'class': 'netfleet-config-layout' }, [
			E('nav', { 'class': 'netfleet-config-nav', 'aria-label': '配置分类' }, SECTIONS.map(function(item) {
				return E('button', { 'class': controller.configSection === item[0] ? 'is-active' : '', 'click': function() { controller.configSection = item[0]; controller.redraw(); } }, item[1]);
			})),
			E('div', { 'class': 'netfleet-config-content' }, content(controller))
		]),
		E('div', { 'class': 'netfleet-config-actions' }, [
			E('span', {}, changed ? '有尚未保存的更改' : (controller.config.pending_apply ? '配置已保存，等待应用' : '设备配置与当前草稿一致')),
			E('div', {}, [
				E('button', { 'class': 'btn cbi-button', 'disabled': !changed || controller.busy, 'click': function() { controller.discardConfig(); } }, '放弃更改'),
				E('button', { 'class': 'btn cbi-button', 'disabled': controller.busy, 'click': function() { controller.validateConfig(); } }, '校验配置'),
				E('button', { 'class': 'btn cbi-button', 'disabled': controller.busy, 'click': function() { controller.previewConfigChanges(); } }, '查看变更'),
				E('button', { 'class': 'btn cbi-button', 'disabled': !changed || active || controller.busy, 'title': active ? '已接管时请直接使用“应用配置”' : '', 'click': function() { controller.saveConfig(); } }, '保存配置'),
				E('button', { 'class': 'btn cbi-button cbi-button-action', 'disabled': !canApply || controller.busy || !controller.liveDataReady, 'click': function() { controller.confirmConfigApply(); } }, '应用配置')
			])
		])
	]);
}

function changeText(change, controller) {
	const labels = {
		enabled: '启用状态', role: '故障层级', billing: '计费方式', mode: '运行方式', display_name: '显示名称',
		region_ids: '可用地区', policy_source: '策略基础', recovery_profile: '退出与故障恢复',
		selection_interval_seconds: '选优周期', subscription_refresh_enabled: '定期更新订阅',
		subscription_refresh_interval_seconds: '订阅更新周期', region_switch_margin_ms: '地区切换门槛',
		leaf_switch_margin_ms: '节点切换门槛', runtime_grace_seconds: '运行失联保护', latency_url: '测速地址',
		path_probe_url: '代理路径检查地址', guard_probe_url: '最终保护地址'
	};
	let owner = '';
	if (change.id) {
		const collection = change.scope === 'provider' ? controller.configDraft.providers : change.scope === 'region' ? controller.configDraft.regions : controller.configDraft.capabilities;
		const item = (collection || []).find(function(entry) { return entry.id === change.id; });
		owner = (item && item.display_name ? item.display_name : change.id) + '：';
	}
	function value(input) {
		if (input === true) return '开启';
		if (input === false) return '关闭';
		if (Array.isArray(input)) return input.join('、') || '无';
		if (input && typeof input === 'object') return input.display_name || input.ref || '已设置';
		return String(input ?? '未设置');
	}
	return owner + (labels[change.field] || change.field) + '：' + value(change.before) + ' → ' + value(change.after);
}

function wizard(controller, step) {
	const groups = [ 'foundation', 'providers', 'regions', 'capabilities', 'automation' ];
	const labels = [ '环境与恢复', '机场', '地区', '出口', '运行与安全' ];
	const oldSection = controller.configSection;
	controller.configSection = groups[step];
	let body = content(controller);
	controller.configSection = oldSection;
	if (step === 4)
		body = E('div', {}, [ body, safety(controller) ]);
	return [
		E('ol', { 'class': 'netfleet-wizard-steps' }, labels.map(function(label, index) {
			return E('li', { 'class': index === step ? 'is-active' : index < step ? 'is-complete' : '' }, [ E('span', {}, String(index + 1)), E('strong', {}, label) ]);
		})),
		E('div', { 'class': 'netfleet-wizard-body' }, body),
		E('div', { 'class': 'right' }, [
			E('button', { 'class': 'btn', 'click': step === 0 ? function() { ui.hideModal(); } : function() { controller.showConfigWizard(step - 1); } }, step === 0 ? '退出向导' : '上一步'),
			' ',
			step < 4 ? E('button', { 'class': 'btn cbi-button-action', 'click': function() { controller.showConfigWizard(step + 1); } }, '下一步') :
				E('button', { 'class': 'btn cbi-button-action', 'click': function() { ui.hideModal(); controller.previewConfigChanges(); } }, '完成并查看变更')
		])
	];
}

return baseclass.extend({
	clone: clone,
	request: request,
	dirty: dirty,
	render: render,
	changeText: changeText,
	wizard: wizard
});
