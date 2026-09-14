import * as fs from 'fs';

const source = fs.readfile(ARGV[0] ?? replace(sourcepath(), /[^/]+$/, '../openwrt/files/usr/libexec/opl-netfleet/plugins/components/lib/control.uc'));
if (source == null) die('components implementation unreadable');
function extract(begin, end) {
	const start = index(source, begin), stop = index(source, end, start);
	if (start < 0 || stop < 0) die('implementation missing');
	return substr(source, start, stop - start);
}
const controls = extract('function cancel_update(', 'function lifecycle(');
loadstring(`
const ROOT='/private'; let id='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', request={id,action:'update'}, state={}, running=true, locked=false, marker=false, unsafe=false, closes=0;
const REQUEST='request';
function check(value,message){if(!value)die(message);}
function fail(code){die(code);}
function error_code(error){return trim(split(error.message ?? error,'\\n')[0]);}
function private_file(path){return path=='request'||path=='/private/'+id+'/cancel.json' ? path=='request'||marker : !unsafe;}
function private_directory(path){return true;}
function read_json(path){return path=='request'?request:state;}
function update_process(){return {running};}
function atomic_json(path,value){marker=true;return true;}
const fs={lstat:()=>({}),open:()=>({lock:()=>!locked,close:()=>{closes++;}})};
function rejects(action,code){let seen;try{action();}catch(error){seen=error_code(error);}check(seen==code,'expected '+code+', got '+seen);}
` + controls + `
rejects(()=>cancel_update('bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'),'update_operation_changed');
check(!marker,'stale identity must not cancel');
locked=true;rejects(()=>cancel_update(id),'update_transition_busy');check(!marker,'transition owns cancellation decision');locked=false;
state={write_started:true};rejects(()=>cancel_update(id),'update_cancel_unavailable');check(!marker,'cannot cancel package replacement');
state={phase:'complete'};rejects(()=>cancel_update(id),'update_cancel_unavailable');
state={};running=false;rejects(()=>cancel_update(id),'update_cancel_unavailable');running=true;
unsafe=true;rejects(()=>cancel_update(id),'unsafe_update_directory');unsafe=false;
check(cancel_update(id).requested && marker,'current operation accepts cancellation');
rejects(()=>cancellation('/private/'+id),'update_cancelled');
check(closes>=4,'control lock released on failures and success');
`)();

const preparation = extract('function resume_resources(', 'get = function(');
loadstring(`
let state={drained:[]}, calls=[], failure='healthy_connections_still_draining', cancelled=false;
const COMPATIBILITY_PACKAGE='opl-netfleet-https-compat';
const context={inventory:()=>[]}, operation={update:()=>true};
function check(value,message){if(!value)die(message);}
function read_json(path){return state;}
function journal(work,next){state=next;}
function cancellation(work){if(cancelled)die('update_cancelled');}
function fail(code){die(code);}
function lifecycle(action,id){push(calls,action+':'+id);return {ok:action=='resume'||id!='mihomo',error:failure};}
function system(command){return 0;}
` + preparation + `
let reason;try{prepare_resources('/work',['opl-netfleet-plugin-events','mihomo-meta'],{'opl-netfleet-plugin-events':'1','mihomo-meta':'1'},{'opl-netfleet-plugin-events':'2','mihomo-meta':'2'});}catch(e){reason=e.message;}
check(reason=='update_deferred','healthy connections defer update');
check(state.phase=='draining'&&length(state.drained)==2,'save every attempted owner before calling drain');
check(resume_resources('/work'),'restore resources after deferred update');
check(join(',',calls)=='drain:events,drain:mihomo,resume:mihomo,resume:events','restore in reverse order');
calls=[];cancelled=true;try{prepare_resources('/work',['mihomo-meta'],{'mihomo-meta':'1'},{'mihomo-meta':'2'});}catch(e){}
check(!length(calls),'cancel before preparing any resource');
`)();

const stopping = extract('stop_services = function(', 'restore_services = function(');
loadstring(`
let stop_services, clean=true, running=false, reads=0;
const KIND='native-mihomo', SERVICE='opl-netfleet-core';
const gateway={status:()=>{reads++;return {ok:true,result:{clean}};}};
function run_command(){return true;}function service_running(){return running;}
function system(){return 0;}
function parsed(){die('installed gateway command must not be used during maintenance');}
` + stopping + `
if(!stop_services('/work')||reads!=1)die('retained gateway confirms drained cleanup');
clean=false;if(stop_services('/work'))die('unclean gateway must reject update');
running=true;if(stop_services('/work'))die('running services must reject update');
`)();

const getter = extract('get = function(', 'local_stage = function(');
loadstring(`
let get;const CACHE='cache',PACKAGES=['opl-netfleet','luci-app-netfleet','mihomo-meta'],KIND='native-mihomo',DEPENDENCIES=[];
let versions={'opl-netfleet':'1','luci-app-netfleet':'1','opl-netfleet-plugin-ui':'2'}, candidates={'opl-netfleet':'1','luci-app-netfleet':'1','opl-netfleet-plugin-ui':'3'};
function installed(){return versions;}function feed(){return 'feed';}function private_file(){return true;}
function read_json(){return {feed:'feed',versions:candidates};}function newer(next,current){return next!=null&&current!=null&&int(next)>int(current);}
function product_packages(){return ['opl-netfleet','luci-app-netfleet','opl-netfleet-plugin-ui'];}function version_valid(value){return value!=null;}
function controller_version(){return null;}function api_secret(){return null;}function capture(){return null;}function dashboard_resource(){return {};}
const context={inventory:()=>[]};function check(value,message){if(!value)die(message);}
function plugin_packages(){return [];}
` + getter + `
let result=get();check(result.components[0].update_available && result.components[0].available_version=='1','same aggregate version must expose plugin update');
check(join(',',result.product.updates)=='opl-netfleet-plugin-ui','report actual changed packages');
versions['opl-netfleet-plugin-ui']='4';result=get();check(!result.components[0].update_available,'never offer a downgrade');
delete versions['opl-netfleet-plugin-ui'];result=get();check(join(',',result.product.missing)=='opl-netfleet-plugin-ui','missing package is separate from an update');
`)();
print('components_update_control_contract_ok\n');
