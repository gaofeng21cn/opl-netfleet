import { createManager } from './manager.js';

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
  modal.showModal = (...args) => { modalOpen = true; return ui.showModal(...args); };
  modal.hideModal = () => { modalOpen = false; return ui.hideModal(); };
  const resourceUrl = name => new URL(name, import.meta.url).href;
  const manager = createManager({ api, ui: modal, resourceUrl, readOnly: () => context.readOnly || context.signal.aborted });
  const style = document.createElement('link');
  style.rel = 'stylesheet'; style.href = resourceUrl('style.css');
  const root = document.createElement('div'); root.className = 'netfleet-https-plugin';
  context.container.append(style, root);
  const controller = {
    context, currentView: 'components', componentDetail: 'https-compat',
    compatibilityTab: context.state?.tab || 'rules',
    redraw() { if (!context.signal.aborted) root.replaceChildren(manager.render(controller)); },
  };
  context.scope.effect(() => { if (modalOpen) ui.hideModal(); style.remove(); root.remove(); });
  controller.redraw();
  await manager.refresh(controller);
  if (context.signal.aborted) return;
  const interval = setInterval(() => { if (!context.signal.aborted) void manager.refresh(controller); }, 5000);
  context.scope.effect(() => clearInterval(interval));
}
