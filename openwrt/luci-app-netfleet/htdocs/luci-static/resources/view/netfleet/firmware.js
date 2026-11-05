'use strict';
'require view';
'require view.attendedsysupgrade.overview as attended';
'require fs';
'require ui';
'require poll';

// Keep upstream ASU version selection, package migration and build monitoring.
// Only feed metadata and the device-local install/preservation step differ.
const HELPER = '/usr/libexec/opl-netfleet-firmware';
function invoke(action, args) {
 return fs.exec(HELPER, [action].concat(args || [])).then(function(reply) {
  if (reply.code !== 0) throw new Error(_('System update preparation failed. Check the device update log.'));
  return JSON.parse(reply.stdout || '{}');
 });
}
// View imports create and mount the upstream instance. Decorate its request
// and install methods; creating a second view would race its rendering.
const upstreamRequest = attended.handleRequest;
attended.handleRequest = function(server, main, content, data, firmware) {
 if (!main || !content.version || this.request_hash.get(server))
  return upstreamRequest.apply(this, arguments);
 this.targetVersion = content.version;
 const args = Array.from(arguments);
 return invoke('describe').then(function(metadata) {
  if (Array.isArray(content.packages))
   content.packages = content.packages.filter(name => !metadata.excluded.includes(name));
  else
   for (const name of metadata.excluded) delete content.packages[name];
  content.repositories = metadata.repositories;
  content.repositories_mode = metadata.repositories_mode;
  content.repository_keys = metadata.repository_keys;
  return upstreamRequest.apply(this, args);
 }.bind(this)).catch(function(error) {
  if (this.pollFn) poll.remove(this.pollFn);
  ui.hideModal();
  ui.addNotification(null, E('p', error.message));
 }.bind(this));
};
attended.handleInstall = function(url, keep, digest) {
  if (!keep) {
   ui.addNotification(null, E('p', _('This update requires keeping the current configuration.')));
   return;
  }
  ui.showModal(_('Updating OpenWrt'), [
   E('p', { class: 'spinning' }, _('The device is downloading and verifying the update. You may close this page.'))
  ]);
  return invoke('install', [url, digest, this.targetVersion]).then(function() {
   const monitor = function() {
    return invoke('status').then(function(state) {
     if (state.phase === 'failed') {
      poll.remove(monitor);
      ui.showModal(_('Update failed'), [
       E('p', _('Check the device update log before retrying.')),
       E('div', { class: 'right' }, E('button', { class: 'btn', click: ui.hideModal }, _('Close')))
      ]);
     } else if (state.phase === 'installing') {
      poll.remove(monitor);
      ui.showModal(_('Installing'), [E('p', { class: 'spinning' }, _('The device will restart. Waiting for it to reconnect.'))]);
      setTimeout(function() { ui.awaitReconnect(); }, 10000);
     }
    });
   };
   poll.add(monitor, 2);
  }).catch(function(error) {
   ui.hideModal();
   ui.addNotification(null, E('p', error.message));
  });
};
// The upstream view owns the sole renderer and normal ASU interactions.
return view.extend({
 __init__: function() {},
 handleSaveApply: null,
 handleSave: null,
 handleReset: null
});
