#!/usr/bin/ucode
import * as fs from 'fs';
import { apply_dns as subscription_dns } from '../plugins/models/lib/subscription-dns.uc';
import { create as create_rules } from '../plugins/mihomo/lib/profile.uc';

const root_plugins = fs.realpath(replace(sourcepath(), /[^/]+$/, '../plugins'));

function test_gateway_cleanup() {
	const path = `${root_plugins}/mihomo/lib/gateway.uc`;
	const source = fs.readfile(path);
	const start = index(source, 'cleanup = function(');
	const end = index(source, 'attach = function(', start);
	if (start < 0 || end < 0) die('gateway cleanup implementation unavailable');
	const implementation = substr(source, start, end - start);
	loadstring(`
let cleanup, commands = [], removed = false, compatibility_fails = true;
let table_present = true, native_present = true, clear_fails = false, marked = 2, claim = true, clear_calls = 0;
const SERVICE = "test-core", OWNERSHIP = "/unused/owner.json", STATE = "/unused";
const fs = { unlink: path => { if (path == OWNERSHIP) removed = true; else claim = false; return true; },
  stat: path => path == "/usr/lib/ucode/netfleet_interception.so" ? native_present : claim };
function require(name) { return { clear_marked: () => { clear_calls++; if (clear_fails) die("mark_cleanup_failed"); marked = 0; } }; }
function ownership() { return { service: SERVICE, table: "11900", pref: "11900",
  mark: "0x40000000", mask: "0x40000000", families: [4, 6], bridge: {} }; }
function shell(command) {
  push(commands, command);
  if (command == "nft list table inet netfleet_compat") return table_present;
  if (command == "nft delete table inet netfleet_compat" && !compatibility_fails) table_present = false;
  return command != "nft delete table inet netfleet_compat" || !compatibility_fails;
}
function capture(command) { return ""; }
function shell_quote(value) { return value; }
` + implementation + `
let result = cleanup();
if (result.ok || result.error != "compatibility_cleanup_failed" || !result.result.base_clean ||
    !removed || !claim || clear_calls || index(commands, "nft delete table inet netfleet") < 0 ||
    index(commands, "ip -4 rule del pref 11900 fwmark 0x40000000/0x40000000 table 11900") < 0 ||
    index(commands, "ip -6 route del local default dev lo table 11900") < 0)
  die("optional failure prevented base cleanup or was reported as success");
compatibility_fails = false;
result = cleanup();
if (!result.ok || !result.result.clean || marked || claim || clear_calls != 1) die("successful cleanup regressed");
marked = 3; claim = true;
result = cleanup();
if (!result.ok || marked || claim || clear_calls != 2) die("absent table left compatibility marks");
clear_fails = true; claim = true; marked = 1; removed = false;
result = cleanup();
if (result.ok || !removed || !claim || !marked || !result.result.base_clean) die("failed mark cleanup lost retry state or blocked base stop");
clear_fails = false; native_present = false;
result = cleanup();
if (result.ok || !claim) die("missing native cleaner reported a claimed dataplane clean");
claim = false;
result = cleanup();
if (!result.ok) die("legacy unclaimed gateway cannot stop");
`)();
	print('gateway_cleanup_contract_ok\n');
}

function test_interception_cleanup() {
	const path = `${root_plugins}/mihomo/lib/interception.uc`;
	const source = fs.readfile(path);
	const start = index(source, '    function dispatch(owner,input) {');
	const end = index(source, '    function request(owner,input)', start);
	if (start < 0 || end < 0) die('interception_dispatch_unavailable');
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
` + substr(source, start, end - start) + `
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
}

