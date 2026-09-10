import * as fs from 'fs';
const control=ARGV[0], envelope='/tmp/identity-native-envelope.json';
function invoke(action,params,allowed) {
    fs.writefile(envelope,sprintf('%J',{request:{id:'device-identity',api_version:1,action,params:params ?? {}}}));
    fs.chmod(envelope,allowed===false?0644:0600);
    const pipe=fs.popen(`ucode ${control} ${action} ${envelope}`);
    const value=json(pipe.read('all')),status=pipe.close();
    if(allowed===false) {if(value.ok||!status) die('public_request_accepted');}
    else if(status||value.ok!==true) die(sprintf('entry_failed: %J',value));
    return value.result;
}
invoke('get',{},false);
let state=invoke('load');
state=invoke('configure',{config_revision:state.config_revision,config:{source:'local',enabled:false,interfaces:[]}});
if(state.config.source!='local'||state.config.enabled!==false) die('entry_configuration_failed');
state=invoke('resolve');
if(state.source_ready) die('disabled_source_issued_evidence');
state=invoke('unload');
if(state.loaded) die('entry_unload_failed');
fs.unlink(envelope);
print('native identity real control entry: private envelope, load, configure, resolve, unload passed\n');
