/* SPDX-License-Identifier: MIT */

'use strict';
'require baseclass';
'require ui';
'require netfleet.compatibility as compatibility';
'require netfleet.management as management';

const SECTIONS = [
	[ 'foundation', '基础接入' ],
	[ 'network', '网络接入' ],
	[ 'providers', '机场' ],
	[ 'regions', '地区映射' ],
	[ 'capabilities', '出口策略' ],
	[ 'routing', '业务规则' ],
	[ 'automation', '自动运行' ],
	[ 'safety', '安全与恢复' ],
	[ 'compatibility', 'HTTPS 兼容' ],
	[ 'files', '配置文件与备份' ]
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
	return controller.configDraft.regions || [];
}

function removeById(items, id) {
	return (items || []).filter(function(item) { return item.id !== id; });
}

function optionById(items, id) {
	return (items || []).find(function(item) { return item.id === id; }) || null;
}

function stableId(value) {
	return /^[A-Za-z0-9][A-Za-z0-9_-]*$/.test(String(value || ''));
}

function compactButton(label, onclick, destructive) {
	return E('button', { 'class': 'btn cbi-button netfleet-compact-button' + (destructive ? ' cbi-button-negative' : ''), 'type': 'button', 'click': onclick }, label);
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
		[ '运行后端', runtime.backend_enabled === true ],
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
			fieldRow('当前运行后端', null,
				E('div', {}, [ E('span', { 'class': 'netfleet-readonly' }, draft.backend.display_name),
					draft.backend.id === 'nikki-mihomo' ? compactButton('迁移到 NetFleet 原生后端', function() { controller.migrateBackend(); }) : E('span') ])),
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
	const draft = controller.configDraft;
	const rows = controller.configDraft.providers.map(function(provider) {
		const status = statusById(controller.status.providers, provider.id);
		const enabledAttrs = { 'type': 'checkbox', 'aria-label': provider.display_name + ' 参与 NetFleet', 'change': function(event) {
			update(controller, function(next) { next.providers.find(function(item) { return item.id === provider.id; }).enabled = event.target.checked; });
		} };
		if (provider.enabled) enabledAttrs.checked = true;
		return E('tr', {}, [
			E('td', {}, E('input', enabledAttrs)),
			E('td', {}, [ E('strong', {}, provider.display_name), E('small', {}, provider.id) ]),
			E('td', {}, status.id ? String(status.available_region_count ?? 0) + ' 个地区 / ' + (status.node_count_known === true ? String(status.available_node_count ?? 0) + ' 个节点' : '节点未提供') : provider.region_ids.length + ' 个已识别地区 / 待应用'),
			E('td', {}, select(provider.role, [ [ 'primary', '主用机场' ], [ 'reserve', '备用机场' ] ], function(event) {
				update(controller, function(next) { next.providers.find(function(item) { return item.id === provider.id; }).role = event.target.value; });
			}, !provider.enabled)),
			E('td', {}, select(provider.billing, [ [ 'subscription', '订阅制' ], [ 'buyout', '买断制' ] ], function(event) {
				update(controller, function(next) { next.providers.find(function(item) { return item.id === provider.id; }).billing = event.target.value; });
			}, !provider.enabled)),
			E('td', {}, compactButton('移除', function() {
				update(controller, function(next) { next.providers = removeById(next.providers, provider.id); });
			}, true))
		]);
	});
	const available = (draft.provider_options || []).filter(function(option) {
		return !draft.providers.some(function(provider) { return provider.id === option.id; });
	});
	let selected = available[0] ? available[0].id : '';
	const addControls = available.length ? E('div', { 'class': 'netfleet-inline-add' }, [
		select(selected, available.map(function(option) { return [ option.id, option.display_name ]; }), function(event) { selected = event.target.value; }),
		compactButton('添加机场', function() {
			const option = optionById(draft.provider_options, selected);
			if (!option) return;
			update(controller, function(next) {
				next.providers.push({ id: option.id, section: option.section, display_name: option.display_name, enabled: true, role: 'primary', billing: 'subscription', region_ids: (option.region_ids || []).slice() });
				(option.region_ids || []).forEach(function(regionId) {
					if (next.regions.some(function(region) { return region.id === regionId; })) return;
					const region = optionById(next.region_options, regionId);
					if (region) next.regions.push({ id: region.id, flag: region.code, display_name: region.display_name, display_order: region.display_order, mode: 'automatic' });
				});
			});
		})
	]) : E('p', { 'class': 'netfleet-empty-note' }, '没有尚未接管的订阅。');
	return E('section', {}, [
		sectionHeading('机场', '选择参与 NetFleet 的订阅及其运行角色。'),
		compactButton('管理订阅', function() { controller.manageSubscriptions(); }),
		E('div', { 'class': 'table netfleet-config-table' }, [
			E('table', {}, [ E('thead', {}, E('tr', {}, [ E('th', {}, '参与'), E('th', {}, '机场'), E('th', {}, '真实资源'), E('th', {}, '故障层级'), E('th', {}, '计费方式'), E('th', {}, '操作') ])), E('tbody', {}, rows) ])
		]),
		addControls
	]);
}

