import * as fs from 'fs';
const path=replace(sourcepath(), /[^/]+$/, '../openwrt/files/usr/libexec/opl-netfleet/plugins/mihomo/lib/interception.uc');
const source=fs.readfile(path),start=index(source,'    function dispatch(owner,input) {'),end=index(source,'    function request(owner,input)',start);
if(start<0||end<0)die('interception_dispatch_unavailable');
loadstring(`
const owner={owner:'https-compat',service:'opl-netfleet-compat',instance:'engine',user:'netfleet-compat'};
const CLAIM='/private-claim',TABLE='netfleet_compat';
let present=false,claimed=true,marked=2,clear_fails=false,native_present=true;
const calls=[];
const fs={stat:path=>claimed,readfile:path=>sprintf('%J',owner),unlink:path=>{claimed=false;push(calls,'unlink');}};
function descriptor(value) {}
function network_lock_held() {return true;}
function table() {return present?{}:null;}
function native() {return native_present?{clear_marked:()=>{push(calls,'clear');if(clear_fails)die('compatibility_conntrack_cleanup_failed');marked=0;}}:null;}
function run(args) {push(calls,'delete');present=false;}
function status() {return {intercepting:false,leases:0};}
`+substr(source,start,end-start)+`
dispatch(owner,{action:'remove'});
if(marked||claimed||sprintf('%J',calls)!=sprintf('%J',['clear','unlink']))die('orphaned_marks_not_cleaned');
dispatch(owner,{action:'remove'});
if(marked||claimed)die('repeated_remove_not_clean');
present=true;claimed=true;marked=2;clear_fails=true;
let failed=false;
try {dispatch(owner,{action:'remove'});} catch(error) {failed=error.message=='compatibility_conntrack_cleanup_failed';}
if(!failed||!present||!claimed||!marked)die('failed_cleanup_dropped_owned_resources');
clear_fails=false;
dispatch(owner,{action:'remove'});
if(present||claimed||marked)die('retry_did_not_finish_cleanup');
native_present=false;claimed=true;
failed=false;try {dispatch(owner,{action:'remove'});} catch(error) {failed=error.message=='compatibility_conntrack_cleanup_failed';}
if(!failed||!claimed)die('missing_cleaner_discarded_claim');
claimed=false;
dispatch(owner,{action:'remove'});
`)();
print('interception cleanup: orphaned marks, repeat removal, failed cleanup and retry passed\n');
