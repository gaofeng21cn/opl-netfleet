/* SPDX-License-Identifier: Apache-2.0 */

const reads = new Set(['status', 'events', 'connections', 'pluginsList', 'pluginRead', 'configGet', 'configValidate', 'networkGet', 'networkValidate', 'maintenanceGet', 'profileGet', 'backupExport', 'diagnosticsGet', 'dashboardGet', 'componentsGet', 'operationGet', 'nativeSetupGet', 'subscriptionsGet', 'migrationGet', 'onboardingGet']);
const parameters = ['baseclass', 'ui', 'poll', 'rpc', 'fs', 'request', 'resourceUrl', 'netfleet', 'api', 'product', 'managed', 'management', 'netfleetConfig', 'advanced', 'productViews', 'loadModule'];
const factories = new Map();
function loadFactory(name) {
  if (!factories.has(name)) factories.set(name, (async () => {
    const response = await fetch(new URL(name + '.js', import.meta.url));
    if (!response.ok) throw new Error('product_ui_resource_unavailable:' + name);
    return new Function(...parameters, await response.text());
  })().catch(error => { factories.delete(name); throw error; }));
  return factories.get(name);
}
const dependencies = {
  api: [], product: [], advanced: [], managed: ['api'],
  components: ['managed'], subscriptions: ['managed'],
  management: ['api', 'product', 'advanced', 'managed'], config: ['management'],
  'product-views': ['managed'], 'product-pages': ['api', 'product', 'managed', 'product-views']
};

export async function mountPage(context, pageId) {
  const resourceUrl = name => new URL(name, import.meta.url).href;
  const [baseclass, ui, poll, rpc, fs, request] = await Promise.all(['baseclass', 'ui', 'poll', 'rpc', 'fs', 'request'].map(name => L.require(name)));
  if (context.signal.aborted) return;
  const guard = transport => new Proxy(transport, { get(target, name) {
    if (typeof target[name] !== 'function') return target[name];
    return function(...params) {
      if (context.signal.aborted) return Promise.reject(new Error('plugin_scope_disposed'));
      if (context.readOnly && !reads.has(name)) return Promise.reject(new Error('plugin_read_only'));
      return target[name](...params);
    };
  } });
  const bindings = { baseclass, ui, poll, rpc, fs, request, resourceUrl };
  const instances = new Map();
  bindings.loadModule = name => {
    if (context.signal.aborted) return Promise.reject(new Error('plugin_scope_disposed'));
    if (!Object.hasOwn(dependencies, name)) return Promise.reject(new Error('product_ui_unknown_module'));
    if (!instances.has(name)) instances.set(name, Promise.all([
      loadFactory(name), ...dependencies[name].map(bindings.loadModule)
    ]).then(([factory]) => {
      if (context.signal.aborted) throw new Error('plugin_scope_disposed');
      const exported = factory(...parameters.map(key => bindings[key]));
      let value = typeof exported === 'function' ? new exported() : exported;
      if (name === 'api') { value = guard(value); bindings.netfleet = value; }
      bindings[name === 'config' ? 'netfleetConfig' : name === 'product-views' ? 'productViews' : name] = value;
      return value;
    }).catch(error => { instances.delete(name); throw error; }));
    return instances.get(name);
  };
  // Preload synchronous page renderers; dialogs load through the same scoped adapter.
  await Promise.all([
    loadFactory('product-pages'), bindings.loadModule('product'), bindings.loadModule('product-views'),
    ...(pageId === 'config' ? [bindings.loadModule('config')] : []),
    ...(pageId === 'events' ? [bindings.loadModule('management')] : []),
    ...(pageId === 'components' ? [bindings.loadModule('components').then(value => { bindings.managed.components = value.components; })] : [])
  ]);
  if (context.signal.aborted) return;
  const pages = await bindings.loadModule('product-pages');
  return pages.mount(context, pageId);
}
