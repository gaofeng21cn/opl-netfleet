import * as fs from 'fs';
let count = 0;
function check(value, message) { if (!value) die(message); count++; }
let history = {}, active = null, pending = false;
const ports = {
 'platform.files': { private_file: p => index(p, 'history.json') >= 0 || (index(p, 'active.json') >= 0 && active != null) || (index(p, 'pending.json') >= 0 && pending) || index(p, '.mrs') >= 0 },
 'platform.storage': { read_json: p => index(p, 'backend.json') >= 0 ? { kind: 'native-mihomo' } : index(p, 'history.json') >= 0 ? history : active },
 'platform.process': { shell_quote: v => v }
};
const root = fs.stat('plugins/mihomo/lib/rule-data.uc') != null ? 'plugins' : '/usr/libexec/opl-netfleet/plugins';
const factory = loadfile(root + '/mihomo/lib/rule-data.uc')();
const data = factory({use: name => ports[name]}, {});
const policy = {policy_source: {kind:'bundle', ref:'bundle:base-v1'}, automation:{rule_refresh_enabled:true,rule_refresh_interval_seconds:604800}};
check(data.status(policy).enabled, 'builtin native policy supports scheduled updates');
check(data.status({policy_source:{kind:'profile',ref:'subscription:fixture'}}).supported == false, 'user profiles do not opt into builtin replacement');
history = {last_success_at:1000000,last_attempt_at:1000000,last_ok:true};
check(data.status(policy).next_run_at == 1604800, 'next deadline is persisted success plus one week');
history = {last_success_at:1,last_attempt_at:2000000,last_ok:false};
check(data.status(policy).next_run_at == 2003600, 'failure retries after one hour without advancing success');
const parsed = data.cidrs('# fixture\n203.0.113.0/24\n2001:db8::/32\n');
check(parsed.china_ip[0].prefix.len == 24 && parsed.china_ip6[0].prefix.len == 32, 'both address families retained');
let rejected=false; try { data.cidrs('203.0.113.0/24;flush ruleset\n2001:db8::/32'); } catch(e) { rejected=true; }
check(rejected,'CIDR input cannot inject nft commands');
rejected=false; try { data.cidrs('203.0.113.0/24'); } catch(e) { rejected=true; }
check(rejected,'partial address-family download is rejected');
const batch = data.batch(parsed);
check(length(batch.nftables)==4 && batch.nftables[0].flush.set.table=='netfleet', 'one batch touches only owned country sets');
active={directory:'/etc/opl-netfleet/native/rule-data/generation.fixture',commit:'a',rules:{'cn-domain':{path:'/etc/opl-netfleet/native/rule-data/generation.fixture/cn-domain.mrs'}}};
const profile={'rule-providers':{'cn-domain':{type:'file',path:'./rulesets/cn-domain.mrs'}}};
check(data.project(profile)['rule-providers']['cn-domain'].path==active.rules['cn-domain'].path,'accepted generation used at next start');
const custom={'rule-providers':{'cn-domain':{type:'http',url:'https://fixture.invalid/rules'}}};
check(data.project(custom)['rule-providers']['cn-domain'].type=='http','custom source owner retained');
check(data.status(policy).last_success_at==1,'failed update preserves success baseline');
printf('rule data: %d assertions passed\n',count);
