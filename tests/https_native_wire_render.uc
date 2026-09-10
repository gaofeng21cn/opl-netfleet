import * as fs from 'fs';
const root=ARGV[0],run=ARGV[1],port=+ARGV[2];
const io=loadfile(root+'/io.uc')()({root});
const policy=loadfile(root+'/policy.uc')()();
const engine=loadfile(root+'/haproxy.uc')()(io,policy,{run,ca:run+'/ca'});
const config=json(fs.readfile(run+'/config.json'));
if(ARGV[2]=='health') print(sprintf('%J\n',engine.health()));
else if(ARGV[2]=='switches') engine.sync_rule_switches(config,engine.health());
else print(sprintf('%J\n',engine.configuration(config,run,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',port)));
