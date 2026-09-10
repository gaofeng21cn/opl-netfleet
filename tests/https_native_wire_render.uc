import * as fs from 'fs';
const root=ARGV[0],run=ARGV[1],port=+ARGV[2];
const io=loadfile(root+'/io.uc')()({root});
const policy=loadfile(root+'/policy.uc')()();
const engine=loadfile(root+'/haproxy.uc')()(io,policy,{run,ca:run+'/ca'});
print(sprintf('%J\n',engine.configuration(json(fs.readfile(run+'/config.json')),run,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',port)));
