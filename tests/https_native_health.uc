import * as fs from 'fs';
import * as socket from 'socket';
import * as uloop from 'uloop';
const cases=[['a',true],[sprintf('%253s','a'),false],[replace(sprintf('%253s',''),' ','a'),true],
    [replace(sprintf('%254s',''),' ','a'),false],['',false],['bad_name',false],['Upper.example',false],['example.test',true]];
const revision=sprintf('%064d',0);
if(ARGV[0]=='--server') {
    const listener=socket.listen({path:ARGV[1]+'/engine/engine.sock'},null,{socktype:socket.SOCK_STREAM});
    if(!listener) die('fixture_listen_failed');
    for(let row in cases) for(let n=0;n<2;n++) {
        if(!socket.poll(2000,[listener,socket.POLLIN])) die('fixture_request_timeout');
        const connection=listener.accept(),request=connection?.recv(4096);
        if(!request) die('fixture_request_missing');
        const response=index(request,'show stat;show info')==0?
            '# pxname,svname,scur,req_tot,hrsp_2xx,hrsp_3xx,hrsp_4xx,econ,eresp\ningress,FRONTEND,2,0,0,0,0,0,0\nloopback_convert,BACKEND,0,0,0,0,0,0,0\nr0_h2,BACKEND,1,7,0,0,1,2,3\n\nPid: 42\ndescription: '+revision+'\nVersion: fixture\n':
            'proc.r0_sni: type=str value=<'+row[0]+'>\n';
        connection.send(response,socket.MSG_NOSIGNAL);connection.close();
    }
    listener.close();exit(0);
}
const root=ARGV[0],run=fs.mkdtemp('/tmp/netfleet-health-fields.XXXXXX');fs.mkdir(run+'/engine',0700);
fs.writefile(run+'/haproxy-rules.json',sprintf('%J',{r0:'rule'}));
const io=loadfile(root+'/io.uc')()({root}),policy=loadfile(root+'/policy.uc')()();
const engine=loadfile(root+'/haproxy.uc')()(io,policy,{run,ca:run+'/ca'}),interpreter=fs.readlink('/proc/self/exe');
uloop.init();let timer,completed=false,failure;
const server=uloop.process('/usr/bin/timeout',['-k','1','10',interpreter,sourcepath(),'--server',run],null,code=>{
    if(code) failure??='fixture_server_failed';uloop.end();
});
timer=uloop.timer(10,()=>{
    if(!fs.lstat(run+'/engine/engine.sock')) {timer.set(10);return;}
    try {
        for(let row in cases) {
            const state=engine.health();
            if(!state.ready||state.pid!=42||state.revision!=revision||state.active_connections!=2||state.active_requests!=1||
                state.rules.rule.requests!=7||state.rules.rule.upstream_protocol!='h2'||state.failure_events[0]?.id!=5) die('health_accounting_changed');
            if(row[1]?state.observed.rule?.domain!=row[0]:state.observed.rule!=null) die('health_sni_boundary_changed');
        }
        completed=true;
    }catch(error){failure=error.message;}
});
uloop.run();for(let file in ['engine/engine.sock','haproxy-rules.json'])fs.unlink(run+'/'+file);fs.rmdir(run+'/engine');fs.rmdir(run);
if(failure||!completed) die(failure ?? 'health_not_verified');
print('health: SNI boundaries, request/drain counters and transport error accounting passed\n');
