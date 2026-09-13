// No production invocation: suspends only its own disposable probe child.
import * as fs from 'fs';
assert(getenv('NETFLEET_ISOLATED_NATIVE_TEST')=='1');
const helper=require('netfleet_probe'),run=ARGV[0],uid=+ARGV[1],gid=+ARGV[2];
function children() {
 const parent=+fs.readlink('/proc/self');
 return map(filter(fs.lsdir('/proc'),name=>match(name,/^[0-9]+$/)&&
  +(match(fs.readfile(`/proc/${name}/status`) ?? '',/\nPPid:\s*(\d+)/)?.[1] ?? 0)==parent),name=>+name);
}
function now() {return +split(fs.readfile('/proc/uptime'),' ')[0];}
function check(value) {assert(value.ipv4.ok&&value.ipv6.ok,sprintf('%J',value));}
let session=helper.open(run,uid,gid);check(session.request());
const pid=filter(children(),p=>index(fs.readfile(`/proc/${p}/cmdline`) ?? '','tls-probe')>=0)[0];assert(pid>1);
const identity=fs.readfile(`/proc/${pid}/status`);
assert(match(identity,/\nCapEff:\s*0+\n/)!=null,'probe retained capabilities');
const users=match(identity,/\nUid:\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)/);
assert(users&&length(filter(slice(users,1),value=>+value!=uid))==0,'probe retained root');
assert(fs.readfile(`/proc/${pid}/cgroup`)==fs.readfile('/proc/self/cgroup'),'probe escaped manager accounting');
const lock=fs.open('/tmp/probe-session-lock','ae',0600);assert(lock.lock('xn'));
const second=helper.open(run,uid,gid);check(second.request());lock.lock('u');lock.close();
for(let child in children())for(let fd in fs.lsdir(`/proc/${child}/fd`) ?? [])
 assert(fs.readlink(`/proc/${child}/fd/${fd}`)!='/tmp/probe-session-lock','child inherited mutation lock');
second.close();
for(let n=0;n<100;n++) check(session.request());
assert(system(['kill','-STOP',pid])==0);let failed=false,started=now();
try {session.request();}catch(_){failed=true;}
assert(failed&&now()-started<1.7,'parent did not bound a stuck worker');
session.close();assert(!fs.stat(`/proc/${pid}`),'stalled child not reaped');
session=helper.open(run,uid,gid);check(session.request());session.close();
failed=false;try {session.request();}catch(_){failed=true;}assert(failed,'closed channel returned stale success');
fs.unlink('/tmp/probe-session-lock');
print('probe session: fresh dual-stack checks, permanent privilege drop, accounting, descriptor isolation, stall deadline and child recovery passed\n');
