import * as fs from 'fs';
const root = ARGV[0], directory = fs.mkdtemp('/tmp/netfleet-identity-test.XXXXXX');
let now = 1000, observations = [['2001:db8::1234','02:00:00:00:00:01']];
const source = loadfile(`${root}/plugins/device-identity/resources/identity.uc`)();
const owner = source({helper:ARGV[1],base:`${directory}/etc`,run:`${directory}/run`,monotonic:()=>now,
    ip_command: args => args[0] == 'neigh' ? [] : [{ifname:'observe0',flags:['UP'],address:'02:00:00:00:00:fe',addr_info:[{family:'inet6',scope:'link',local:'fe80::fe'}]}],
    connections:()=>['2001:db8::1234','2001:db8::5678'], observe:()=>observations});
function check(value, message) { if (!value) die(message); }
function eq(actual, expected, message) { check(sprintf('%J', actual) == sprintf('%J', expected), message); }
const config = {enabled:true,source:'local',interfaces:['observe0']};
owner.dispatch('load',{});
let state=owner.dispatch('get',{});
state=owner.dispatch('configure',{config_revision:state.config_revision,config});
const revision=state.config_revision, binding=state.binding;
state=owner.dispatch('sync',{});
check(state.source_ready,'fresh source missing'); eq(state.devices[0].addresses,['2001:db8::1234'],'new address missing');
eq(state.config_revision,revision,'observation changed config revision');
eq(state.binding,binding,'observation changed binding');
observations=[['2001:db8::5678','02:00:00:00:00:01']]; now+=31;
state=owner.dispatch('sync',{}); eq(state.devices[0].addresses,['2001:db8::5678'],'temporary address did not rotate');
observations=[['2001:db8::5678','02:00:00:00:00:01'],['2001:db8::5678','02:00:00:00:00:02']]; now+=31;
state=owner.dispatch('sync',{}); check(!length(filter(state.devices,x=>length(x.addresses))),'conflicting MAC accepted');
observations=[['2001:db8::1234','02:00:00:00:00:01']]; now+=31; owner.dispatch('sync',{}); now+=121;
state=owner.dispatch('resolve',{}); check(!state.source_ready,'expired source accepted');
check(!length(filter(state.devices,x=>length(x.addresses))),'expired addresses published');
let failed=false;
try { owner.dispatch('configure',{config_revision:'stale',config}); } catch (_) { failed=true; }
check(failed,'stale configuration accepted');
owner.atomic(`${directory}/etc/config.json`,{enabled:true,source:'unifi',endpoint:'https://invalid.example',password:'secret'});
owner.atomic(`${directory}/run/evidence.json`,{source_ready:true});
state=owner.dispatch('sync',{}); check(!state.source_ready && state.reason == 'source_not_supported','controller config still accepted');
check(fs.stat(`${directory}/run/evidence.json`) == null,'controller evidence remained');
check(index(sprintf('%J',state),'secret') < 0,'credential leaked');
state=owner.dispatch('configure',{config_revision:state.config_revision,config}); now+=31;
owner.dispatch('sync',{}); owner.dispatch('unload',{}); check(!owner.dispatch('resolve',{}).source_ready,'unload kept evidence');
for (let value in ['::','::1','ff02::1','fe80::1','::ffff:192.0.2.1','127.0.0.1','169.254.1.1','2001:db8::1%observe0']) check(owner.address(value) == null,`invalid client accepted: ${value}`);
printf('%J\n',{ok:true,checks:['address rotation','MAC conflict','TTL expiry','revision conflict','controller isolation','unload','source address validation']});
