/* SPDX-License-Identifier: Apache-2.0 */

const identifier = /^[a-z][a-z0-9_-]{0,63}$/;
const modulePath = /^resources\/(?:[A-Za-z0-9_-]+\/)*[A-Za-z0-9_-]+\.js$/;
const sharedEvents = new Map();

export function pluginPages(snapshot) {
  const pages = [];
  const seen = new Set();
  for (const plugin of snapshot?.plugins || []) {
    if (!identifier.test(plugin.id) || plugin.enabled === false || plugin.available === false || plugin.state === 'unavailable' || !plugin.revision) continue;
    for (const page of plugin.ui || []) {
      if (!identifier.test(page.id) || typeof page.title !== 'string' || !page.title.trim() || !modulePath.test(page.module)) continue;
      const instance = plugin.instance && plugin.instance !== 'default' ? plugin.instance : null;
      if (instance && !identifier.test(instance)) continue;
      const id = `plugin:${plugin.id}:${instance ? instance + ':' : ''}${page.id}`;
      if (seen.has(id)) continue;
      seen.add(id);
      pages.push({ id, title: instance ? `${page.title} (${instance})` : page.title, plugin, page });
    }
  }
  return pages;
}

export function resourceUrl(contribution) {
  if (!identifier.test(contribution.plugin.id) || !/^[A-Za-z0-9_-]{1,128}$/.test(contribution.plugin.revision) || !modulePath.test(contribution.page.module)) throw new Error('plugin_resource_invalid');
  return `/luci-static/resources/netfleet/plugins/${contribution.plugin.id}/${contribution.plugin.revision}/${contribution.page.module}`;
}

export function createScope(events = sharedEvents, report = () => {}) {
  let disposed = false;
  const effects = [];
  const controller = new AbortController();
  const run = async (cleanup) => {
    try { await cleanup(); } catch (error) { report(error); }
  };
  const scope = {
    signal: controller.signal,
    effect(cleanup) {
      if (typeof cleanup !== 'function') throw new TypeError('plugin_effect_requires_cleanup');
      let active = true;
      const release = () => {
        if (!active) return Promise.resolve();
        active = false;
        const index = effects.indexOf(release);
        if (index >= 0) effects.splice(index, 1);
        return run(cleanup);
      };
      if (disposed) void release();
      else effects.push(release);
      return release;
    },
    on(name, callback) {
      if (disposed) throw new Error('plugin_scope_disposed');
      let listeners = events.get(name);
      if (!listeners) events.set(name, listeners = new Set());
      listeners.add(callback);
      return scope.effect(() => {
        listeners.delete(callback);
        if (!listeners.size) events.delete(name);
      });
    },
    emit(name, value) {
      if (disposed) throw new Error('plugin_scope_disposed');
      for (const callback of [...(events.get(name) || [])]) {
        try { callback(value); } catch (error) { report(error); }
      }
    },
    scope() {
      if (disposed) throw new Error('plugin_scope_disposed');
      const child = createScope(events, report);
      scope.effect(() => child.dispose());
      return child;
    },
    timeout(callback, delay) {
      if (disposed) throw new Error('plugin_scope_disposed');
      const timer = setTimeout(() => { void release(); callback(); }, delay);
      const release = scope.effect(() => clearTimeout(timer));
      return release;
    },
    interval(callback, delay) {
      if (disposed) throw new Error('plugin_scope_disposed');
      const timer = setInterval(callback, delay);
      return scope.effect(() => clearInterval(timer));
    },
    async dispose() {
      if (disposed) return;
      disposed = true;
      controller.abort();
      for (const release of [...effects].reverse()) await release();
    },
  };
  return scope;
}

export function createPageHost({ api, readOnly = false, loadModule = url => import(/* @vite-ignore */ url), onError = () => {}, navigate = () => {} }) {
  let active = null;
  let generation = 0;
  const eventBuses = new Map();
  const dispose = async () => {
    generation++;
    const previous = active;
    active = null;
    if (previous) {
      await previous.scope.dispose();
      previous.mountContainer.remove?.();
    }
  };
  return {
    dispose,
    async show(contribution, container, state) {
      const url = resourceUrl(contribution);
      const key = `${url}|${contribution.plugin.instance || ''}`;
      if (active?.key === key && active.container === container) return;
      const version = ++generation;
      const previous = active;
      active = null;
      if (previous) {
        await previous.scope.dispose();
        previous.mountContainer.remove?.();
      }
      if (version !== generation) return;
      const instance = contribution.plugin.instance || 'default';
      if (!eventBuses.has(instance)) eventBuses.set(instance, new Map());
      const scope = createScope(eventBuses.get(instance), onError);
      const mountContainer = container.ownerDocument ? container.ownerDocument.createElement('div') : container;
      const current = { key, scope, container, mountContainer };
      active = current;
      if (mountContainer !== container) container.replaceChildren(mountContainer);
      const invoke = async (writing, action, params = {}) => {
        if (scope.signal.aborted) throw new Error('plugin_scope_disposed');
        if (writing && (typeof readOnly === 'function' ? readOnly() : readOnly)) throw new Error('plugin_read_only');
        const request = { id: contribution.plugin.id, action, params, revision: contribution.plugin.revision };
        if (contribution.plugin.instance) request.instance = contribution.plugin.instance;
        if (writing) request.confirm = true;
        const result = await (writing ? api.pluginCall(request) : api.pluginRead(request));
        if (scope.signal.aborted) throw new Error('plugin_scope_disposed');
        return result;
      };
      const configuration = contribution.plugin.configuration;
      const context = {
        container: mountContainer, signal: scope.signal, scope, state,
        navigate: (id, nextState) => navigate(id.startsWith('plugin:') ? id : contribution.id.slice(0, contribution.id.lastIndexOf(':') + 1) + id, nextState),
        get readOnly() { return typeof readOnly === 'function' ? readOnly() : readOnly; },
        api: { read: (action, params) => invoke(false, action, params), call: (action, params) => invoke(true, action, params) },
        configuration: configuration ? {
          read: params => invoke(false, configuration.read, params),
          write: params => invoke(true, configuration.write, params),
        } : null,
      };
      try {
        const module = await loadModule(url);
        if (version !== generation || scope.signal.aborted) return;
        if (typeof module.mount !== 'function') throw new Error('plugin_mount_missing');
        const cleanup = await module.mount(context);
        if (cleanup !== undefined) scope.effect(cleanup);
      } catch (error) {
        await scope.dispose();
        mountContainer.replaceChildren?.();
        if (active === current) active = null;
        if (version === generation) onError(error);
      }
    },
  };
}
