// Disposable OpenWrt guest only. Exercise kernel replies, not a mocked transport.
import * as fs from 'fs';
const io=require('netfleet_interception');
assert(getenv('NETFLEET_ISOLATED_NATIVE_TEST')=='1');
function command(text) {const p=fs.popen(text,'r'),out=p.read('all'),rc=p.close();assert(rc==0,text);return out;}
function nft(text) {const p=fs.popen('nft -f -','w');p.write(text+'\n');assert(p.close()==0,text);}
function rejects(work) {let rejected=false;try {work();} catch(e) {rejected=e.message=='gateway_command_failed'||e.message=='invalid_lease_candidate';}assert(rejected,'invalid observation accepted');}
const initial=io.observe();assert(initial.present&&initial.guard);
assert(sprintf('%J',sort(initial.interfaces))=='[ "br-lan", "nf-observe" ]');
const protected=command('nft -j list table inet netfleet');
const pairs=[['192.0.2.22','198.51.100.0/24',443],['2001:db8::22','2001:db8:8::/64',8443]];
assert(io.renew(pairs,initial.generation).leases==2);
assert(io.status().leases==2);
const cli=json(command('nft -j list table inet netfleet_compat'));
let live=0;
for(let row in cli.nftables) for(let item in row.set?.elem ?? []) {
 assert(item.elem.expires>=8&&item.elem.expires<=10,'invalid kernel deadline');live++;
}
assert(live==2,'independent CLI readback');
rejects(()=>io.renew(pairs,initial.generation)); // The write changed the nft generation.
assert(io.status().leases==2,'stale generation mutated existing leases');
for(let bad in [null,{},[['127.0.0.1','0.0.0.0/0',443]],[['192.0.2.22','198.51.100.1/24',443]],
 [['192.0.2.22','198.51.100.1; delete table inet netfleet',443]], [['2001:db8::22','::/0',65536]],
 [['192.0.2.22','::/0',443]], [['fe80::1','::/0',443]]]) rejects(()=>io.renew(bad));
assert(io.status().leases==2,'invalid input changed lease');
const all=[];
for(let n=0;n<4096;n++) push(all,n%2?['2001:db8::22','2001:db8:8::1',10000+n]:['192.0.2.22','198.51.100.1',10000+n]);
assert(io.renew(all).leases==4096,'maximum dual stack transaction');
assert(io.status().leases==4096);
push(all,all[0]);rejects(()=>io.renew(all));
assert(io.renew([]).leases==0&&!io.status().intercepting);
assert(command('nft -j list table inet netfleet')==protected,'private I/O changed the base');
io.renew(pairs);sleep(10200);assert(!io.status().intercepting,'leases survived manager silence');
// Permanent or malformed elements must not masquerade as an empty lease set.
nft('add element inet netfleet_compat targets4 { 192.0.2.22 . 198.51.100.1 . 443 timeout 1h }');
rejects(()=>io.status());io.renew([]);
nft('flush chain inet netfleet mangle_prerouting_lan\nadd rule inet netfleet mangle_prerouting_lan counter');
assert(!io.observe().guard,'counter-only guard accepted');
nft('flush chain inet netfleet mangle_prerouting_lan\nadd rule inet netfleet mangle_prerouting_lan ct mark & 0x02000000 != 0 return');
assert(!io.observe().guard,'different ownership bit accepted');
nft('flush chain inet netfleet mangle_prerouting_lan\nadd rule inet netfleet mangle_prerouting_lan ct mark & 0x01000000 != 0 return');
assert(io.observe().guard,'valid guard not recovered');
command('ip -4 rule add fwmark 0x80/0xff lookup 80; ip -4 route add local default dev lo table 80; ip -6 rule add fwmark 0x80/0xff lookup 80; ip -6 route add local default dev lo table 80');
assert(io.routes(80,[4,6]));command('ip -6 route del local default dev lo table 80');assert(!io.routes(80,[4,6]));
command('ip -4 rule del fwmark 0x80/0xff lookup 80; ip -4 route del local default dev lo table 80; ip -6 rule del fwmark 0x80/0xff lookup 80');
assert(io.port_range(40000,50000));
nft('delete table inet netfleet_compat');assert(!io.table().exists&&!io.status().intercepting);
rejects(()=>io.renew(pairs));assert(io.renew([]).leases==0);
print('native I/O: dual stack ranges, 4096 candidates, invalid inputs, generation, independent readback, expiry, guard and route changes passed\n');
