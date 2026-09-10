import * as fs from 'fs';
const root=ARGV[0],run=ARGV[1],action=ARGV[2];
const io=loadfile(root+'/io.uc')()({root,process:loadfile((ARGV[3] ?? '/usr/libexec/opl-netfleet')+'/plugins/platform/lib/process.uc')()({})});
const policy=loadfile(root+'/policy.uc')()();
const engine=loadfile(root+'/haproxy.uc')()(io,policy,{run,ca:run+'/ca'});
if(action=='prepare') {
    io.mkdir(run);io.mkdir(run+'/engine');engine.prepare_ca();
    const config={schema:1,enabled:true,devices:[],rules:[]};
    engine.prepare(config);
    print(sprintf('%J\n',{fingerprint:engine.fingerprint()}));
} else if(action=='health') print(sprintf('%J\n',engine.health()));
else if(action=='probe') print(sprintf('%J\n',engine.probe(null,65534)));
else die('unknown_test_action');
