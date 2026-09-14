import { createManager } from './manager.js';
import { displayCache } from './display.js';

export async function mount(context) {
  const [ui, rpc] = await Promise.all(['ui', 'rpc'].map(name => L.require(name)));
  const read = rpc.declare({ object: 'opl-netfleet.plugins', method: 'plugin_read', params: ['request'], nobatch: true });
  const call = rpc.declare({ object: 'opl-netfleet.plugins', method: 'plugin_call', params: ['request'], nobatch: true });
  const identity = async (writing, request) => {
    if (context.signal.aborted) throw new Error('plugin_scope_disposed');
    if (writing && context.readOnly) throw new Error('plugin_read_only');
    const previous = L.env.rpctimeout;
    L.env.rpctimeout = Math.max(Number(previous) || 20, writing ? 200 : 70);
    try {
      const response = await (writing ? call : read)(request);
      if (context.signal.aborted) throw new Error('plugin_scope_disposed');
      if (response?.ok !== true) throw new Error(response?.error || 'plugin_operation_failed');
      return response.result;
    } finally { L.env.rpctimeout = previous; }
  };
  if (context.signal.aborted) return;
  const api = {
    compatibilityGet: () => context.configuration.read(),
    compatibilityApply: params => context.configuration.write(params),
    compatibilityEnable: params => context.api.call('enable', params),
    compatibilityDisable: params => context.api.call('disable', params),
    compatibilityProbe: params => context.api.call('probe', params),
    compatibilityCa: () => context.api.read('public-ca'),
    pluginRead: params => identity(false, params),
    pluginCall: params => identity(true, params),
  };
  let modalOpen = false;
  const modal = Object.create(ui);
  modal.showModal = (title, contents, ...args) => {
    modalOpen = true;
    return ui.showModal(title, [E('div', { 'class': 'netfleet-https-dialog' }, contents)], ...args);
  };
  modal.hideModal = () => { modalOpen = false; return ui.hideModal(); };
  const resourceUrl = name => new URL(name, import.meta.url).href;
  const cache = displayCache('netfleet:https-display:1:' + resourceUrl('page.js'));
  const cached = cache.read();
  const manager = createManager({ api, ui: modal, resourceUrl, readOnly: () => context.readOnly || context.signal.aborted });
  const style = document.createElement('link');
  style.rel = 'stylesheet'; style.href = resourceUrl('style.css');
  const root = document.createElement('div'); root.className = 'netfleet-https-plugin';
  context.container.append(style, root);
  const controller = {
    context, compatibility: cached?.state, compatibilityLive: false,
    compatibilityAt: cached?.at, compatibilityTab: context.state?.tab || cached?.tab || 'rules',
    disposed: () => context.signal.aborted,
    remember() { cache.write(controller.compatibility, controller.compatibilityAt, controller.compatibilityTab); },
    redraw() {
      if (context.signal.aborted) return;
      const focus = root.contains(document.activeElement) ? document.activeElement : null;
      const keyOf = node => node && JSON.stringify([node.closest('[data-row-key]')?.getAttribute('data-row-key'),
        node.tagName, node.getAttribute('aria-label') || (node.tagName === 'DETAILS' ? node.querySelector('summary')?.textContent : node.textContent)]);
      const key = keyOf(focus);
      const expanded = [...root.querySelectorAll('details[open]')].map(keyOf);
      root.replaceChildren(manager.render(controller));
      for (const node of root.querySelectorAll('details')) if (expanded.includes(keyOf(node))) node.open = true;
      if (key) [...root.querySelectorAll('button,input,a,summary')].find(node => keyOf(node) === key)?.focus({ preventScroll: true });
    },
  };
  let timer;
  controller.follow = () => {
    clearTimeout(timer);
    if (document.hidden || context.signal.aborted) return;
    const state = controller.compatibility;
    // Availability changes asynchronously, including reasons unknown to this UI.
    // A displayed bypass is never grounds for abandoning current-state readback.
    const draining = state?.active_connections > 0 && !state.requested;
    if (controller.compatibilityLive === false || state?.requested || draining) {
      const interval = draining || state?.requested && !state.intercepting ? 3000 : 10000;
      timer = setTimeout(() => void manager.refresh(controller), interval);
    }
  };
  const visibility = () => { clearTimeout(timer); if (!document.hidden) void manager.refresh(controller); };
  document.addEventListener('visibilitychange', visibility);
  context.scope.effect(() => {
    clearTimeout(timer); document.removeEventListener('visibilitychange', visibility);
    if (modalOpen) ui.hideModal(); style.remove(); root.remove();
  });
  controller.redraw();
  void manager.refresh(controller);
}
