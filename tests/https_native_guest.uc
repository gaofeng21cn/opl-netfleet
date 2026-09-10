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
} else if(action=='disable') {
    const state=run(['compatibility-get']);
    const result=request('compatibility-disable',{revision:state.revision});
    check(!result.requested&&!result.intercepting,'disable_did_not_remove_admission');
} else if(action=='state') printf('%J\n',run(['compatibility-get']));
else die('unknown_native_guest_action');
fs.unlink(path);
