// Disposable guest only. Exercise the public controller, including external writers.
import * as fs from 'fs';
const root=ARGV[0],dir=fs.mkdtemp('/tmp/https-state-cache.XXXXXX'),run=dir+'/run',base=dir+'/config';
fs.mkdir(run,0700);fs.mkdir(base,0700);
const context={use:name=>name=='platform.process'?{capture:()=>({status:0,output:'{}'})}:
    {request:()=>({ok:true,result:{intercepting:false,leases:0}})}};
const controller=loadfile(root+'/control.uc')()(context,{root,run,base});
const events=[];
for(let n=0;n<100;n++)push(events,{at:n,reason:'fixture',intercepting:false,local_probes:{
    ipv4:{ok:true,duration_ms:30,timeout_ms:1400},ipv6:{ok:true,duration_ms:30,timeout_ms:1400}}});
const state=run+'/state.json';
fs.writefile(state,sprintf('%J',{reason:'disabled',intercepting:false,events}));fs.chmod(state,0600);
for(let n=0;n<10;n++)controller.dispatch('tick',{});
let saved=json(fs.readfile(state));
if(length(saved.events)!=100||saved.events[99].at!=99||saved.reason!='disabled')die('history_changed');
let view=controller.dispatch('get');view.events[0].reason='caller_changed';
if(controller.dispatch('get').events[0].reason!='fixture')die('history_reference_escaped');
// A same-sized external replacement must invalidate the decoded history.
let raw=replace(fs.readfile(state),'fixture','updated');fs.writefile(state,raw);
if(controller.dispatch('get').events[0].reason!='updated')die('external_state_not_read');
controller.dispatch('tick',{});
if(json(fs.readfile(state)).events[99].reason!='updated')die('external_history_overwritten');
fs.chmod(state,0666);let rejected=false;
try{controller.dispatch('get');}catch(e){rejected=e.message=='compatibility_state_unsafe';}
if(!rejected)die('cached_state_permission_bypass');fs.chmod(state,0600);
fs.writefile(state,'broken');rejected=false;
try{controller.dispatch('get');}catch(e){rejected=e.message=='compatibility_state_invalid';}
if(!rejected)die('cached_state_invalid_json_bypass');
fs.unlink(state);controller.dispatch('tick',{});
saved=json(fs.readfile(state));if(length(saved.events)!=1||saved.events[0].reason!='disabled')die('missing_state_reused');
fs.unlink(state);fs.rmdir(run);fs.rmdir(base);fs.rmdir(dir);
print('state: retained history, external changes, isolated readback and invalidation passed\n');
