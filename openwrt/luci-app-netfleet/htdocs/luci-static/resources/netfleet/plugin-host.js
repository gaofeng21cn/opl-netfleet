/* SPDX-License-Identifier: Apache-2.0 */

const identifier = /^[a-z][a-z0-9_-]{0,63}$/;
const modulePath = /^resources\/(?:[A-Za-z0-9_-]+\/)*[A-Za-z0-9_-]+\.js$/;
const sharedEvents = new Map();

export const pluginHostStyles = `
.netfleet-shell-brand { font-weight: 700; font-size: 15px; padding: 0 0 12px; }
.netfleet-plugin-shell > .cbi-tabmenu { display: flex; flex-wrap: wrap; gap: 4px; padding: 0; margin: 0 0 20px; }
.netfleet-plugin-shell { min-width: 0; }
.netfleet-plugin-shell > .cbi-tabmenu > li { margin: 0 !important; padding: 0 !important; border: 0 !important; background: transparent !important; box-shadow: none !important; }
.netfleet-plugin-shell > .cbi-tabmenu > li > a { display: block; padding: 9px 14px; border-bottom: 3px solid transparent; }
.netfleet-plugin-shell > .cbi-tabmenu > .cbi-tab > a { border-bottom-color: var(--primary, #5e72e4); color: var(--primary, #5e72e4); background: var(--primary-color-low, rgba(94,114,228,.1)); }
.netfleet-plugin-directory, .nf-plugin-directory { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(100%, 280px), 1fr)); gap: 16px; }
.nf-plugin-directory > p { grid-column: 1 / -1; }
.netfleet-plugin-directory > section, .nf-plugin-directory > section { margin: 0; padding: 20px; background: var(--nf-surface, #fff); border: 1px solid var(--nf-border, #ddd); border-radius: 6px; }
.netfleet-plugin-directory h3, .nf-plugin-directory h2 { margin: 0 0 16px; padding: 0; border: 0; font-size: 17px; }
.netfleet-plugin-directory button, .nf-plugin-directory button, .netfleet-plugin-subnav button { margin: 0 8px 8px 0; min-height: 40px; }
.netfleet-plugin-subnav { margin: 16px 0; display: flex; flex-wrap: wrap; gap: 8px; }
.netfleet-plugin-subnav [aria-current=page] { font-weight: 600; }
[data-netfleet-theme=dark] .netfleet-plugin-shell > .cbi-tabmenu > .cbi-tab > a { color: var(--primary-color-high, #a5b2ff); border-bottom-color: currentColor; }
@media (max-width: 700px) {
  .netfleet-plugin-shell > .netfleet-shell-brand { display: none; }
  .netfleet-plugin-shell > .cbi-tabmenu { flex-wrap: nowrap; gap: 0; width: 100%; min-height: 0; margin: 0 0 16px !important; padding: 0 !important; overflow-x: auto; overscroll-behavior-x: contain; scrollbar-width: thin; }
  .netfleet-plugin-shell > .cbi-tabmenu > li { flex: 0 0 auto; float: none; height: auto; min-height: 0; }
  .netfleet-plugin-shell > .cbi-tabmenu > li > a { display: flex; align-items: center; min-height: 44px; padding: 8px 12px !important; margin: 0 !important; white-space: nowrap; font-size: 15px; line-height: 1.4; }
  .netfleet-plugin-subnav { flex-wrap: nowrap; overflow-x: auto; }
  .netfleet-plugin-subnav button { flex-shrink: 0; }
}
`;

export function pluginPages(snapshot) {
  const pages = [];
  const seen = new Set();
  for (const plugin of [...(snapshot?.plugins || [])].sort((a, b) => `${a.id}:${a.instance || ''}`.localeCompare(`${b.id}:${b.instance || ''}`))) {
    if (!identifier.test(plugin.id) || plugin.enabled === false || plugin.available === false || plugin.state === 'unavailable' || !plugin.revision) continue;
    for (const page of plugin.ui || []) {
      if (!['primary', 'plugin'].includes(page.navigation ?? 'plugin')) continue;
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

// Navigation is shared by the LuCI and React hosts; business pages remain plugin-owned.
export function pluginNavigation(pages) {
  const primary = pages.filter(item => item.page.navigation === 'primary');
  const groups = [];
  for (const item of pages.filter(item => item.page.navigation !== 'primary')) {
    const key = `${item.plugin.id}:${item.plugin.instance || 'default'}`;
    let group = groups.find(value => value.id === key);
    if (!group) {
      group = { id: key, title: item.plugin.label || item.plugin.id, instance: item.plugin.instance, pages: [] };
      groups.push(group);
    }
    group.pages.push(item);
  }
  return { primary, groups, directoryId: primary.find(item => item.page.id === 'components')?.id || 'plugins', defaultId: primary[0]?.id || 'plugins' };
}

// Only installed page identities enter the URL; drafts and device data stay in memory.
export function pageHash(id) { return '#/netfleet/' + encodeURIComponent(id); }
export function pageFromHash(hash, pages) {
  const fallback = pluginNavigation(pages).defaultId;
  if (!String(hash || '').startsWith('#/netfleet/')) return fallback;
  try {
    const id = decodeURIComponent(hash.slice('#/netfleet/'.length));
    if (id === 'plugins') return pluginNavigation(pages).directoryId;
    return pages.some(page => page.id === id) ? id : fallback;
  } catch (_) { return fallback; }
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
