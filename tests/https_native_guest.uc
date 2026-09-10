// Invoked only by the disposable OpenWrt native compatibility lane.
import * as fs from 'fs';
const main='/usr/libexec/opl-netfleet/main.uc',path='/tmp/native-compat-request.json';
function run(args) {
    const pipe=fs.popen(`ucode ${main} ${join(' ',args)}`);
    const value=json(pipe.read('all')),status=pipe.close();
    if(status||value?.ok!==true) die(sprintf('native_guest_command_failed: %J',value));
    return value.result;
}
function request(command,body) {
    fs.writefile(path,sprintf('%J',{request:body}));fs.chmod(path,0600);
    return run([command,path]);
}
function check(value,message){if(!value) die(message);}
const action=ARGV[0];
if(action=='load') {
    for(let id in ['https-compat','device-identity']) {
        const row=filter(run(['plugins-list']).plugins,item=>item.id==id&&item.instance=='default')[0];
        check(row,'installed_plugin_missing');
        if(!row.loaded) request('plugin-call',{id,action:'load',revision:row.revision,confirm:true});
    }
} else if(action=='enable') {
    let state=run(['compatibility-get']);
    const config={schema:1,enabled:false,devices:[],rules:[]};
    state=request('compatibility-apply',{revision:state.revision,config});
    state=request('compatibility-enable',{revision:state.revision});
    check(state.requested&&!state.intercepting,'empty_rules_must_not_intercept');
} else if(action=='network-enable') {
    let state=run(['compatibility-get']);
    const config={schema:1,enabled:false,devices:[{id:'mac',name:'Isolated Mac',addresses:['10.77.0.2','2001:db8:77::2']}],rules:[
        {id:'wire',name:'Wire origin',enabled:true,devices:['mac'],domain:'wire.example',match:'exact',port:443,strategy:'h2'}]};
    state=request('compatibility-apply',{revision:state.revision,config});
    state=request('compatibility-probe',{revision:state.revision,operation:'trust_record',device:'mac',report:{system:true,ca_sha256:state.ca_sha256}});
    state=request('compatibility-enable',{revision:state.revision});
    printf('%J\n',state);
} else if(action=='network-identity') {
    const id='device-identity';
    let row=filter(run(['plugins-list']).plugins,item=>item.id==id)[0];
    request('plugin-call',{id,action:'load',revision:row.revision,confirm:true});
    let source=request('plugin-read',{id,action:'get',params:{}});
    row=filter(run(['plugins-list']).plugins,item=>item.id==id)[0];
    request('plugin-call',{id,action:'configure',revision:row.revision,confirm:true,params:{config_revision:source.config_revision,
        config:{enabled:true,source:'local',interfaces:['nfcompat0']}}});
    source=request('plugin-read',{id,action:'sync',params:{}});
    check(source.source_ready,'native_source_not_ready');
    let state=run(['compatibility-get']);
    const config={...state.config,devices:[{...state.config.devices[0],addresses:[],identity:{binding:source.binding,mac:'02:77:00:00:00:02'}}]};
    state=request('compatibility-apply',{revision:state.revision,config});
    check(state.trust.mac?.verified===true,'confirmed_identity_lost_trust');
    printf('%J\n',state);
} else if(action=='network-source-disable'||action=='network-source-enable') {
    const id='device-identity',source=request('plugin-read',{id,action:'get',params:{}});
    const row=filter(run(['plugins-list']).plugins,item=>item.id==id)[0];
    request('plugin-call',{id,action:'configure',revision:row.revision,confirm:true,params:{config_revision:source.config_revision,
        config:{enabled:action=='network-source-enable',source:'local',interfaces:['nfcompat0']}}});
    request('plugin-read',{id,action:'sync',params:{}});
} else if(action=='recover') {
    const state=run(['compatibility-get']);
    printf('%J\n',request('compatibility-probe',{revision:state.revision,operation:'recover'}));
} else if(action=='disable') {
    const state=run(['compatibility-get']);
    const result=request('compatibility-disable',{revision:state.revision});
    check(!result.requested&&!result.intercepting,'disable_did_not_remove_admission');
} else if(action=='state') printf('%J\n',run(['compatibility-get']));
else die('unknown_native_guest_action');
fs.unlink(path);
