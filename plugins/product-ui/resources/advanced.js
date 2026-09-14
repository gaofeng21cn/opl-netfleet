/* SPDX-License-Identifier: Apache-2.0 */
'use strict';
'require baseclass';
'require ui';

function format(value) { return value == null ? '由核心默认值决定' : typeof value === 'object' ? JSON.stringify(value) : String(value); }
function render(controller) {
  const state = controller.networkState;
  const fields = state.resources.advanced_fields || [];
  if (!fields.length) return '';
  const draft = controller.networkDraft.advanced;
  const sources = { platform: '平台配置', override: '用户覆写', profile: '当前 Profile', core_default: '核心默认' };
  function editor(field) {
    const value = draft[field.id];
    const explanation = (state.explanation || []).find(item => item.id === field.id) || {};
    const change = next => { draft[field.id] = next; delete (controller.networkDraftErrors || {})[field.id]; };
    let control;
    if (field.kind === 'bool' || field.kind === 'enum') {
      const options = [[null, '继承 Profile / 核心默认值']].concat(field.kind === 'bool' ? [[true, '开启'], [false, '关闭']] : field.options.map(value => [value, value]));
      control = E('select', { class: 'cbi-input-select', 'aria-label': field.label, change: event => {
        change(event.target.value === '' ? null : field.kind === 'bool' ? event.target.value === 'true' : event.target.value);
      } }, options.map(option => E('option', { value: option[0] == null ? '' : String(option[0]), selected: value === option[0] || null }, option[1])));
    } else if (field.kind === 'list' || field.kind === 'sniff') {
      control = E('textarea', { class: 'cbi-input-textarea', rows: 3, 'aria-label': field.label, input: event => {
        if (field.kind === 'list') { change(event.target.value.split(/\r?\n/).map(value => value.trim()).filter(Boolean)); event.target.setCustomValidity(''); }
        else { try { change(event.target.value.trim() ? JSON.parse(event.target.value) : null); event.target.setCustomValidity(''); }
          catch (_) { controller.networkDraftErrors ||= {}; controller.networkDraftErrors[field.id] = field.label + '：请输入有效 JSON'; event.target.setCustomValidity('请输入有效 JSON'); } }
      } }, value == null ? '' : field.kind === 'list' ? value.join('\n') : JSON.stringify(value, null, 2));
    } else {
      control = E('input', { class: 'cbi-input-text', type: field.kind === 'int' ? 'number' : 'text', value: value == null ? '' : value,
        min: field.min, max: field.max, placeholder: '继承 Profile / 核心默认值', 'aria-label': field.label,
        input: event => change(event.target.value === '' ? null : field.kind === 'int' ? Number(event.target.value) : event.target.value) });
    }
    return E('div', { class: 'netfleet-config-row' }, [ E('div', {}, [ E('strong', {}, field.label),
      E('p', {}, '读取时来源：' + (sources[explanation.source] || '未提供')),
      E('small', {}, '配置值：' + format(explanation.configured) + '；运行值：' + (explanation.active ? format(explanation.running) : '未运行')) ]),
      E('div', { class: 'netfleet-config-control' }, [control, E('button', { type: 'button', class: 'btn cbi-button', click: () => { change(null); controller.redraw(); } }, '恢复继承')]) ]);
  }
  const groups = [...new Set(fields.map(field => field.group))];
  return E('details', { class: 'netfleet-management-section' }, [ E('summary', {}, 'Mihomo 高级设置'),
    E('p', {}, '修改后先校验，再应用。空值表示继承 Profile 或核心默认值；来源和运行值来自最近一次设备读取。'),
    ...groups.map(group => E('section', {}, [ E('h4', {}, group), ...fields.filter(field => field.group === group).map(editor) ])),
    E('button', { type: 'button', class: 'btn cbi-button', click: () => {
      const text = E('textarea', { class: 'cbi-input-textarea', rows: 18, 'aria-label': '高级参数 JSON' }, JSON.stringify(draft, null, 2));
      const problem = E('p', { role: 'alert' });
      ui.showModal('专家编辑', [ E('p', {}, '与高级表单编辑同一份草稿。使用已列出的参数名；省略的参数保持不变，null 恢复继承。尚未保存或应用。'), text, problem,
        E('div', { class: 'right' }, [ E('button', { class: 'btn cbi-button', click: ui.hideModal }, '取消'),
          E('button', { class: 'btn cbi-button-action', click: () => {
            try { const next = JSON.parse(text.value); if (!next || Array.isArray(next) || typeof next !== 'object') throw new Error('请输入 JSON 对象');
              controller.networkDraft.advanced = { ...draft, ...next }; controller.networkDraftErrors = {}; ui.hideModal(); controller.redraw(); }
            catch (error) { problem.textContent = 'JSON 无效：' + error.message; }
          } }, '更新草稿') ]) ]);
    } }, '专家 JSON 编辑') ]);
}
function preview(result) {
  const changes = result && result.changes || [];
  return E('div', {}, [ E('p', {}, result && result.restart_required ? '校验通过；应用时需要重启核心。' : '校验通过；应用只保存配置。'),
    ...changes.map(item => E('p', {}, item.label + '：' + format(item.before) + ' → ' + format(item.after) + (item.category === 'network' ? '' : item.inherited ? '（恢复继承）' : '（用户覆写）'))) ]);
}
function valid(controller) {
  const errors = Object.values(controller.networkDraftErrors || {});
  if (!errors.length) return true;
  ui.addNotification(null, E('p', {}, errors.join('；')), 'error');
  return false;
}
return baseclass.extend({ render, preview, valid });
