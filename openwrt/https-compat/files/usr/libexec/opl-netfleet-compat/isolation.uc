import * as fs from 'fs';
return function(io,base,run) {
    const group='/sys/fs/cgroup/netfleet-compat';
    const budgets={'memory.max':'201326592','memory.swap.max':'0','memory.oom.group':'1','pids.max':'32','cpu.max':'50000 100000'};
    function account() {
        const users=map(split(fs.readfile('/etc/passwd') ?? '', '\n'),line=>split(line,':'));
        const groups=map(split(fs.readfile('/etc/group') ?? '', '\n'),line=>split(line,':'));
        const user=filter(users,row=>row[0]=='netfleet-compat')[0],grp=filter(groups,row=>row[0]=='netfleet-compat')[0];
        const uid=+user?.[2],gid=+grp?.[2];
        if(!(uid>0&&gid>0)||+user[3]!=gid||length(filter(users,row=>+row[2]==uid))!=1||length(filter(groups,row=>+row[2]==gid))!=1) die('engine_identity_invalid');
        return {uid,gid};
    }
    function prepare() {
        const ids=account(),ca=run+'/ca';io.mkdir(run);io.mkdir(ca);
        for(let path in [run,ca]) if(!fs.chown(path,0,ids.gid)||!fs.chmod(path,0750)) die('engine_directory_unsafe');
        for(let name in fs.lsdir(base+'/ca') ?? []) {
            if(!match(name,/^[a-z0-9-]+\.pem$/)) continue;
            const src=base+'/ca/'+name,info=fs.lstat(src);
            if(info?.type!='file'||info.uid!=0||info.mode&0022) die('engine_ca_unsafe');
            const target=ca+'/'+name;
            if(fs.lstat(target)?.type=='link') die('engine_ca_unsafe');
            io.write(target,fs.readfile(src));
            if(!fs.chown(target,0,ids.gid)||!fs.chmod(target,0640)) die('engine_ca_unsafe');
        }
        const engine=run+'/engine',info=fs.lstat(engine);
        if(info && (info.type!='directory'||index([0,ids.uid],info.uid)<0)) die('engine_directory_unsafe');
        if(!info&&!fs.mkdir(engine,0700)) die('engine_directory_unsafe');
        if(!fs.chown(engine,ids.uid,ids.gid)||!fs.chmod(engine,0700)) die('engine_directory_unsafe');
        return ids;
    }
    function readable() {
        const ids=account();
        for(let name in ['rules.map','haproxy.cfg','effective.json']) {
            const path=run+'/'+name;
            if(fs.lstat(path)?.type!='file'||!fs.chown(path,0,ids.gid)||!fs.chmod(path,0640)) die('engine_config_unsafe');
        }
    }
    function status() {
        const limits={};for(let name in budgets) {const raw=fs.readfile(group+'/'+name);if(raw==null) return {supported:false,enforced:false};limits[name]=trim(raw);}
        return {supported:true,enforced:io.canonical(limits)==io.canonical(budgets),limits};
    }
    function counters() {
        const result={};
        for(let kind in ['engine','manager']) {
            const path=kind=='engine'?group:group+'-manager',values={};
            for(let file in ['cpu.stat','memory.events']) for(let line in split(fs.readfile(path+'/'+file) ?? '', '\n')) {
                const fields=split(trim(line),/\s+/);
                if(length(fields)==2&&match(fields[1],/^[0-9]+$/)) values[fields[0]]=+fields[1];
            }
            result[kind]=values;
        }
        return result;
    }
    function delta(before) {
        const after=counters(),result={};
        for(let kind,values in after) {
            result[kind]={};
            for(let key,value in values) if(type(before?.[kind]?.[key])=='int'&&value>=before[kind][key]) result[kind][key]=value-before[kind][key];
        }
        return result;
    }
    return {account,prepare,readable,status,counters,delta};
};
