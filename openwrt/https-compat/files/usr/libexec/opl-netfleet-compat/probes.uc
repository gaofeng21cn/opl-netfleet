import * as fs from 'fs';
import * as uloop from 'uloop';
return function(io,run) {
    const results={},pending={};let serial=0;
    function request(kind,rule,egress) {
        const key=io.sha256(io.canonical([kind,rule.domain,rule.port,egress]));
        const saved=results[key],now=io.now();
        if(!pending[key]&&(!saved||now-saved.at>=10)&&length(pending)<4) {
            const path=`${run}/probe-${serial++}.json`;
            io.write(path,'');
            const ports=egress?.port_range ?? [0,0];
            const args=[io.root+'/tls-probe',kind,rule.domain,rule.port,...(kind=='upstream'?ports:[])];
            const child=uloop.process('/bin/sh',['-c',`exec ${join(' ',map(args,io.quote))} > ${io.quote(path)} 2>/dev/null`],null,code=>{
                let value;
                try {value=io.read(path);} catch (_) {}
                if(type(value)!='object') value={ok:false,reason:'engine_probe_unavailable'};
                results[key]={at:io.now(),value:{...value,at:time()}};
                delete pending[key];fs.unlink(path);
            });
            if(child) pending[key]=child;
            else {fs.unlink(path);results[key]={at:now,value:{ok:false,reason:'engine_probe_unavailable',at:time()}};}
        }
        // Obsolete results cannot authorize a different target or egress policy.
        for(let name in results) if(now-results[name].at>60) delete results[name];
        return saved&&now>=saved.at&&now-saved.at<20?saved.value:null;
    }
    return {request};
};
