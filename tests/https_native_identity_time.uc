import * as fs from 'fs';
const root=ARGV[0],directory=fs.mkdtemp('/tmp/netfleet-identity-time.XXXXXX');
const base=directory+'/base',run=directory+'/run';fs.mkdir(base,0700);fs.mkdir(run,0700);
let now;
const config={enabled:true,source:'local',interfaces:['observe0']},mac='02:00:00:00:00:01',address='2001:db8::1234';
const owner=loadfile(ARGV[1])()({base,run,helper:directory+'/unused',monotonic:()=>now});
const consumer=loadstring(replace(fs.readfile(root+'/identity.uc'),
    '/var/run/opl-netfleet-device-identity/evidence.json',run+'/evidence.json'))()({
    read:path=>json(fs.readfile(path)),now:()=>now});
const device={identity:{binding:owner.binding(config),mac}};
fs.writefile(base+'/loaded.json','true');
function write(path,value){fs.writefile(path,sprintf('%J',value));}
function seed(sample,expiry) {
    write(run+'/cache.json',{revision:owner.revision(config),monotonic:sample,devices:[
        {mac,addresses:[address],address_expires:{[address]:expiry},ttl:120}]});
}
function check(value,message){if(!value)die(message);}
for(let sample in [100.02,100.09,122.51,128.02,155.68,185.73,1000.01,200000.01]) {
    now=sample+0.5;seed(sample,sample+120);
    check(length(owner.status(config).devices[0].addresses)==1,'source_rejects_rounded_deadline');
    owner.publish(config);
    const result=consumer.resolve({devices:[device]});
    check(result.source_ready&&length(consumer.addresses(device,result))==1,'consumer_rejects_rounded_deadline');
    check(result.devices[0].expires_in<=120,'address_ttl_extended');
    now=sample+120;
    check(!length(owner.status(config).devices[0].addresses),'source_keeps_expired_address');
    check(!length(consumer.addresses(device,consumer.resolve({devices:[device]}))),'consumer_keeps_expired_address');
}
now=100.52;seed(100.02,220.02001);
check(!length(owner.status(config).devices[0].addresses),'source_accepts_excess_ttl');
write(run+'/evidence.json',{schema:1,binding:owner.binding(config),source_ready:true,sampled_monotonic:100.02,
    devices:[{mac,address_expires:{[address]:220.02001}}]});
check(!consumer.resolve({devices:[device]}).source_ready,'consumer_accepts_excess_ttl');
for(let path in [base,run]){for(let file in fs.lsdir(path))fs.unlink(path+'/'+file);fs.rmdir(path);}fs.rmdir(directory);
print('identity time: JSON round-trip, original TTL cap and expiry passed\n');
