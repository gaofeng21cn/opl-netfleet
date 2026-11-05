#!/usr/bin/ucode
// OpenWrt platform maintenance. No NetFleet runtime command calls this entry.
import * as fs from 'fs';
import { sha256 } from 'digest';
import { cursor } from 'uci';
const uci=cursor(), ROOT='/etc/opl-netfleet/firmware', MARKER=ROOT+'/pending.json';
const ARGON=['luci-theme-argon','luci-app-argon-config','luci-i18n-argon-config-zh-cn'];
const SERVICES=['opl-netfleet','opl-netfleet-core','nikki'];
const DIRS=['/etc/opl-netfleet','/etc/nikki/profiles','/etc/nikki/subscriptions','/etc/nikki/run'];
const INPUTS=['/etc/config/netfleet','/etc/config/nikki','/etc/config/luci','/etc/config/argon',
 '/etc/config/attendedsysupgrade','/etc/config/network','/etc/config/firewall','/etc/nikki/mixin.yaml','/usr/libexec/mihomo'];
function q(s) { return "'"+replace(s,/'/g,"'\\''")+"'"; }
function command(s) {
 const p=fs.popen(s,'r'); if(!p) die('command_unavailable'); const out=p.read('all'), code=p.close();
 if(code!=0) die('platform_command_failed'); return out;
}
function json_command(s) { const v=json(command(s)); if(v==null) die('platform_response_invalid'); return v; }
function write(path,value) {
 const t=path+'.tmp'; if(!fs.writefile(t,sprintf('%J\n',value))) die('state_write_failed');
 fs.chmod(t,0o600); if(!fs.rename(t,path)) die('state_replace_failed');
}
function installed() {
 const result={};
 for(let row in json_command("apk --no-network --repositories-file /dev/null query --from installed --format json --fields name,version '*'")) result[row.name]=row.version;
 return result;
}
function board() { return json_command('ubus call system board'); }
function public_url(url) {
 // These URLs are sent to the public ASU builder, never device credentials.
 return type(url)=='string' && match(url,/^https:\/\/[A-Za-z0-9.-]+\/[A-Za-z0-9_.~+%\/-]+$/) && index(url,'..')<0;
}
function description() {
 const repositories={}, repository_keys=[]; let n=0;
 for(let file in fs.lsdir('/etc/apk/repositories.d')??[]) {
  if(file=='distfeeds.list') continue;
  const content=fs.readfile('/etc/apk/repositories.d/'+file)??'';
  for(let line in split(content,'\n')) {
   line=trim(line); if(!length(line) || substr(line,0,1)=='#') continue;
   if(!public_url(line)) die('private_or_unsupported_repository');
   repositories['feed'+n++]=line;
  }
 }
 for(let file in fs.lsdir('/etc/apk/keys')??[]) {
  const key=fs.readfile('/etc/apk/keys/'+file);
  if(!key || !match(key,/^-----BEGIN PUBLIC KEY-----\n[A-Za-z0-9+\/=\n]+-----END PUBLIC KEY-----\n?$/)) die('repository_public_key_invalid');
  push(repository_keys,key);
 }
 const versions=installed();
 return {repositories,repositories_mode:'append',repository_keys,excluded:filter(ARGON,name=>name in versions)};
}
function admit(url,digest,version) {
 const server=rtrim(uci.get_first('attendedsysupgrade','server','url')??'https://sysupgrade.openwrt.org','/');
 if(!public_url(server+'/store/x') || !public_url(url) || index(url,server+'/store/')!=0 || !match(digest??'',/^[a-f0-9]{64}$/)) die('untrusted_firmware_download');
 const current=board().release.version;
 if(!match(version??'',/^\d+\.\d+\.\d+$/) || join('.',slice(split(version,'.'),0,2))!=join('.',slice(split(current,'.'),0,2)) || +split(version,'.')[2]<+split(current,'.')[2]) die('unsupported_release_transition');
 description();
}
function fetch_json(url) { return json_command('uclient-fetch -q -T 30 -O - '+q(url)); }
function argon_archives(versions) {
 let previous=json(fs.readfile(ROOT+'/argon.json')??'null')??[];
 const rows=[], missing=[];
 for(let name in ARGON) {
  if(!(name in versions)) continue;
  const version=versions[name], filename=name+'-'+version+'.apk';
  if(!match(filename,/^[A-Za-z0-9_.~+-]+\.apk$/)) die('invalid_argon_identity');
  let row=filter(previous,r=>r.name==name && r.version==version)[0];
  if(!row || row.filename!=filename || !public_url(row.url) || index(row.url,'https://github.com/jerrykuku/luci-theme-argon/releases/download/')!=0 || !match(row.sha256??'',/^[a-f0-9]{64}$/) || sha256(fs.readfile(ROOT+'/'+filename)??'')!=row.sha256) row=null;
  if(row) push(rows,row); else push(missing,{name,version,filename});
 }
 for(let page=1;length(missing) && page<=3;page++) {
  const releases=fetch_json('https://api.github.com/repos/jerrykuku/luci-theme-argon/releases?per_page=100&page='+page);
  if(type(releases)!='array') die('argon_release_metadata_unavailable');
  for(let release in releases) for(let asset in release.assets??[]) {
   // Some upstream translation assets replace APK's '~' with '.' in the
   // release filename. The downloaded package metadata must still match exactly.
   const item=filter(missing,r=>r.filename==asset.name || replace(r.filename,/~/g,'.')==asset.name)[0]; if(!item) continue;
   const digest=match(asset.digest??'',/^sha256:([a-f0-9]{64})$/)?.[1], url=asset.browser_download_url;
   if(!digest || !public_url(url) || index(url,'https://github.com/jerrykuku/luci-theme-argon/releases/download/')!=0) die('argon_release_digest_missing');
   const path=ROOT+'/'+item.filename, temporary=path+'.tmp';
   command('uclient-fetch -q -T 60 -O '+q(temporary)+' '+q(url));
   if(sha256(fs.readfile(temporary))!=digest) die('argon_archive_digest_changed');
   const info=json_command('apk adbdump --format json '+q(temporary)).info;
   if(info.name!=item.name || info.version!=item.version) die('argon_archive_identity_changed');
   fs.chmod(temporary,0o600); if(!fs.rename(temporary,path)) die('argon_archive_replace_failed');
   push(rows,{name:item.name,version:item.version,filename:item.filename,url,sha256:digest});
   splice(missing,index(missing,item),1);
  }
  if(!length(releases)) break;
 }
 if(length(missing)) die('exact_argon_archive_unavailable');
 write(ROOT+'/argon.json',rows); return rows;
}
function inputs() {
 const found={};
 function add(path) {
  if(index(path,ROOT)==0 || !match(path,/^\/(etc|usr)\/[A-Za-z0-9_./-]+$/)) return;
  const st=fs.lstat(path); if(st?.type=='file') found[path]=sha256(fs.readfile(path));
  else if(st?.type=='directory') for(let name in fs.lsdir(path)??[]) add(path+'/'+name);
 }
 for(let path in [...INPUTS,...DIRS]) add(path);
 return map(sort(keys(found)),path=>({path,sha256:found[path]}));
}
function prepare(version) {
 const st=fs.lstat(ROOT);
 if(st && (st.type!='directory' || st.uid!=0 || (st.mode&0o077))) die('unsafe_firmware_state');
 if(!st) { fs.mkdir(ROOT,0o700); fs.chmod(ROOT,0o700); }
 const b=board(), packages=argon_archives(installed()), services={};
 for(let name in SERVICES) if(fs.access('/etc/init.d/'+name)) services[name]=system('/etc/init.d/'+name+' enabled >/dev/null 2>&1')==0;
 write(MARKER,{schema:1,target:b.release.target,to_version:version,inputs:inputs(),packages,services});
}
function restore() {
 if(!fs.access(MARKER)) return;
 const state=json(fs.readfile(MARKER)), b=board();
 if(state?.schema!=1 || state.target!=b.release.target || state.to_version!=b.release.version || type(state.inputs)!='array' || !length(state.inputs)) die('firmware_restore_identity_changed');
 for(let row in state.inputs) {
  if(!match(row.path??'',/^\/(etc|usr)\/[A-Za-z0-9_./-]+$/) || index(row.path,'..')>=0 || !match(row.sha256??'',/^[a-f0-9]{64}$/) || sha256(fs.readfile(row.path)??'')!=row.sha256) die('firmware_private_input_changed');
 }
 const archives=[];
 for(let row in state.packages??[]) {
  if(index(ARGON,row.name)<0 || row.filename!=row.name+'-'+row.version+'.apk' || !match(row.filename,/^[A-Za-z0-9_.~+-]+\.apk$/) || !match(row.sha256??'',/^[a-f0-9]{64}$/) || sha256(fs.readfile(ROOT+'/'+row.filename)??'')!=row.sha256) die('firmware_argon_archive_changed');
  push(archives,q(ROOT+'/'+row.filename));
 }
 if(length(archives)) command('apk --no-network --repositories-file /dev/null --allow-untrusted --scripts=no add '+join(' ',archives));
 for(let name in [...ARGON,'nikki','luci-app-nikki','luci-i18n-nikki-zh-cn']) {
  for(let path in split(fs.readfile('/lib/apk/packages/'+name+'.list')??'','\n')) {
   if(match(path,/^\/etc\/uci-defaults\/[A-Za-z0-9_.-]+$/) && fs.lstat(path)?.type=='file') fs.unlink(path);
  }
 }
 for(let name in SERVICES) if(name in state.services) {
  if(type(state.services[name])!='bool' || !fs.access('/etc/init.d/'+name)) die('firmware_service_identity_changed');
  command('/etc/init.d/'+name+(state.services[name]?' enable':' disable'));
 }
 const backend=json(fs.readfile('/etc/opl-netfleet/backend.json')??'null')?.kind;
 const runtime=backend=='native-mihomo'?'/etc/opl-netfleet/native/run':'/etc/nikki/run';
 if(fs.access(runtime+'/config.yaml')) command('mihomo -t -d '+q(runtime)+' -f '+q(runtime+'/config.yaml')+' 2>&1');
 write(ROOT+'/last.json',{ok:true,version:b.release.version,packages:length(archives),inputs:length(state.inputs)});
 fs.unlink(MARKER);
}
try {
 switch(ARGV[0]) {
  case 'describe': printf('%J\n',description()); break;
  case 'admit': admit(ARGV[1],ARGV[2],ARGV[3]); break;
  case 'prepare': prepare(ARGV[1]); break;
  case 'restore': restore(); break;
  default: die('unknown_firmware_action');
 }
} catch(error) { warn('netfleet-firmware: '+error+'\n'); exit(1); }