function test_native_profile() {
	const path = `${root_plugins}/mihomo/lib/gateway.uc`;
	const source = fs.readfile(path);
	const start = index(source, 'render_profile = function() {');
	const end = index(source, 'prepare = function()', start);
	const merge_start = index(source, 'merge = function(');
	const merge_end = index(source, 'source_path = function(', merge_start);
	if (start < 0 || end < 0 || merge_start < 0 || merge_end < 0) die('native_profile_renderer_unavailable');
	const profile_rules = create_rules();
	const suite = loadstring(`
return function(profile_rules, subscription_dns) {
let render_profile,merge,profile_source,extra,overlay={};
const BASE='/private',RUN='/private/run',VENDOR='/vendor';
const paths={BACKEND_PATH:'/etc/opl-netfleet/backend.json'};
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
` + substr(source, merge_start, merge_end - merge_start) + substr(source, start, end - start) + `
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
profile_source['netfleet-subscription-dns']={'node.test':['https://dns.test/current-account']};
profile_source.dns['proxy-server-nameserver-policy']={'node.test':['https://dns.test/current-account']};
extra.dns={'proxy-server-nameserver':['system'],'proxy-server-nameserver-policy':{
 'node.test':['https://dns.test/stale-account'],'+.test':['https://dns.test/stale-suffix'],
 'NODE.TEST.':['https://dns.test/stale-case'],'manual.example':['192.0.2.53']}};
extra['netfleet-subscription-dns']={'node.test':['https://dns.test/forged-owner']};
const dns_input=sprintf('%J',{profile_source,extra}),dns_profile=render_profile().result.profile;
check(dns_profile.dns['proxy-server-nameserver-policy']['node.test'][0]=='https://dns.test/current-account','manual_rule_overrode_subscription_DNS');
check(dns_profile.dns['proxy-server-nameserver-policy']['NODE.TEST.']==null,'duplicate_case_rule_survived_projection');
check(dns_profile.dns['proxy-server-nameserver-policy']['manual.example'][0]=='192.0.2.53','unrelated_manual_DNS_changed');
check(dns_profile['netfleet-subscription-dns']['node.test'][0]=='https://dns.test/current-account','private_mixin_forged_DNS_ownership');
check(sprintf('%J',{profile_source,extra})==dns_input,'DNS_renderer_mutated_private_inputs');
delete profile_source['netfleet-subscription-dns'];delete profile_source.dns['proxy-server-nameserver-policy'];
extra={sniffer:{sniff:{TLS:{port:[8443],'override-destination':false}}}};
const legacy=sprintf('%J',extra),legacy_render=render_profile().result.profile;
check(sprintf('%J',legacy_render.sniffer.sniff.TLS.ports)==sprintf('%J',[8443]),'legacy_override_lost_to_inherited_ports');
check(legacy_render.sniffer.sniff.TLS.port==null&&sprintf('%J',extra)==legacy,'legacy_port_conversion_mutated_private_input');
return profile;
};`)();
	const profile = suite(profile_rules, subscription_dns);
	if (ARGV[0]) {
		if (!fs.writefile(ARGV[0], sprintf('%J', profile))) die('fixture_profile_write_failed');
	}
	print('native profile: TLS DNS identity, protocol exclusions and private input preservation passed\n');
}

function test_native_setup() {
	const subscriptions_model = loadfile(`${root_plugins}/models/lib/subscriptions.uc`)()({});
	const setup_model = loadfile(`${root_plugins}/setup/lib/native-model.uc`)()({
		use: name => name == 'models.subscriptions' ? subscriptions_model : null
	});
	const validate_request = setup_model.validate_request;
	const upstream_candidates = setup_model.upstream_candidates;

	function check(value, reason) {
		if (!value) { print(`${reason}\n`); exit(1); }
	}
	const source = { id: 'alpha', name: 'Alpha', url: 'https://subscription.example.invalid/profile?token=private' };
	const request = { confirmed: true, revision: 'revision', source: source };
	const accepted = validate_request(request, 'revision');
	check(accepted.ok && accepted.source.id == 'alpha' && accepted.source.user_agent == 'clash.meta', 'initial_source_rejected');
	check(!validate_request({ ...request, confirmed: false }, 'revision').ok, 'confirmation_required');
	check(!validate_request(request, 'new-revision').ok, 'stale_setup_rejected');
	check(!validate_request({ ...request, overwrite: true }, 'revision').ok, 'unknown_setup_field_rejected');
	check(!validate_request({ ...request, source: { ...source, url: 'file:///etc/passwd' } }, 'revision').ok,
		'local_source_rejected');
	check(!validate_request({ ...request, source: { ...source, id: '../alpha' } }, 'revision').ok, 'source_path_rejected');
	check(!validate_request({ ...request, source: { ...source, user_agent: 'agent\nheader' } }, 'revision').ok,
		'source_control_character_rejected');
	check(!validate_request({ ...request, source: { ...source, info_url: source.url } }, 'revision').ok,
		'unrequested_setup_source_field_rejected');
	const upstream = upstream_candidates([
		{ interface: 'lan', up: true, 'ipv4-address': [{ address: '192.0.2.1' }], 'dns-server': ['203.0.113.10'] },
		{ interface: 'wan', up: true, 'ipv4-address': [{ address: '192.0.2.2' }],
			'dns-server': ['192.0.2.1', '192.0.2.2', '127.0.0.1', '0.0.0.0', '300.1.1.1', '224.0.0.1',
				'198.51.100.53', '198.51.100.53', 'https://resolver.example.invalid/dns-query', '1.1.1.1;exit'] },
		{ interface: 'wan6', up: true, 'ipv6-address': [{ address: '2001:db8::1' }],
			'dns-server': ['2001:db8::1', '2001:db8::53', 'fe80::53', 'febf::53', '::', '::1', '0:0:0:0:0:0:0:1'] },
		{ interface: 'wan', up: false, 'dns-server': ['203.0.113.53'] }
	]);
	check(length(upstream) == 2 && upstream[0] == '198.51.100.53' && upstream[1] == '2001:db8::53',
		'only_current_wan_ip_resolvers');
	check(length(upstream_candidates([])) == 0, 'no_invented_dns_default');
	print('native_setup_contract passed\n');
}

