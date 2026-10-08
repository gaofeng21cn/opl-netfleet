// Disposable guest: use the actual resolver helper and separate controller instances.
import * as fs from 'fs';import * as uloop from 'uloop';import {sha256} from 'digest';
const root=ARGV[0],run='/tmp/https-native-dns';fs.mkdir(run,0700);uloop.init();
let now=0;
const io={root,sha256,canonical:v=>sprintf('%J',v),now:()=>now,
 quote:v=>"'"+replace(`${v}`,"'","'\\''")+"'",write:(p,v)=>fs.writefile(p,v),read:p=>json(fs.readfile(p))};
const factory=loadfile(root+'/probes.uc')(),api=factory(io,run),rule={domain:'localhost',port:443};
assert(api.request('resolve',rule,{})?.pending===true,'cold resolver is pending, not an empty DNS answer');
uloop.timer(300,function(){
 const warm=api.request('resolve',rule,{});assert(warm?.ok&&length(warm.addresses)>0,'real asynchronous DNS did not complete');
 assert(factory(io,run).request('resolve',rule,{})?.pending===true,'independent controller reused unowned results');
 now=21;assert(api.request('resolve',rule,{})?.pending===true,'expired answer authorized a target');
 uloop.end();
});
uloop.run();
print('DNS: pending cold start, real asynchronous resolution, controller isolation and expiry passed\n');
