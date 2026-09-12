import * as fs from 'fs';
const root=ARGV[1] ?? '/src/openwrt/files/usr/libexec/opl-netfleet',pid=+ARGV[0];
const network={backend:'native-mihomo',ready:true,router_proxy:true,lan_proxy:true,compatibility_ownership_guard:true,interfaces:['nf-observe'],engine_pid:pid};
const process=loadfile(root+'/plugins/platform/lib/process.uc')()({});
let unreadable=false;
const capture=process.capture;
process.capture=(command,timeout,input)=>unreadable&&index(command,"'list' 'table' 'inet' 'netfleet_compat'")>=0?{status:1,output:''}:capture(command,timeout,input);
const context={root,id:'mihomo',use:name=>name=='mihomo.gateway'?{interception_snapshot:()=>({ok:true,result:{...network}})}:
    name=='platform.process'?process:
    {write_private:(path,data)=>{const result=fs.writefile(path,data);fs.chmod(path,0600);return result;},atomic_json:(path,data)=>fs.writefile(path,sprintf('%J',data))}};
const api=loadfile(root+'/plugins/mihomo/lib/interception.uc')()(context);
const owner={owner:'https-compat',service:'opl-netfleet-compat',instance:'engine',user:ARGV[2] ?? 'nobody'};
function check(value,reason) {if(!value) die(reason);}
function call(action,params) {const result=api.request(owner,{action,...(params??{})});check(result.ok,sprintf('%s: %J',action,result));return result.result;}
const lock=fs.open('/var/lock/opl-netfleet-deploy.lock','ae',0600);check(lock.lock('xn'),'lock');
const first=call('snapshot');check(first.reason==null,sprintf('admission: %J',first));
call('prepare',{epoch:first.epoch});
const candidates=[['192.0.2.22','198.51.100.1',443],['2001:db8:7::22','2001:db8:8::1',443]];
let active=call('renew',{epoch:first.epoch,candidates});check(active.intercepting&&active.leases==2,'dual stack leases');
unreadable=true;
check(api.request(owner,{action:'status'}).error=='gateway_command_failed','unreadable existing table reported as bypass');
unreadable=false;check(call('status').leases==2,'failed read changed leases');
const bad=api.request(owner,{action:'renew',epoch:first.epoch,candidates:[['192.0.2.22','198.51.100.1; delete table inet base',443]]});
check(!bad.ok,'nft injection accepted');
call('bypass');check(!call('status').intercepting,'bypass failed');
call('renew',{epoch:first.epoch,candidates});
sleep(10500);check(!call('status').intercepting,'kernel leases did not expire');
call('renew',{epoch:first.epoch,candidates});
fs.writefile('/etc/opl-netfleet/native/run/config.yaml','{"rules":["MATCH,PROXY"]}');
const stale=api.request(owner,{action:'renew',epoch:first.epoch,candidates});
check(stale.error=='lease_gateway_changed','stale epoch accepted');check(!call('status').intercepting,'stale epoch did not withdraw leases');
const next=call('snapshot');call('prepare',{epoch:next.epoch});call('renew',{epoch:next.epoch,candidates});
network.engine_pid=pid+100000;
const wrong=api.request(owner,{action:'prepare',epoch:call('snapshot').epoch});
check(wrong.error=='lease_listener_unconfirmed','unconfirmed listener accepted');check(!call('status').intercepting,'listener loss kept leases');
call('remove');check(!call('status').intercepting,'absent table not reported as bypass');lock.lock('u');lock.close();
print('native nft: IPv4/IPv6 leases, expiry, bypass, input rejection, epoch and listener failure passed\n');
