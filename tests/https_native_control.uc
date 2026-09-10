import * as fs from 'fs';
const root=ARGV[0],run=ARGV[1],calls=[];
const context={use:name=>name=='mihomo.interception'?{request:(owner,input)=>{
    push(calls,input.action);
    return {ok:true,result:input.action=='status'?{intercepting:false,leases:0}:{}};
}}:null};
const api=loadfile(root+'/control.uc')()(context,{root,base:run,run});
function check(value,message) {if(!value) die(message);}
let current=api.dispatch('get',{});
check(current.requested===false&&current.config.schema==1,'disabled_initial_state');
const config={schema:1,enabled:false,devices:[{id:'mac',name:'Mac',addresses:['192.0.2.22']}],rules:[
    {id:'target',name:'Target',enabled:true,devices:['mac'],domain:'example.com',match:'exact',port:443,strategy:'h2'}]};
current=api.dispatch('apply',{revision:current.revision,config});
const configured=current.revision;
let stale=false;try{api.dispatch('enable',{revision:'stale'});}catch(error){stale=error.message=='compatibility_revision_conflict';}
check(stale,'stale_configuration_accepted');
current=api.dispatch('probe',{revision:configured,operation:'trust_record',device:'mac',report:{system:true,ca_sha256:current.ca_sha256,images:true}});
check(current.trust.mac?.verified===true&&current.trust.mac.runtimes.images===true,'trust_record_missing');
check(current.revision!=configured,'trust_revision_not_bound');
current=api.dispatch('enable',{revision:current.revision});
check(current.requested===true&&current.intercepting===false,'intent_must_not_claim_interception');
current=api.dispatch('disable',{revision:current.revision});
check(current.requested===false&&current.reason=='disabled','user_disable_not_retained');
current=api.dispatch('probe',{revision:current.revision,operation:'trust_revoke',device:'mac'});
check(!current.trust.mac,'trust_revocation_failed');
const saved=api.dispatch('suspend',{lifecycle:true});
check(saved.requested===false,'suspend_intent');
api.dispatch('resume',saved);
check(api.dispatch('get',{}).requested===false,'resume_overrode_disable');
check(length(filter(calls,action=>action=='bypass'))>=5,'mutations_must_remove_admission');
print('native control: revisions, trust, intent, disable and lifecycle passed\n');
