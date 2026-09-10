import * as fs from 'fs';
import * as uloop from 'uloop';
return function(io) {
    const evidence = '/var/run/opl-netfleet-device-identity/evidence.json';
    const unavailable = {source_ready:false,reason:'identity_source_unavailable',devices:[]};
    let worker = null, next_sync = 0;
    function schedule() {
        if (worker || io.now() < next_sync) return;
        next_sync = io.now() + 30;
        const path='/var/run/opl-netfleet-compat/identity-sync.json';
        io.atomic(path,{request:{id:'device-identity',action:'sync',params:{}}});
        worker=uloop.process('/usr/bin/timeout',['-k','1','7','nice','-n','15','/usr/bin/ucode',
            '/usr/libexec/opl-netfleet/main.uc','plugin-read',path],null,()=>{fs.unlink(path);worker=null;});
        if (!worker) fs.unlink(path);
    }
    function published() {
        try {
            const parent=fs.lstat(fs.dirname(evidence));
            if (parent?.type!='directory'||parent.uid!=0||parent.mode&0022||fs.lstat(evidence)?.size>65536) return unavailable;
            const value=io.read(evidence), now=io.now(), age=now-value.sampled_monotonic;
            if (value.schema!==1||value.source_ready!==true||!(age>=0&&age<120)||type(value.devices)!='array'||length(value.devices)>256) return unavailable;
            const devices=[];
            for (let row in value.devices) {
                const addresses=[],remaining=[];
                if (type(row.address_expires)!='object') return unavailable;
                for (let address,expiry in row.address_expires) {
                    if (type(expiry)!='int'&&type(expiry)!='double'||!(expiry<=value.sampled_monotonic+120)) return unavailable;
                    if (expiry<=now) continue;
                    const bytes=iptoarr(address);
                    if(!bytes||!length(filter(bytes,x=>x!=0))||index(address,'%')>=0) return unavailable;
                    if(length(bytes)==4 ? bytes[0]==127||bytes[0]>=224&&bytes[0]<=239||bytes[0]==169&&bytes[1]==254 :
                        bytes[0]==255||bytes[0]==254&&(bytes[1]&192)==128||!length(filter(slice(bytes,0,15),x=>x!=0))&&bytes[15]==1) return unavailable;
                    push(addresses,arrtoip(bytes));push(remaining,expiry-now);
                }
                push(devices,{mac:row.mac,addresses:sort(addresses),expires_in:length(remaining)?min(...remaining):0});
            }
            return {source_ready:true,binding:value.binding,devices};
        } catch (_) { return unavailable; }
    }
    function resolve(config, scheduling) {
        if (!length(filter(config.devices,device=>device.identity!=null))) return {};
        if (scheduling) schedule();
        return published();
    }
    function addresses(device,source) {
        if (!device.identity) return device.addresses;
        if (!source.source_ready||source.binding!=device.identity.binding) return [];
        const rows=filter(source.devices ?? [],row=>row.mac==device.identity.mac);
        return length(rows)==1&&rows[0].expires_in>0?rows[0].addresses:[];
    }
    function trust_matches(device,trust) {
        return device.identity ? io.canonical(device.identity)==io.canonical(trust.identity) :
            !trust.identity&&io.canonical(device.addresses)==io.canonical(trust.addresses);
    }
    return {resolve,addresses,trust_matches};
};
