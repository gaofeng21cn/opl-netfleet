import * as fs from 'fs';
import * as uloop from 'uloop';
const root=ARGV[0],process=loadfile(root+'/plugins/platform/lib/process.uc')()({});
const io=loadfile(ARGV[1]+'/io.uc')()({root:ARGV[1],process});
const before=filter(fs.lsdir('/tmp'),name=>index(name,'netfleet-capture.')==0);
const payload='{"ok":true,"data":"'+sprintf('%8192s','')+'"}',interpreter=fs.readlink('/proc/self/exe');
const producer='print('+sprintf('%J',payload)+'); sleep(100);';
uloop.init();let timer,round=0;const children=[];
timer=uloop.timer(0,()=>{
    // Exit an unrelated asynchronous child while the foreground producer runs.
    push(children,uloop.process(interpreter,['-e','sleep(30);'],null,()=>{}));
    const value=io.command([interpreter,'-e',producer],2);
    if(value!=payload) die('signal_truncated_command_output');
    if(++round==20) uloop.end(); else timer.set(10);
});
uloop.run();
const binary='a\u0000b\n';
const echoed=process.capture('cat',2,binary);
if(echoed.status!=0||echoed.output!=binary) die('binary_capture_changed');
const failed=process.capture("printf 'business-error'; exit 7",2);
if(failed.status!=7||failed.output!='business-error') die('exit_status_not_preserved');
const started=+split(fs.readfile('/proc/uptime'),' ')[0];
const timed=process.capture('exec sleep 10',1);
if(timed.status==0||+split(fs.readfile('/proc/uptime'),' ')[0]-started>3) die('capture_deadline_failed');
const large=process.capture('dd if=/dev/zero bs=1048576 count=3',2);
if(large.status==0&&large.output!=null) die('capture_size_unbounded');
const after=filter(fs.lsdir('/tmp'),name=>index(name,'netfleet-capture.')==0);
if(sprintf('%J',sort(before))!=sprintf('%J',sort(after))) die('capture_output_leaked');
print('async capture: complete output, binary input, exit status, deadline, output bound and cleanup passed\n');