function regions(controller) {
	const visible = visibleRegions(controller);
	const providers = controller.configDraft.providers || [];
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
			E('td', {}, status.id ? String(status.available_provider_count ?? 0) + ' 个机场 / ' + String(status.available_node_count ?? 0) + ' 个节点' : '待应用'),
			E('td', {}, E('div', { 'class': 'netfleet-region-checks' }, providers.map(function(provider) {
				const option = optionById(controller.configDraft.provider_options, provider.id);
				const supported = provider.region_ids.indexOf(region.id) >= 0 || (option && option.region_ids.indexOf(region.id) >= 0);
				return checkbox(provider.region_ids.indexOf(region.id) >= 0, provider.display_name, function(event) {
					update(controller, function(next) {
						const target = next.providers.find(function(item) { return item.id === provider.id; });
						target.region_ids = event.target.checked ? target.region_ids.concat([ region.id ]) : target.region_ids.filter(function(id) { return id !== region.id; });
					});
				}, !supported);
			}))),
			E('td', {}, select(region.mode, [ [ 'automatic', '参与自动选优' ], [ 'manual_only', '仅手动使用' ] ], function(event) {
				update(controller, function(next) { next.regions.find(function(item) { return item.id === region.id; }).mode = event.target.value; });
			})),
			E('td', {}, compactButton('移除', function() {
				update(controller, function(next) {
					next.regions = removeById(next.regions, region.id);
					next.providers.forEach(function(provider) { provider.region_ids = provider.region_ids.filter(function(id) { return id !== region.id; }); });
					next.capabilities.forEach(function(capability) { capability.region_ids = capability.region_ids.filter(function(id) { return id !== region.id; }); });
				});
			}, true))
		]);
	});
	const available = (controller.configDraft.region_options || []).filter(function(option) {
		if (visible.some(function(region) { return region.id === option.id; })) return false;
		return providers.some(function(provider) {
			const providerOption = optionById(controller.configDraft.provider_options, provider.id);
			return providerOption && providerOption.region_ids.indexOf(option.id) >= 0;
		});
	});
	let selected = available[0] ? available[0].id : '';
	const addControls = available.length ? E('div', { 'class': 'netfleet-inline-add' }, [
		select(selected, available.map(function(option) { return [ option.id, option.code + ' ' + option.display_name ]; }), function(event) { selected = event.target.value; }),
		compactButton('添加地区', function() {
			const option = optionById(controller.configDraft.region_options, selected);
			if (!option) return;
			update(controller, function(next) {
				next.regions.push({ id: option.id, flag: option.code, display_name: option.display_name, display_order: option.display_order, mode: 'automatic' });
				next.providers.forEach(function(provider) {
					const providerOption = optionById(next.provider_options, provider.id);
					if (providerOption && providerOption.region_ids.indexOf(option.id) >= 0 && provider.region_ids.indexOf(option.id) < 0)
						provider.region_ids.push(option.id);
				});
			});
		})
	]) : E('p', { 'class': 'netfleet-empty-note' }, '当前机场缓存没有更多可添加地区。');
	return E('section', {}, [
		sectionHeading('地区映射', '地区来自当前机场的真实节点；只修正识别结果，不预设必须存在的地区。'),
		E('div', { 'class': 'table netfleet-config-table' }, [
			E('table', {}, [ E('thead', {}, E('tr', {}, [ E('th', {}, '识别状态'), E('th', {}, '地区名称'), E('th', {}, '真实覆盖'), E('th', {}, '使用机场'), E('th', {}, '自动选优'), E('th', {}, '操作') ])), E('tbody', {}, rows) ])
		]),
		addControls
	]);
}

