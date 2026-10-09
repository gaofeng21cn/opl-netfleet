import * as fs from 'fs';
import { create as create_rules } from '../openwrt/files/usr/libexec/opl-netfleet/plugins/mihomo/lib/profile.uc';
const path=replace(sourcepath(), /[^/]+$/, '../openwrt/files/usr/libexec/opl-netfleet/plugins/mihomo/lib/gateway.uc');
const source=fs.readfile(path),start=index(source,'render_profile = function() {'),end=index(source,'prepare = function()',start);
const merge_start=index(source,'merge = function('),merge_end=index(source,'source_path = function(',merge_start);
if(start<0||end<0||merge_start<0||merge_end<0)die('native_profile_renderer_unavailable');
const profile_rules=create_rules();
const suite=loadstring(`
return function(profile_rules) {
let render_profile,merge,profile_source,extra,overlay={};
const BASE='/private',RUN='/private/run',VENDOR='/vendor';
const fs={lstat:()=>true};
const rule_data={project:profile=>profile};
function source_path(value) {return '/source';}
function uci_value(section,key,fallback) {return section=='proxy'?'tproxy':fallback;}
function enabled(section,key) {return false;}
function read_json(path) {return path=='/etc/opl-netfleet/backend.json'?{kind:'native-mihomo'}:extra;}
function read_yaml(path) {return profile_source;}
function capture(command) {return sprintf('%J',overlay);}
function parse(value) {return json(value);}
function shell_quote(value) {return value;}
function fixture(sniffer) {
 profile_source={sniffer,'allow-lan':true,'tproxy-port':9898,dns:{enable:true,listen:'127.0.0.1:1053'}};
 extra={};return render_profile().result.profile;
}
function check(ok,reason) {if(!ok)die(reason);}
`+substr(source,merge_start,merge_end-merge_start)+substr(source,start,end-start)+`
const sniff={TLS:{ports:[443,'8443-8445'],'override-destination':false},HTTP:{ports:[80],'override-destination':false}};
const sniffer={enable:true,'force-dns-mapping':true,'parse-pure-ip':true,'skip-domain':['skip.example'],sniff};
const original=sprintf('%J',sniffer),profile=fixture(sniffer);
check(profile.sniffer.sniff.TLS['override-destination']===true,'dns_mapped_tls_kept_wrong_dial_domain');
check(sprintf('%J',sniffer)==original,'renderer_mutated_source_sniffer');
check(sprintf('%J',profile.sniffer.sniff.TLS.ports)==sprintf('%J',sniff.TLS.ports),'tls_ports_changed');
check(profile.sniffer.sniff.HTTP['override-destination']===false,'http_policy_changed');
check(sprintf('%J',profile.sniffer['skip-domain'])==sprintf('%J',sniffer['skip-domain']),'skip_domains_changed');
check(fixture({...sniffer,enable:false}).sniffer.sniff.TLS['override-destination']===false,'disabled_sniffer_rewritten');
check(fixture({...sniffer,'force-dns-mapping':false}).sniffer.sniff.TLS['override-destination']===false,'non_mapped_policy_rewritten');
check(fixture({...sniffer,'force-dns-mapping':false,'force-domain':['forced.example']}).sniffer.sniff.TLS['override-destination']===true,'forced_domain_tls_kept_wrong_dial_domain');
check(fixture({...sniffer,sniff:{HTTP:sniff.HTTP}}).sniffer.sniff.TLS==null,'tls_protocol_invented');
fixture(sniffer);extra={sniffer:{sniff:{TLS:{'override-destination':false}}}};
const before=sprintf('%J',extra);
check(render_profile().result.profile.sniffer.sniff.TLS['override-destination']===true,'private_override_bypassed_tls_identity');
check(sprintf('%J',extra)==before,'private_mixin_mutated');
extra={sniffer:{sniff:{TLS:{port:[8443],'override-destination':false}}}};
const legacy=sprintf('%J',extra),legacy_render=render_profile().result.profile;
check(sprintf('%J',legacy_render.sniffer.sniff.TLS.ports)==sprintf('%J',[8443]),'legacy_override_lost_to_inherited_ports');
check(legacy_render.sniffer.sniff.TLS.port==null&&sprintf('%J',extra)==legacy,'legacy_port_conversion_mutated_private_input');
return profile;
};`)();
const profile=suite(profile_rules);
if(ARGV[0]) {if(!fs.writefile(ARGV[0],sprintf('%J',profile)))die('fixture_profile_write_failed');}
print('native profile: TLS DNS identity, protocol exclusions and private input preservation passed\n');
