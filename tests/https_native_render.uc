import * as fs from 'fs';
const root=ARGV[0]+'/openwrt/https-compat/files/usr/libexec/opl-netfleet-compat';
const io=loadfile(root+'/io.uc')()({root});
const policy=loadfile(root+'/policy.uc')()();
const engine=loadfile(root+'/haproxy.uc')()(io,policy,{run:'/tmp/netfleet-native-render',ca:'/tmp/netfleet-native-render/ca'});
const config=json(fs.readfile(ARGV[1]));
const result=engine.configuration(config,'/tmp/netfleet-native-render',engine.revision(config));
print(sprintf('%J\n',result));