function capabilities(controller) {
	const draft = controller.configDraft;
	const groups = draft.policy_groups || [];
	function groupOwner(group, exceptId) {
		return draft.capabilities.find(function(item) {
			return item.id !== exceptId && (item.entry_group === group || (item.policy_groups || []).indexOf(group) >= 0);
		});
	}
	return E('section', {}, [
		sectionHeading('出口策略', '决定哪些业务出口由 NetFleet 增强，以及自动选择可以使用哪些地区。'),
		E('div', { 'class': 'netfleet-capability-config' }, draft.capabilities.map(function(capability) {
			const rows = [
				E('div', { 'class': 'netfleet-capability-head' }, [
					E('div', {}, [ E('input', { 'class': 'cbi-input-text', 'value': capability.display_name, 'aria-label': capability.id + ' 出口名称', 'change': function(event) {
						update(controller, function(next) { next.capabilities.find(function(item) { return item.id === capability.id; }).display_name = event.target.value; });
					} }), E('small', {}, capability.id) ]),
					E('div', {}, [ checkbox(capability.enabled, capability.enabled ? '已启用' : '已关闭', function(event) {
						update(controller, function(next) { next.capabilities.find(function(item) { return item.id === capability.id; }).enabled = event.target.checked; });
					}), compactButton('移除', function() {
						update(controller, function(next) {
							next.capabilities = removeById(next.capabilities, capability.id);
							next.capabilities.forEach(function(item) { if (item.prefer_region_from === capability.id) item.prefer_region_from = null; });
							next.routing_rules = (next.routing_rules || []).filter(function(rule) { return rule.capability !== capability.id; });
						});
					}, true) ])
				]),
				fieldRow('运行方式', null, select(capability.mode, [ [ 'automatic', '自动选优' ], [ 'manual', '手动选择' ] ], function(event) {
					update(controller, function(next) { next.capabilities.find(function(item) { return item.id === capability.id; }).mode = event.target.value; });
				}, !capability.enabled)),
				fieldRow('默认出口组', '每个已启用出口必须有一个唯一入口组。', select(capability.entry_group || '', [ [ '', '请选择' ] ].concat(groups.map(function(group) {
					const owner = groupOwner(group, capability.id);
					return [ group, owner ? group + '（已用于 ' + owner.display_name + '）' : group ];
				})), function(event) {
					update(controller, function(next) { next.capabilities.find(function(item) { return item.id === capability.id; }).entry_group = event.target.value || null; });
				}, !capability.enabled)),
				fieldRow('业务分类', '这些组仍保持原规则语义，但默认使用此出口。', E('div', { 'class': 'netfleet-region-checks' }, groups.filter(function(group) {
					return group !== capability.entry_group;
				}).map(function(group) {
					const owner = groupOwner(group, capability.id);
					const selected = (capability.policy_groups || []).indexOf(group) >= 0;
					return checkbox(selected, group, function(event) {
						update(controller, function(next) {
							const target = next.capabilities.find(function(item) { return item.id === capability.id; });
							target.policy_groups = event.target.checked ? target.policy_groups.concat([ group ]) : target.policy_groups.filter(function(item) { return item !== group; });
						});
					}, !capability.enabled || Boolean(owner));
				}))),
				fieldRow('地区限制', '取消选择的地区不会进入该出口的候选集合。',
					E('div', { 'class': 'netfleet-region-checks' }, visibleRegions(controller).map(function(region) {
						const selected = capability.region_ids.indexOf(region.id) >= 0;
						return checkbox(selected, regionalDisplayName(region.flag, region.display_name), function(event) {
							update(controller, function(next) {
								const target = next.capabilities.find(function(item) { return item.id === capability.id; });
								target.region_ids = event.target.checked ? target.region_ids.concat([ region.id ]) : target.region_ids.filter(function(id) { return id !== region.id; });
							});
						}, !capability.enabled);
						}))),
				fieldRow('地区协同', '可优先跟随另一个自动出口的地区；不合规时仍会独立选择。', select(capability.prefer_region_from || '', [ [ '', '独立选择' ] ].concat(draft.capabilities.filter(function(item) {
					return item.id !== capability.id && item.enabled && item.mode === 'automatic';
				}).map(function(item) { return [ item.id, '跟随 ' + item.display_name ]; })), function(event) {
					update(controller, function(next) { next.capabilities.find(function(item) { return item.id === capability.id; }).prefer_region_from = event.target.value || null; });
				}, !capability.enabled || capability.mode !== 'automatic'))
			];
			return E('div', { 'class': 'netfleet-capability-editor' }, rows);
		})),
		capabilityAddControls(controller, groups, groupOwner)
	]);
}

