import * as fs from 'fs';
import * as socket from 'socket';
import * as uloop from 'uloop';
const revision=sprintf('%064d',0);
if(ARGV[0]=='--server') {
    const server=socket.listen({path:ARGV[1]+'/engine/engine.sock'},null,{socktype:socket.SOCK_STREAM});
    if(!server) die('fixture_listen_failed');
    for(let i=0;i<2;i++) {
        socket.poll(1500,[server,socket.POLLIN]);
        const conn=server.accept();if(!conn) die('fixture_accept_failed');
        const query=conn.recv(4096);sleep(100);
        const response=index(query,'show stat')==0?'# pxname,svname,scur\ningress,FRONTEND,0\nloopback_convert,BACKEND,0\n':
            'Pid: 42\ndescription: '+revision+'\nVersion: fixture\n';
        conn.send(response,socket.MSG_NOSIGNAL);conn.close();
    }
    server.close();exit(0);
}
const root=ARGV[0],run=fs.mkdtemp('/tmp/netfleet-health-signal.XXXXXX');fs.mkdir(run+'/engine',0700);
const io=loadfile(root+'/io.uc')()({root}),policy=loadfile(root+'/policy.uc')()();
const engine=loadfile(root+'/haproxy.uc')()(io,policy,{run,ca:run+'/ca'}),interpreter=fs.readlink('/proc/self/exe');
uloop.init();let timer,signal_child,complete=false,failure=null;
const server=uloop.process('/usr/bin/timeout',['-k','1','3',interpreter,sourcepath(),'--server',run],null,code=>{
    if(code) failure??='fixture_server_failed';uloop.end();
});
timer=uloop.timer(10,()=>{
    if(!fs.lstat(run+'/engine/engine.sock')) {timer.set(10);return;}
    signal_child=uloop.process(interpreter,['-e','sleep(30);'],null,()=>{});
    try {const live=engine.health();complete=live.ready&&live.pid==42&&live.revision==revision;}
    catch(error) {failure=error.message;}
});
uloop.run();fs.unlink(run+'/engine/engine.sock');fs.rmdir(run+'/engine');fs.rmdir(run);
if(failure||!complete) die(failure ?? 'health_signal_not_verified');
print('health socket: asynchronous child signal preserves response and original deadline\n');
