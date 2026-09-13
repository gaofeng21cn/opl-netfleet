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
    this.current = this.module.pageFromHash(window.location.hash, this.pages);
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
    this.locationChanged = function() {
      const id = self.module.pageFromHash(window.location.hash, self.pages);
      if (id !== self.current) { self.current = id; self.navigationState = undefined; self.redraw(); }
    };
    window.addEventListener('hashchange', this.locationChanged);
    this.redraw();
    this.pluginPoll = function() { return self.refreshPlugins(); };
    poll.add(this.pluginPoll, 5);
    const dispose = function() { window.removeEventListener('hashchange', self.locationChanged); poll.remove(self.pluginPoll); void self.host.dispose(); };
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
    if (id === 'plugins') id = this.module.pluginNavigation(this.pages).directoryId;
    if (id !== 'plugins' && !this.pages.some(function(page) { return page.id === id; })) return;
    if (id === this.current && state === undefined) return;
    this.current = id;
    this.navigationState = state;
    const hash = this.module.pageHash(id);
    if (window.location.hash !== hash) window.location.hash = hash;
    this.pageContainer = null;
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
      if (self.current !== 'plugins' && !self.pages.some(function(page) { return page.id === self.current; })) {
        self.current = self.module.pluginNavigation(self.pages).defaultId; self.navigationState = undefined;
      }
      if (changed || hadError) self.redraw();
    }).catch(function(error) { self.error = error; self.redraw(); }).finally(function() { self.reading = null; });
    return this.reading;
  },
  redraw: function() {
    const self = this;
    const navigation = this.module.pluginNavigation(this.pages);
    const selected = this.pages.find(function(page) { return page.id === self.current; });
    const key = selected ? this.module.resourceUrl(selected) + '|' + (selected.plugin.instance || 'default') : null;
    if (!selected || this.pageKey !== key || !this.pageContainer) {
      this.pageKey = key;
      this.pageContainer = E('section', { 'class': 'netfleet-plugin-page', 'aria-label': selected?.title || 'NetFleet' });
      if (selected) {
        this.pageContainer.appendChild(E('p', { 'class': 'spinning', 'role': 'status' }, '正在加载…'));
        void this.host.show(selected, this.pageContainer, this.navigationState);
      } else {
        void this.host.dispose();
        this.pageContainer.appendChild(E('p', {}, '选择插件打开配置页面。'));
        this.pageContainer.appendChild(E('div', { 'class': 'netfleet-plugin-directory' }, navigation.groups.map(function(group) {
          return E('section', { 'class': 'cbi-section' }, [ E('h3', {}, group.title + (group.instance && group.instance !== 'default' ? ' · ' + group.instance : '')),
            E('div', {}, group.pages.map(function(page) { return E('button', { 'type': 'button', 'class': 'btn cbi-button', 'click': function() { self.navigate(page.id); } }, page.title); })) ]);
        })));
        if (!navigation.groups.length) this.pageContainer.appendChild(E('p', { 'role': 'status' }, '暂无已启用的插件配置页'));
      }
    }
    const extensionSelected = selected && selected.page.navigation !== 'primary';
    const tabs = E('ul', { 'class': 'netfleet-primary-nav', 'aria-label': 'NetFleet 导航' }, navigation.primary.map(function(page) {
      return E('li', { 'class': (page.id === self.current || extensionSelected && page.id === navigation.directoryId) ? 'is-current' : '' }, E('a', {
        'href': self.module.pageHash(page.id), 'aria-current': page.id === self.current ? 'page' : null, 'click': function(event) { if (event.ctrlKey || event.metaKey || event.shiftKey || event.altKey) return; event.preventDefault(); self.navigate(page.id); }
      }, page.title));
    }));
    if (navigation.directoryId === 'plugins') tabs.appendChild(E('li', { 'class': !selected || selected.page.navigation !== 'primary' ? 'is-current' : '' }, E('a', { 'href': '#', 'click': function(event) { event.preventDefault(); self.navigate('plugins'); } }, '插件')));
    const group = navigation.groups.find(function(value) { return value.pages.some(function(page) { return page.id === self.current; }); });
    const subnav = group ? E('nav', { 'class': 'netfleet-plugin-subnav', 'aria-label': '插件页面' }, [
      E('button', { 'type': 'button', 'class': 'btn cbi-button', 'click': function() { self.navigate(navigation.directoryId); } }, navigation.directoryId === 'plugins' ? '← 插件' : '← 插件与更新'),
      ...group.pages.map(function(page) { return E('button', { 'type': 'button', 'class': 'btn cbi-button', 'aria-current': page.id === self.current ? 'page' : null, 'click': function() { self.navigate(page.id); } }, page.title); })
    ]) : E('span');
    const warning = this.error ? E('div', { 'class': 'alert-message warning', 'role': 'alert' }, [
      E('p', {}, '插件清单读取失败：' + String(this.error.message || this.error)),
      E('button', { 'class': 'btn cbi-button', 'type': 'button', 'click': function() { return self.refreshPlugins(); } }, '重新读取')
    ]) : E('span');
    this.root.replaceChildren(E('style', {}, this.module.pluginHostStyles), tabs, subnav, warning, this.pageContainer);
    // Only scroll the navigation strip; scrollIntoView would also move the page.
    requestAnimationFrame(function() {
      const active = tabs.querySelector('.is-current');
      if (active && tabs.scrollWidth > tabs.clientWidth) {
        const item = active.getBoundingClientRect(), strip = tabs.getBoundingClientRect();
        if (item.left < strip.left) tabs.scrollLeft -= strip.left - item.left;
        else if (item.right > strip.right) tabs.scrollLeft += item.right - strip.right;
      }
    });
  },
  handleSaveApply: null,
  handleSave: null,
  handleReset: null
});
