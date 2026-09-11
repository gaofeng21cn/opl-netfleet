#!/usr/bin/ucode
import * as fs from 'fs';
import { use, release } from './services.uc';
import { create_history } from '../openwrt/files/usr/libexec/opl-netfleet/plugins/subscriptions/lib/history.uc';

const root = fs.realpath(replace(sourcepath(), /[^/]+$/, '../openwrt/files/usr/libexec/opl-netfleet'));
const workspace = fs.mkdtemp('/tmp/netfleet-refresh-history.XXXXXX');
const path = `${workspace}/subscription-history.json`;
const model = use('models.subscription');
const events = use('events.model');
let log = { schema_version: 1, events: [] }, assertions = 0;
function check(ok, message) { if (!ok) die(message); assertions++; };
const ports = {
 'platform.paths': { SUBSCRIPTION_HISTORY_PATH: path },
 'platform.storage': use('platform.storage'),
 'platform.files': use('platform.files'),
 'events.store': { read_events: () => log },
 'events.model': events,
 'models.subscription': model
};
const history_factory = create_history;
function reopen() { return history_factory({use: name => ports[name]}); };
function event(at, ok, reason) {
 return {at, action: 'refresh', ok, reason: reason ?? (ok ? 'unchanged' : 'upstream_unavailable'),
  initiator: 'supervisor', subscriptions: [{section: 'alpha', result: ok ? 'unchanged' : 'failed'}]};
};
const now = int(time());
let history = reopen();
try {
 check(history.read() == null && model.refresh_due_at(history.read(), 86400) == null, 'no trustworthy baseline is due immediately');
 log = events.append(log, [event(now - 172800, true)]);
 check(history.read().subscriptions.alpha.last_success == now - 172800 && history.read().last_success_at == null,
  'legacy evidence preserves known success without inventing full-refresh scope');
 check(history.record(event(now - 86000, true), true), 'actual atomic history write succeeds');
 for (let i = 0; i < 256; i++) log = events.append(log, [{at: now, action: 'select', reason: 'fixture'}]);
 history = reopen();
 check(length(log.events) == 128 && history.read().last_success_at == now - 86000,
  'reopened owner retains success after all refresh events have rolled out');
 check(model.refresh_due_at(history.read(), 86400) == now + 400, 'restart retains the original daily deadline');
 check(model.refresh_due_at(history.read(), 3600) == now - 82400, 'changed interval uses the same success baseline');
 check(history.record(event(now - 100, false), true), 'failed attempt persists');
 history = reopen();
 check(history.read().last_success_at == now - 86000 && history.read().subscriptions.alpha.last_success == now - 86000,
  'failure does not overwrite global or source success');
 check(model.refresh_due_at(history.read(), 86400) == now + 200, 'failure retry deadline survives restart');
 const rollback = event(now - 50, false, 'rollback_restored');
 rollback.subscriptions[0].result = 'updated';
 check(history.record(rollback, true) && history.read().subscriptions.alpha.last_success == now - 86000,
  'download followed by rollback is not an accepted source update');
 check(history.record(event(now, true), false), 'single-source manual success persists');
 check(history.read().subscriptions.alpha.last_success == now && history.read().last_success_at == now - 86000 &&
  model.refresh_due_at(history.read(), 86400) == now + 250, 'manual source refresh does not postpone the fleet schedule');
 const projection = model.project({subscription_refresh_enabled: true, subscription_refresh_interval_seconds: 86400}, [], history.read());
 check(projection.last_success_at == now - 86000 && projection.last_run_at == now - 50 && projection.next_run_at == now + 250,
  'status uses persisted success, attempt, and the same scheduling deadline');

 // Exercise the shipped scheduler through a fresh factory, using persisted owner state.
 let commands = [], locked = false;
 const config = {subscription_refresh_enabled: true, subscription_refresh_interval_seconds: 86400,
  enabled: false, selection_interval_seconds: 1800, poll_interval_seconds: 15, runtime_grace_seconds: 45};
 ports['subscriptions.facts'] = {read_history: () => reopen().read()};
 ports['platform.documents'] = {load_policy: () => ({main: {enabled: true}})};
 ports['platform.profile'] = {current_profile: () => 'active', backend_enabled: () => true};
 ports['platform.credentials'] = {api_secret: () => 'fixture'};
 ports['platform.process'] = {run_owner: (action, trigger) => {
  if (locked) return false;
  push(commands, action);
  if (action == 'refresh') history.record(event(int(time()), true), true);
  return true;
 }};
 ports['mihomo.backend'] = {running: () => true, lan_runtime_state: () => ({transparent_proxy_ready: true, dns_ready: true})};
 ports['mihomo.controller'] = {controller_ready: () => true};
 ports['models.policy'] = {automation: () => config, guard_probe_url: () => 'fixture'};
 ports['models.activation'] = {is_active: () => true};
 ports['recovery.state'] = {pending: () => null};
 const scheduler_factory = loadfile(`${root}/plugins/scheduler/lib/control.uc`)();
 function restart_scheduler() { return scheduler_factory({use: name => ports[name]}).tick(null); };
 restart_scheduler();
 check(length(commands) == 0, 'process restart before persisted deadline does not refresh early');
 history.record(event(now - 90000, true), true);
 locked = true;
 restart_scheduler();
 check(length(commands) == 0 && history.read().last_success_at == now - 90000, 'busy writer does not advance the deadline');
 locked = false;
 restart_scheduler();
 check(join(',', commands) == 'refresh', 'overdue restart invokes the real refresh owner once');
 restart_scheduler();
 check(length(commands) == 1, 'another restart uses the committed completion time');
 history.record(event(now - 90000, true), true);
 history.record(event(now - 600, false), true);
 restart_scheduler();
 check(length(commands) == 2, 'failed full refresh retries after its persisted backoff');

 // Follow the shipped refresh transaction's real early-failure path.
 ports['subscriptions.facts'] = {read_history: history.read, record_history: history.record};
 ports['platform.runtime'] = {KIND: 'native-mihomo'};
 ports['platform.device'] = {upstream_ready: () => false};
 ports['events.operation'] = {begin: () => {}, update: () => {}};
 ports['events.store'].write_events = value => { log = value; return true; };
 ports['events.record'] = loadfile(`${root}/plugins/events/lib/record.uc`)()({use: name => ports[name]});
 let output;
 ports['events.output'] = {ok: (action, result) => { output = result; }, fail: (action, error) => die(error)};
 const refresh = loadfile(`${root}/plugins/refresh/lib/control.uc`)()({use: name => ports[name] ?? {}});
 const success_before = history.read().last_success_at;
 refresh.refresh_action({providers: {alpha: {enabled: true, section: 'alpha'}}}, null, 'scheduled');
 check(output?.state == 'failed' && reopen().read().latest.reason == 'upstream_unavailable' &&
  reopen().read().last_success_at == success_before, 'actual refresh command records failure while preserving accepted update');
 check(model.refresh_due_at(reopen().read(), 86400) == reopen().read().latest.at + 300,
  'failure in the same second as success still uses retry backoff');

 // A full disk must not interrupt recovery after a failed rollback.
 let recovered = false;
 ports['platform.paths'].REFRESH_DIR = `${workspace}/snapshot`;
 ports['platform.process'].shell_quote = use('platform.process').shell_quote;
 ports['recovery.control'] = {restore_recovery_with_probes: () => { recovered = true; return {ok: true}; }};
 ports['subscriptions.facts'] = {read_history: () => history.read(), record_history: () => false};
 const failing_writer = loadfile(`${root}/plugins/refresh/lib/control.uc`)()({use: name => ports[name] ?? {}});
 let write_rejected = false;
 try {
  failing_writer.fail_refresh({active: false, entries: [], backend_config: {
   backup: `${workspace}/missing-backup`, path: `${workspace}/missing-cache`, digest: ''
  }}, {}, {}, 'scheduled', 'fixture_failure', {});
 } catch (error) { write_rejected = error.message == 'subscription_history_write_failed'; }
 check(recovered && write_rejected, 'history write failure cannot bypass rollback recovery');
 ports['subscriptions.facts'] = {read_history: history.read, record_history: history.record};

 const file = fs.open(path, 'w'); file.write('{broken'); file.close();
 let rejected = false;
 try { history.record(event(now, true), true); } catch (error) { rejected = true; }
 check(rejected && fs.readfile(path) == '{broken', 'unreadable history is not silently erased');
 ports['mihomo.backend'].running = () => false;
 scheduler_factory({use: name => ports[name]}).tick({unhealthy_since: now - 600});
 check(commands[-1] == 'recover', 'unreadable subscription state cannot suppress network recovery');
} catch (error) {
 warn(sprintf('%J\n', error)); fs.unlink(path); fs.unlink(`${path}.tmp`); fs.rmdir(workspace); release(); die(error.message);
}
fs.unlink(path); fs.rmdir(workspace); release();
printf('refresh history: %d assertions passed\n', assertions);
