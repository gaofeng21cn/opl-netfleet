/* SPDX-License-Identifier: Apache-2.0 */
'use strict';
'require view';
'require poll';
'require netfleet.api as api';

return view.extend({
  load: function() {
    return Promise.all([
      import(L.resource('netfleet/plugin-host.js')),
      api.pluginsList().then(function(snapshot) { return { snapshot: snapshot }; }, function(error) { return { error: error }; })
    ]);
  },
  render: function(initial) {
    const self = this;
    this.module = initial[0];
    this.snapshot = initial[1].snapshot || { plugins: [] };
    this.error = initial[1].error || null;
    this.pages = this.module.pluginPages(this.snapshot);
    this.current = this.pages[0]?.id || null;
    this.root = E('div', { 'class': 'netfleet-plugin-shell' });
    this.pageContainer = null;
    this.host = this.module.createPageHost({
      api: api,
      readOnly: function() { return !!self.error || L.hasViewPermission?.() !== true; },
      navigate: function(id, state) { self.navigate(id, state); },
      onError: function(error) {
        if (self.pageContainer) self.pageContainer.replaceChildren(E('div', { 'class': 'alert-message warning', 'role': 'alert' }, [
          E('p', {}, '插件页面加载失败：' + String(error.message || error)),
          E('button', { 'class': 'btn cbi-button', 'type': 'button', 'click': function() { self.pageContainer = null; self.redraw(); } }, '重试')
        ]));
      }
    });
    this.redraw();
    this.pluginPoll = function() { return self.refreshPlugins(); };
    poll.add(this.pluginPoll, 5);
    const dispose = function() { poll.remove(self.pluginPoll); void self.host.dispose(); };
    window.addEventListener('pagehide', dispose, { once: true });
    this.observer = new MutationObserver(function() {
      if (self.root.isConnected) self.wasConnected = true;
      else if (self.wasConnected) {
        dispose(); self.observer.disconnect(); window.removeEventListener('pagehide', dispose);
      }
    });
    this.observer.observe(document.body, { childList: true, subtree: true });
    return this.root;
  },
  navigate: function(id, state) {
    if (!this.pages.some(function(page) { return page.id === id; })) return;
    this.current = id;
    this.navigationState = state;
    this.redraw();
  },
  refreshPlugins: function() {
    const self = this;
    if (this.reading) return this.reading;
    this.reading = api.pluginsList().then(function(snapshot) {
      const changed = JSON.stringify(snapshot) !== JSON.stringify(self.snapshot);
      const hadError = !!self.error;
      self.snapshot = snapshot;
      self.pages = self.module.pluginPages(snapshot);
      self.error = null;
      if (!self.pages.some(function(page) { return page.id === self.current; })) self.current = self.pages[0]?.id || null;
      if (changed || hadError) self.redraw();
    }).catch(function(error) { self.error = error; self.redraw(); }).finally(function() { self.reading = null; });
    return this.reading;
  },
  redraw: function() {
    const self = this;
    const selected = this.pages.find(function(page) { return page.id === self.current; });
    const key = selected ? this.module.resourceUrl(selected) + '|' + (selected.plugin.instance || 'default') : null;
    if (this.pageKey !== key || !this.pageContainer) {
      this.pageKey = key;
      this.pageContainer = E('section', { 'class': 'netfleet-plugin-page', 'aria-label': selected?.title || 'NetFleet' });
      if (selected) {
        this.pageContainer.appendChild(E('p', { 'class': 'spinning', 'role': 'status' }, '正在加载…'));
        void this.host.show(selected, this.pageContainer, this.navigationState);
      } else {
        void this.host.dispose();
        this.pageContainer.appendChild(E('p', {}, '暂无已启用的界面插件'));
      }
    }
    const tabs = E('ul', { 'class': 'cbi-tabmenu' }, this.pages.map(function(page) {
      return E('li', { 'class': page.id === self.current ? 'cbi-tab' : 'cbi-tab-disabled' }, E('a', {
        'href': '#', 'click': function(event) { event.preventDefault(); self.navigate(page.id); }
      }, page.title));
    }));
    const warning = this.error ? E('div', { 'class': 'alert-message warning', 'role': 'alert' }, [
      E('p', {}, '插件清单读取失败：' + String(this.error.message || this.error)),
      E('button', { 'class': 'btn cbi-button', 'type': 'button', 'click': function() { return self.refreshPlugins(); } }, '重新读取')
    ]) : E('span');
    this.root.replaceChildren(E('h2', {}, 'NetFleet'), tabs, warning, this.pageContainer);
  },
  handleSaveApply: null,
  handleSave: null,
  handleReset: null
});
