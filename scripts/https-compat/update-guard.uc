import * as fs from 'fs';
import {sha256} from 'digest';
const stage=ARGV[0],request=json(fs.readfile(stage+'/request.json'));
const quote=v=>"'"+replace(v,"'","'\\''")+"'";
if(type(request.base_runtime)!='object'||!length(request.base_runtime))die('qualified_base_inventory_missing');
for(let path,digest in request.base_runtime) {
 if(!match(path,/^\/(usr\/(libexec\/opl-netfleet[-\/]|share\/opl-netfleet\/nikki\/)|etc\/init\.d\/opl-netfleet(-core)?$)/)||
    !match(digest,/^[0-9a-f]{64}$/)||sha256(fs.readfile(path) ?? '')!=digest)die('qualified_base_runtime_changed');
}
function read(command) {const p=fs.popen(command),s=p.read('all');if(p.close())die('update_precondition_failed');return json(s);}
const installed=read("apk --no-network query --from installed --format json --fields name,version 'opl-netfleet*'");
fs.writefile(stage+'/installed-before.json',sprintf('%J',installed));
const versions={};for(let row in installed)versions[row.name]=row.version;
for(let kind in ['old','new']) {
 const name=request[kind];
 if(!match(name,/^opl-netfleet-https-compat-[0-9]+\.[0-9]+\.[0-9]+(-r[0-9]+)?\.apk$/))die('invalid_engine_archive');
 const path=stage+'/'+name;
 if(system('apk --no-network verify '+quote(path)+' >/dev/null 2>&1'))die('engine_signature_invalid');
 const meta=read('apk adbdump --format json '+quote(path));
 if(meta.info.name!='opl-netfleet-https-compat'||meta.info.arch!=trim(fs.readfile('/etc/apk/arch')))die('engine_identity_invalid');
 if(kind=='old'&&versions[meta.info.name]!=meta.info.version)die('installed_engine_changed');
 if(system('apk --no-network --repositories-file /dev/null --simulate add '+quote(path)+' >/dev/null 2>&1'))die('engine_dependencies_unavailable');
}
const status=read('ucode /usr/libexec/opl-netfleet/main.uc native-gateway-status');
if(!status.ok||status.result.ready!==true)die('base_gateway_not_ready');
const current=read('ucode /usr/libexec/opl-netfleet/main.uc compatibility-get');
if(!current.ok||current.result.requested&&current.result.intercepting!==true)die('engine_precondition_not_ready');
// Extract only into the private transaction, then compare every existing engine byte.
const dir=stage+'/old-files';if(!fs.mkdir(dir,0700))die('update_stage_exists');
if(system('apk extract --destination '+quote(dir)+' '+quote(stage+'/'+request.old)+' >/dev/null 2>&1'))die('old_engine_extract_failed');
function compare(path) {
 for(let name in fs.lsdir(dir+path) ?? []) {
  const p=path+'/'+name,info=fs.lstat(dir+p);
  if(info.type=='directory')compare(p);
  else if(info.type=='file'&&sha256(fs.readfile(dir+p))!=sha256(fs.readfile(p) ?? ''))die('installed_engine_bytes_changed');
 }
}
compare('/usr/libexec/opl-netfleet-compat');compare('/etc/init.d');