function capabilityAddControls(controller, groups, groupOwner) {
	let id = '';
	let name = '';
	let entry = groups.find(function(group) { return !groupOwner(group, null); }) || '';
	const idInput = E('input', { 'class': 'cbi-input-text', 'placeholder': '稳定 ID，如 streaming', 'input': function(event) { id = event.target.value.trim(); } });
	const nameInput = E('input', { 'class': 'cbi-input-text', 'placeholder': '显示名称', 'input': function(event) { name = event.target.value.trim(); } });
	return E('div', { 'class': 'netfleet-inline-add netfleet-capability-add' }, [
		idInput,
		nameInput,
		select(entry, [ [ '', '选择默认出口组' ] ].concat(groups.map(function(group) { return [ group, group ]; })), function(event) { entry = event.target.value; }),
		compactButton('添加出口', function() {
			if (!stableId(id) || !name || !entry || groupOwner(entry, null)) {
				ui.addNotification(null, E('p', {}, '请填写唯一稳定 ID、显示名称，并选择尚未使用的默认出口组。'), 'warning');
				return;
			}
			update(controller, function(next) {
				next.capabilities.push({ id: id, display_name: name, enabled: true, mode: 'manual', region_ids: next.regions.map(function(region) { return region.id; }), prefer_region_from: null, entry_group: entry, policy_groups: [], base_groups: [ entry ] });
			});
		})
	]);
}

