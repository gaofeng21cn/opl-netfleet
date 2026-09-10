import * as fs from 'fs';
import * as uloop from 'uloop';
const root=ARGV[0],run='/tmp/native-async';
const io=loadfile(root+'/io.uc')()({root});io.mkdir(run);
const probes=loadfile(root+'/probes.uc')()(io,run);
uloop.init();
let complete=false,attempt=0,timer;
timer=uloop.timer(0,function(){
    const value=probes.request('resolve',{domain:'localhost',port:443},{});
    if(value){
        if(!value.ok||!length(value.addresses)) die(sprintf('native_resolver_failed: %J',value));
        complete=true;uloop.end();return;
    }
    if(++attempt>100){uloop.end();return;}
    timer.set(50);
});
uloop.run();if(!complete) die('native_async_probe_timeout');
if(length(filter(fs.lsdir(run),name=>match(name,/^probe-/)))) die('probe_output_not_cleaned');
print('native uloop: asynchronous C DNS probe, result caching and output cleanup passed\n');
