// Isolated guest only: reproduce the target's retained signed plugin set.
import * as fs from 'fs';
import {sha256} from 'digest';
if (!fs.stat('/tmp/netfleet-retained-base-vm-authorized')) die('isolated_guest_required');
const root='/tmp/compat-runtime/retained-base';
const raw=fs.readfile(root+'/retained-base.json');
const manifest=json(raw), base=json(fs.readfile('/tmp/compat-base-identity.json'));
const quote=v=>"'"+replace(v,"'","'\\''")+"'";
function run(command) {
 const p=fs.popen(command+' 2>/tmp/retained-command.stderr'), output=p.read('all');
 if(p.close())die('retained_command_failed: '+fs.readfile('/tmp/retained-command.stderr'));
 return output;
}
if(base?.retained?.manifest_sha256!=sha256(raw) ||
   sprintf('%J',base.retained.artifacts)!=sprintf('%J',manifest.artifacts) ||
   sprintf('%J',base.retained.keys)!=sprintf('%J',manifest.keys))die('retained_manifest_changed');
for(let key in manifest.keys)
 if(sha256(fs.readfile(root+'/'+key.name) ?? '')!=key.sha256)die('retained_key_changed');
const archives=[];
for(let row in manifest.artifacts) {
 const archive=root+'/'+row.artifact;
 if(sha256(fs.readfile(archive) ?? '')!=row.sha256)die('retained_archive_changed');
 run('apk --no-network verify --keys-dir '+quote(root)+' '+quote(archive));
 const metadata=json(run('apk adbdump --format json '+quote(archive)));
 if(metadata.info.name!=row.package || metadata.info.version!=row.version ||
    !('noarch'==metadata.info.arch || trim(fs.readfile('/etc/apk/arch'))==metadata.info.arch))die('retained_package_identity_changed');
 const dir='/tmp/retained-extracted-'+row.package;
 if(!fs.mkdir(dir,0700))die('retained_extraction_exists');
 run('apk extract --keys-dir '+quote(root)+' --destination '+quote(dir)+' '+quote(archive));
 const prefix='/usr/libexec/opl-netfleet/plugins/'+replace(row.package,/^opl-netfleet-plugin-/,'');
 let checked=0;
 function owners(path) {
  for(let name in fs.lsdir(dir+path) ?? []) {
   const file=path+'/'+name, info=fs.lstat(dir+file);
   if(info.type=='directory')owners(file);
   else {
    if(info.type!='file')die('retained_payload_owner_escape');
    if(file=='/lib/apk/packages/'+row.package+'.list')continue;
    const shared=row.package=='opl-netfleet-plugin-scheduler' && file=='/etc/init.d/opl-netfleet' &&
       row.files[file]==base.runtime_sha256[file];
    if(!(index(file,prefix+'/')==0 || shared))die('retained_payload_owner_escape');
    if(row.files[file]!=sha256(fs.readfile(dir+file)))die('retained_payload_changed');
    checked++;
   }
  }
 }
 owners('');
 if(checked!=length(row.files))die('retained_payload_inventory_incomplete');
 push(archives,quote(archive));
}
const command='apk --no-network --repositories-file /dev/null --keys-dir '+quote(root);
run(command+' --simulate add '+join(' ',archives));
run(command+' add --force-reinstall '+join(' ',archives));
for(let path,digest in base.runtime_sha256)
 if(sha256(fs.readfile(path) ?? '')!=digest)die('retained_installed_caller_mismatch: '+path);
const installed=json(run("apk --no-network query --from installed --format json --fields name,version 'opl-netfleet*'"));
for(let row in manifest.artifacts) {
 if(!length(filter(installed,v=>v.name==row.package&&v.version==row.version)))die('retained_installed_version_mismatch');
}
printf('%J\n',{ok:true,packages:map(manifest.artifacts,v=>({name:v.package,version:v.version,sha256:v.sha256})),runtime_files:length(base.runtime_sha256)});