function automation(controller) {
	const value = controller.configDraft.automation;
	return E('section', {}, [
		sectionHeading('自动运行', '设置重新比较出口和更新已有订阅的周期。'),
		E('div', { 'class': 'netfleet-config-rows' }, [
			fieldRow('周期选优', '关闭后仍可手动执行单次选优。', checkbox(value.enabled, value.enabled ? '已开启' : '已关闭', function(event) {
				update(controller, function(next) { next.automation.enabled = event.target.checked; });
			})),
			fieldRow('选优周期', '只在自动模式下执行同一套有界选择。', select(value.selection_interval_seconds,
				[ [ 900, '15 分钟' ], [ 1800, '30 分钟' ], [ 3600, '1 小时' ], [ 7200, '2 小时' ] ], function(event) {
					update(controller, function(next) { next.automation.selection_interval_seconds = Number(event.target.value); });
				}, !value.enabled)),
			fieldRow('定期更新订阅', null, checkbox(value.subscription_refresh_enabled,
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

function routing(controller) {
	const draft = controller.configDraft;
	let suffix = '';
	let kind = 'domain_suffix';
	let capability = draft.capabilities[0] ? draft.capabilities[0].id : '';
	const targets = [[ 'direct', '直连' ]].concat(draft.capabilities.map(function(item) { return [ item.id, item.display_name ]; }));
	const kinds = [[ 'domain_suffix', '域名后缀' ], [ 'ip_cidr', 'IP 网段' ]];
	function assignTarget(rule, value) {
		if (value === 'direct') { rule.target = 'direct'; delete rule.capability; }
		else { rule.capability = value; delete rule.target; }
	}
	const rows = (draft.routing_rules || []).map(function(rule, index) {
		return E('tr', {}, [
			E('td', {}, select(rule.kind, kinds, function(event) { update(controller, function(next) { next.routing_rules[index].kind = event.target.value; }); })),
			E('td', {}, E('input', { 'class': 'cbi-input-text', 'type': 'text', 'value': rule.value, 'aria-label': '匹配内容', 'change': function(event) {
				update(controller, function(next) { next.routing_rules[index].value = event.target.value.trim(); });
			} })),
			E('td', {}, select(rule.target === 'direct' ? 'direct' : rule.capability, targets, function(event) {
				update(controller, function(next) { assignTarget(next.routing_rules[index], event.target.value); });
			})),
			E('td', {}, compactButton('移除', function() {
				update(controller, function(next) { next.routing_rules.splice(index, 1); });
			}, true))
		]);
	});
	return E('section', {}, [
		sectionHeading('业务规则', '按域名后缀或 IP 网段指定出口，也可设为直连。'),
		E('div', { 'class': 'table netfleet-config-table' }, [
			E('table', {}, [ E('thead', {}, E('tr', {}, [ E('th', {}, '匹配类型'), E('th', {}, '匹配内容'), E('th', {}, '使用出口'), E('th', {}, '操作') ])), E('tbody', {}, rows) ])
		]),
		E('div', { 'class': 'netfleet-inline-add' }, [
			select(kind, kinds, function(event) { kind = event.target.value; }),
			E('input', { 'class': 'cbi-input-text', 'type': 'text', 'placeholder': 'example.com', 'input': function(event) { suffix = event.target.value.trim(); } }),
			select(capability, targets, function(event) { capability = event.target.value; }),
			compactButton('添加规则', function() {
				if (!suffix || !capability) {
					ui.addNotification(null, E('p', {}, '请填写匹配内容并选择出口。'), 'warning');
					return;
				}
				update(controller, function(next) { const rule = { kind: kind, value: suffix }; assignTarget(rule, capability); next.routing_rules.push(rule); });
			})
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
			E('p', {}, '最终退路：原生配置恢复失败时，停止 ' + controller.configDraft.backend.display_name + ' 并恢复网络直通。')
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
		network: management.network,
		files: management.files,
		providers: providers,
		regions: regions,
		capabilities: capabilities,
		routing: routing,
		automation: automation,
		safety: safety,
		compatibility: compatibility.render
	})[controller.configSection](controller);
}

function request(config) {
	const providers = {};
	(config.providers || []).forEach(function(item) { providers[item.id] = { section: item.section, enabled: item.enabled, role: item.role, billing: item.billing, region_ids: (item.region_ids || []).slice() }; });
	const regions = {};
	(config.regions || []).forEach(function(item) { regions[item.id] = { display_name: item.display_name, mode: item.mode }; });
	const capabilities = {};
	(config.capabilities || []).forEach(function(item) { capabilities[item.id] = { display_name: item.display_name, enabled: item.enabled, mode: item.mode, region_ids: item.region_ids.slice(), prefer_region_from: item.prefer_region_from || null, entry_group: item.entry_group || null, policy_groups: (item.policy_groups || []).slice() }; });
	return {
		revision: config.revision,
		policy_source: { kind: config.policy_source.kind, ref: config.policy_source.ref },
		recovery_profile_ref: config.recovery_profile.ref,
		providers: providers,
		regions: regions,
		capabilities: capabilities,
		routing_rules: clone(config.routing_rules || []),
		automation: clone(config.automation),
		safety: clone(config.safety)
	};
}

function dirty(controller) {
	return JSON.stringify(request(controller.configDraft)) !== JSON.stringify(request(controller.config));
}

function render(controller) {
	if (!controller.configDraft)
		return E('div', { 'class': 'alert-message warning' }, controller.configError ? [
			E('p', {}, '设备配置读取失败：' + String(controller.configError.message || controller.configError)),
			compactButton('重试', function() { return controller.loadConfig(); })
		] : '正在读取设备配置；读取完成前不会开放配置操作。');
	const changed = dirty(controller);
	const active = controller.configDraft.active === true;
	const canApply = changed || controller.config.pending_apply === true || !active;
	const independent = ['network', 'files', 'compatibility'].includes(controller.configSection);
	return E('div', { 'class': 'netfleet-config-page' }, [
		controller.configSection === 'compatibility' ? '' : E('div', { 'class': 'netfleet-config-intro' }, [
			E('div', {}, [ E('strong', {}, '设备配置'), E('span', {}, active ? '当前已接管，应用会执行受保护切换。' : '当前未接管，可先保存配置或直接应用。') ]),
			E('button', { 'class': 'btn cbi-button', 'click': function() { controller.showConfigWizard(0); } }, '首次设置向导')
		]),
		E('div', { 'class': 'netfleet-config-layout' }, [
			E('nav', { 'class': 'netfleet-config-nav', 'aria-label': '配置分类' }, SECTIONS.map(function(item) {
				return E('button', { 'class': controller.configSection === item[0] ? 'is-active' : '', 'click': function() {
					controller.configSection = item[0];
					if (item[0] === 'network') management.load(controller, 'network');
					if (item[0] === 'files') management.load(controller, 'maintenance');
					controller.redraw();
				} }, item[1]);
			})),
			E('div', { 'class': 'netfleet-config-content' }, content(controller))
		]),
		independent ? '' : E('div', { 'class': 'netfleet-config-actions' }, [
			E('span', {}, changed ? '有尚未保存的更改' : (controller.config.pending_apply ? '配置已保存，等待应用' : '设备配置与当前草稿一致')),
			E('div', {}, [
				E('button', { 'class': 'btn cbi-button', 'disabled': !changed || controller.busy || null, 'click': function() { controller.discardConfig(); } }, '放弃更改'),
				E('button', { 'class': 'btn cbi-button', 'disabled': controller.busy || null, 'click': function() { controller.validateConfig(); } }, '校验配置'),
				E('button', { 'class': 'btn cbi-button', 'disabled': controller.busy || null, 'click': function() { controller.previewConfigChanges(); } }, '查看变更'),
				E('button', { 'class': 'btn cbi-button', 'disabled': !changed || active || controller.busy || null, 'title': active ? '已接管时请直接使用“应用配置”' : '', 'click': function() { controller.saveConfig(); } }, '保存配置'),
				E('button', { 'class': 'btn cbi-button cbi-button-action', 'disabled': !canApply || controller.busy || !controller.liveDataReady || null, 'click': function() { controller.confirmConfigApply(); } }, '应用配置')
			])
		])
	]);
}

function changeText(change, controller) {
	const labels = {
		enabled: '启用状态', role: '故障层级', billing: '计费方式', mode: '运行方式', display_name: '显示名称',
		region_ids: '可用地区', policy_source: '策略基础', recovery_profile: '退出与故障恢复', item: '配置项',
		entry_group: '默认出口组', policy_groups: '业务分类', prefer_region_from: '地区协同', routing_rules: '域名规则',
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
	const groups = [ 'foundation', 'providers', 'regions', 'capabilities', 'routing', 'automation' ];
	const labels = [ '环境与恢复', '机场', '地区', '出口', '业务规则', '运行与安全' ];
	const oldSection = controller.configSection;
	controller.configSection = groups[step];
	let body = content(controller);
	controller.configSection = oldSection;
	if (step === 5)
		body = E('div', {}, [ body, safety(controller) ]);
	return [
		E('ol', { 'class': 'netfleet-wizard-steps' }, labels.map(function(label, index) {
			return E('li', { 'class': index === step ? 'is-active' : index < step ? 'is-complete' : '' }, [ E('span', {}, String(index + 1)), E('strong', {}, label) ]);
		})),
		E('div', { 'class': 'netfleet-wizard-body' }, body),
		E('div', { 'class': 'right' }, [
			E('button', { 'class': 'btn', 'click': step === 0 ? function() { ui.hideModal(); } : function() { controller.showConfigWizard(step - 1); } }, step === 0 ? '退出向导' : '上一步'),
			' ',
			step < 5 ? E('button', { 'class': 'btn cbi-button-action', 'click': function() { controller.showConfigWizard(step + 1); } }, '下一步') :
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
