import { createManager } from './manager.js';
import { displayCache } from './display.js';

export async function mount(context) {
  const [ui, transport] = await Promise.all(['ui', 'netfleet.api'].map(name => L.require(name)));
  if (context.signal.aborted) return;
  const api = {
    compatibilityGet: () => context.configuration.read(),
    compatibilityApply: params => context.configuration.write(params),
    compatibilityEnable: params => context.api.call('enable', params),
    compatibilityDisable: params => context.api.call('disable', params),
    compatibilityProbe: params => context.api.call('probe', params),
    compatibilityCa: () => context.api.read('public-ca'),
    pluginRead: params => transport.pluginRead(params),
    pluginCall: params => context.readOnly || context.signal.aborted
      ? Promise.reject(new Error('plugin_read_only')) : transport.pluginCall(params),
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
  let timer, deadline = 0;
  controller.follow = () => {
    clearTimeout(timer);
    const state = controller.compatibility;
    const pending = state && ((!state.requested && state.active_connections > 0) ||
      state.requested && ['disabled', 'not_ready', 'recovering', 'rules_recovering', 'engine_config_pending', 'engine_starting', 'engine_restarted'].includes(state.reason) ||
      state.reason === 'draining');
    if (!pending) { deadline = 0; return; }
    if (!deadline) deadline = Date.now() + 120000;
    if (Date.now() < deadline && !document.hidden && !context.signal.aborted)
      timer = setTimeout(() => void manager.refresh(controller), 3000);
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