function test_rule_data() {
	let count = 0;
	function check(value, message) { if (!value) die(message); count++; }
	let history = {}, active = null, pending = false;
	const ports = {
		'platform.paths': { RULE_DATA_ROOT: '/etc/opl-netfleet/native/run/rule-data', BACKEND_RUN_DIR: '/etc/opl-netfleet/native/run',
			RULE_LOCK_PATH: '/etc/opl-netfleet/rulesets.lock.json', BACKEND_PATH: '/etc/opl-netfleet/backend.json' },
		'platform.files': { private_file: p => index(p, 'history.json') >= 0 || (index(p, 'active.json') >= 0 && active != null) || (index(p, 'pending.json') >= 0 && pending) || index(p, '.mrs') >= 0 },
		'platform.storage': { read_json: p => index(p, 'backend.json') >= 0 ? { kind: 'native-mihomo' } : index(p, 'history.json') >= 0 ? history : active },
		'platform.process': { shell_quote: v => v }
	};
	const factory = loadfile(`${root_plugins}/mihomo/lib/rule-data.uc`)();
	const data = factory({ use: name => ports[name] }, {});
	const policy = { policy_source: { kind: 'bundle', ref: 'bundle:base-v1' }, automation: { rule_refresh_enabled: true, rule_refresh_interval_seconds: 604800 } };
	check(data.status(policy).enabled, 'builtin native policy supports scheduled updates');
	check(data.status({ policy_source: { kind: 'profile', ref: 'subscription:fixture' } }).supported == false, 'user profiles do not opt into builtin replacement');
	history = { last_success_at: 1000000, last_attempt_at: 1000000, last_ok: true };
	check(data.status(policy).next_run_at == 1604800, 'next deadline is persisted success plus one week');
	history = { last_success_at: 1, last_attempt_at: 2000000, last_ok: false };
	check(data.status(policy).next_run_at == 2003600, 'failure retries after one hour without advancing success');
	const parsed = data.cidrs('# fixture\n203.0.113.0/24\n2001:db8::/32\n');
	check(parsed.china_ip[0].prefix.len == 24 && parsed.china_ip6[0].prefix.len == 32, 'both address families retained');
	let rejected = false; try { data.cidrs('203.0.113.0/24;flush ruleset\n2001:db8::/32'); } catch (e) { rejected = true; }
	check(rejected, 'CIDR input cannot inject nft commands');
	rejected = false; try { data.cidrs('203.0.113.0/24'); } catch (e) { rejected = true; }
	check(rejected, 'partial address-family download is rejected');
	const batch = data.batch(parsed);
	check(length(batch.nftables) == 4 && batch.nftables[0].flush.set.table == 'netfleet', 'one batch touches only owned country sets');
	active = { directory: '/etc/opl-netfleet/native/run/rule-data/generation.fixture', commit: 'a', rules: { 'cn-domain': { path: '/etc/opl-netfleet/native/run/rule-data/generation.fixture/cn-domain.mrs' } } };
	const profile = { 'rule-providers': { 'cn-domain': { type: 'file', path: './rulesets/cn-domain.mrs' } } };
	check(data.project(profile)['rule-providers']['cn-domain'].path == active.rules['cn-domain'].path, 'accepted generation used at next start');
	const custom = { 'rule-providers': { 'cn-domain': { type: 'http', url: 'https://fixture.invalid/rules' } } };
	check(data.project(custom)['rule-providers']['cn-domain'].type == 'http', 'custom source owner retained');
	check(data.status(policy).last_success_at == 1, 'failed update preserves success baseline');
	printf('rule data: %d assertions passed\n', count);
}

test_gateway_cleanup();
test_interception_cleanup();
test_native_profile();
test_native_setup();
test_rule_data();
