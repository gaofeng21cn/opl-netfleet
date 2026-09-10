import * as fs from 'fs';
const root=ARGV[0];
const profile='/etc/opl-netfleet/native/run/config.yaml';
for (let path in ['/etc/opl-netfleet','/etc/opl-netfleet/native','/etc/opl-netfleet/native/run']) fs.mkdir(path,0700);
fs.writefile(profile,'{"rules":["MATCH,DIRECT"]}');
const gateway={interception_snapshot:()=>({ok:true,result:{backend:'native-mihomo',ready:true,router_proxy:true,lan_proxy:true,compatibility_ownership_guard:true}})};
const context={root:root+'/openwrt/files/usr/libexec/opl-netfleet',id:'mihomo',use:function(name) {
    if(name=='mihomo.gateway') return gateway;
    if(name=='platform.files') return {write_private:(path,value)=>fs.writefile(path,value)};
    if(name=='platform.process') return {shell_quote:value=>"'"+replace(`${value}`,"'","'\\''")+"'"};
    die('unexpected_service');
}};
const api=loadfile(context.root+'/plugins/mihomo/lib/interception.uc')()(context);
const owner={owner:'https-compat',service:'opl-netfleet-compat',instance:'engine',user:'netfleet-compat'};
function check(value,message) { if(!value) die(message); }
check(api.request({...owner, extra:'x'},{action:'status'}).error=='lease_owner_invalid','owner_shape');
check(api.request(owner,{action:'remove',extra:1}).error=='lease_request_invalid','request_shape');
check(api.request(owner,{action:'bogus'}).error=='lease_action_invalid','action');
const snapshot=api.request(owner,{action:'snapshot'});
check(snapshot.ok && snapshot.result.reason==null && length(snapshot.result.epoch)==64,sprintf('snapshot: %J',snapshot));
fs.mkdir('/var/lock',0755);
const lock=fs.open('/var/lock/opl-netfleet-deploy.lock','a',0600);
check(api.request(owner,{action:'prepare',epoch:snapshot.result.epoch}).error=='lease_network_lock_required','no_lock');
check(lock.lock('xn'),'lock');
const result=api.request(owner,{action:'prepare',epoch:snapshot.result.epoch});
check(result.error=='lease_unprivileged_listener_required',sprintf('held_lock: %J',result));
lock.close();
fs.unlink(profile);
print('native interception snapshot and real flock checks passed\n');
