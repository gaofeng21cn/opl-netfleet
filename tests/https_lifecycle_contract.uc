// Run the shipped controller with a deterministic process/clock boundary.
import * as real_fs from 'fs';
const path = replace(sourcepath(), /[^/]+$/, '../openwrt/https-compat/files/usr/libexec/opl-netfleet-compat/control.uc');
const source = replace(replace(real_fs.readfile(path), "import * as fs from 'fs';", ''), "import * as uloop from 'uloop';", '');
const factory = loadstring('return function(fs, uloop, loadfile, sleep) { ' + source + '\n};')();
function check(ok, message) { if (!ok) die(message); }
function scenario(interactive, exits, stop_failure) {
    let clock = 0, stopped = false;
    const calls = [], files = {
        '/config/config.json': '{"enabled":true}',
        '/run/state.json': '{"intercepting":true,"reason":null,"last_failure":{"reason":"retained"}}'
    };
    const io = {
        now: () => clock, mkdir: () => {}, lock: () => ({}), unlock: () => {}, renewed: () => {},
        measure: (name, work) => work(), canonical: value => sprintf('%J', value), sha256: value => value,
        source: path => files[path] ?? null,
        read: (path, fallback) => files[path] == null ? fallback : json(files[path]),
        write: (path, value) => { files[path] = value; },
        command: args => {
            push(calls, args);
            if(args[0] == 'ubus' && args[3] == 'delete' && !stop_failure) stopped = true;
            if(args[1] == 'start') stopped = false;
            return args[0] == 'ubus' && args[3] == 'list'
                ? (stopped ? '{}' : '{"opl-netfleet-compat":{"instances":{"engine":{"running":true,"pid":99}}}}') : '{}';
        }
    };
    const modules = {
        'io.uc': io, 'policy.uc': {}, 'identity.uc': {}, 'isolation.uc': {}, 'probes.uc': {}, 'recovery.uc': {},
        'haproxy.uc': { close_probe: () => {}, health: () => ({pid:99,ready:true,active_connections:1}) }
    };
    const filesystem = { readfile: path => index(path, '/proc/') == 0
        ? (stopped || clock >= exits ? null : '99 (engine) S ' + join(' ', map([1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19], () => '77')))
        : files[path] ?? null };
    const controller = factory(filesystem, {}, path => () => () => modules[split(path, '/')[-1]], ms => { clock += ms / 1000.0; })(
        {use: name => ({request: (owner, request) => { push(calls, request); return {ok:true,result:{intercepting:false,leases:0}}; }})},
        {root:'/engine',base:'/config',run:'/run'});
    let error, saved;
    try { saved = controller.dispatch('suspend', {lifecycle:true,interactive}); } catch (failure) { error = failure.message; }
    return {controller,files,calls,error,saved,elapsed:clock};
}
const interactive = scenario(true, 100);
check(interactive.error == null && interactive.elapsed >= 1 && interactive.elapsed < 1.3,
    'explicit disable terminates plugin connections after one second grace');
check(length(filter(interactive.calls, call => call.action == 'remove')) == 1, 'confirmed stop removes gateway resources');
const failed = scenario(true, 100, true);
check(failed.error == 'compatibility_stop_unconfirmed' && failed.elapsed < 3.3, 'unconfirmed stop never reports disabled');
check(!length(filter(failed.calls, call => call.action == 'remove')), 'unconfirmed stop retains connection resources');
const before = failed.files['/config/config.json'];
failed.controller.dispatch('resume', {});
const restored = json(failed.files['/run/state.json']);
check(!restored.maintenance && !restored.suspended && restored.reason == 'recovering', 'failed drain recovers its locally saved intent');
check(restored.last_failure.reason == 'retained' && failed.files['/config/config.json'] == before, 'recovery preserves failure evidence and user configuration');
check(length(filter(failed.calls, call => type(call) == 'array' && call[1] == 'start')) == 1, 'previously running engine is resumed');
const package = scenario(false, 100);
check(package.error == 'healthy_connections_still_draining' && package.elapsed >= 30 && package.elapsed < 30.3,
    'package drain retains its thirty second allowance');
const complete = scenario(true, 0.4);
check(complete.error == null && complete.saved.running && complete.elapsed < 1, 'process exit completes interactive drain early');
check(length(filter(complete.calls, call => call.action == 'remove')) == 1, 'confirmed process exit permits resource removal');
print('HTTPS lifecycle: bounded interactive drain, retained package wait, failed-drain recovery and early completion passed\n');
