import * as fs from 'fs';
import * as socket from 'socket';
return function(io, policy, paths) {
    const RUN=paths.run, CA=paths.ca, BINARY=io.root+'/haproxy';
    function openssl(args) { return io.command(['openssl',...args],15); }
    function fingerprint() {
        try { return io.sha256(openssl(['x509','-in',CA+'/mitmproxy-ca-cert.pem','-outform','DER'])); }
        catch (_) { return null; }
    }
    function prepare_ca() {
        io.mkdir(CA);
        const private=CA+'/mitmproxy-ca.pem',public=CA+'/mitmproxy-ca-cert.pem';
        if (!!fs.lstat(private)!=!!fs.lstat(public)) die('ca_private_key_missing');
        function temporary(work) {
            const dir=fs.mkdtemp(CA+'/generate.XXXXXX');
            if (!dir) die('ca_storage_unavailable');
            let failure;
            try { work(dir); } catch(error) {failure=error;}
            for(let name in fs.lsdir(dir) ?? []) fs.unlink(dir+'/'+name);
            fs.rmdir(dir); if(failure) die(failure.message);
        }
        if (!fs.lstat(private)) temporary(dir=>{
            openssl(['req','-x509','-newkey','rsa:2048','-noenc','-sha256','-days','3650',
                '-subj','/CN=NetFleet Compatibility CA','-addext','basicConstraints=critical,CA:TRUE',
                '-addext','keyUsage=critical,keyCertSign,cRLSign','-keyout',dir+'/key','-out',dir+'/cert']);
            io.write(private,fs.readfile(dir+'/cert')+fs.readfile(dir+'/key'),true);
            io.write(public,fs.readfile(dir+'/cert'),true);
        });
        if(openssl(['x509','-in',private,'-outform','DER'])!=openssl(['x509','-in',public,'-outform','DER'])) die('ca_certificate_mismatch');
        if(openssl(['x509','-in',public,'-pubkey','-noout'])!=openssl(['pkey','-in',private,'-pubout'])) die('ca_key_mismatch');
        openssl(['x509','-in',public,'-checkend','86400','-noout']);
        const leaf=CA+'/probe-cert.pem';let renew=!fs.lstat(leaf);
        if(!renew) try { io.command(['openssl','x509','-in',leaf,'-checkend','604800','-noout']); } catch (_) {renew=true;}
        if(renew) temporary(dir=>{
            io.write(dir+'/extensions','subjectAltName=DNS:localhost\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n');
            openssl(['req','-new','-newkey','rsa:2048','-noenc','-subj','/CN=localhost','-keyout',dir+'/key','-out',dir+'/csr']);
            const serial=trim(openssl(['rand','-hex','16']));
            openssl(['x509','-req','-in',dir+'/csr','-CA',public,'-CAkey',private,'-set_serial','0x'+serial,
                '-days','90','-sha256','-extfile',dir+'/extensions','-out',dir+'/cert']);
            io.write(leaf,fs.readfile(dir+'/cert'),true);io.write(CA+'/probe-key.pem',fs.readfile(dir+'/key'),true);
        });
        io.write(CA+'/server.pem',fs.readfile(leaf)+fs.readfile(CA+'/probe-key.pem'),true);
        const system_ca=fs.readfile('/etc/ssl/certs/ca-certificates.crt');
        if(!system_ca) die('upstream_ca_unavailable');
        io.write(CA+'/upstream-trust.pem',system_ca,true);
    }
    function revision(effective) {
        const structural={...effective};delete structural.blocked_rules;
        structural.devices=map(structural.devices,device=>device.identity?{...device,addresses:[]}:device);
        return io.sha256(io.canonical(structural));
    }
    function configuration(effective,run,rev,port,probe_port) {
        port??=18443;probe_port??=18445;
        const config=policy.validate({...effective,rules:filter(effective.rules,rule=>length(rule.devices))});
        if(!match(rev,/^[0-9a-f]{64}$/)||match(run,/[[:space:]#\\"']/)) die('engine_configuration_invalid');
        const ca=run+'/ca',sockets=run+'/engine',source={'4':'','6':''},ports=effective.egress?.port_range;
        if(ports!=null) {
            if(type(ports)!='array'||length(ports)!=2||length(filter(ports,x=>type(x)!='int'))||ports[0]<1024||ports[0]>ports[1]||ports[1]>65535) die('egress_port_range_invalid');
            source['4']=` source 0.0.0.0:${ports[0]}-${ports[1]}`;source['6']=` source [::]:${ports[0]}-${ports[1]}`;
        }
        const lines=[`global
  nbthread 1
  maxconn 96
  description ${rev}
  tune.ssl.cachesize 128
  tune.ssl.ssl-ctx-cache-size 128
  tune.ssl.default-dh-param 2048
  stats socket ${sockets}/engine.sock mode 600 level admin
defaults
  mode tcp
  timeout connect 10s
  timeout client 300s
  timeout server 300s
  timeout tunnel 1h
  timeout http-request 60s
  timeout http-keep-alive 30s
  retries 0
frontend ingress
  bind 0.0.0.0:${port}
  bind :::${port} v6only
  bind ${sockets}/probe.sock accept-proxy mode 600
  tcp-request inspect-delay 2s
  tcp-request content accept if { req.ssl_hello_type 1 }
  use_backend loopback_convert if { src 127.0.0.1 ::1 } { dst 127.0.0.1 ::1 } { dst_port ${probe_port} } { req.ssl_sni -i localhost } !{ req.ssl_alpn -m str h2 }`];
        const rules=sort(filter(config.rules,rule=>rule.enabled),(a,b)=>(b.match=='exact')-(a.match=='exact')||length(b.domain)-length(a.domain));
        const mapping={};
        for(let n=0;n<length(rules);n++) {
            const rule=rules[n],name=`r${n}`;mapping[name]=rule.id;
            push(lines,`  acl ${name}_source src -f ${run}/sources-${name}.acl`,`  acl ${name}_domain req.ssl_sni -i ${rule.domain}`);
            if(rule.match=='suffix') push(lines,`  acl ${name}_domain req.ssl_sni -m end -i .${rule.domain}`);
            const condition=`${name}_source ${name}_domain { dst_port ${rule.port} } !{ req.ssl_alpn -m str h2 }`;
            if(config.enabled&&rule.strategy=='h2') push(lines,`  use_backend ${name}_convert if ${condition} { str(${name}),map_str_int(${run}/rules.map,0) eq 1 }`);
            push(lines,`  use_backend passthrough if ${condition}`);
        }
        push(lines,`  default_backend passthrough
backend passthrough
  use-server v4 if { dst -m ip 0.0.0.0/0 }
  use-server v6 if { dst -m ip ::/0 }
  server v4 0.0.0.0:0${source['4']}
  server v6 [::]:0${source['6']}
backend loopback_convert
  server local ${sockets}/health.sock send-proxy-v2
frontend health_convert
  mode http
  option http-no-delay
  bind ${sockets}/health.sock accept-proxy mode 600 ssl crt ${ca}/server.pem alpn http/1.1
  default_backend health_origin
backend health_origin
  mode http
  option abortonclose
  option http-no-delay
  server local 127.0.0.1:${probe_port} ssl alpn h2 proto h2 verify required ca-file ${ca}/mitmproxy-ca-cert.pem sni str(localhost)
frontend health_endpoint
  mode http
  bind 127.0.0.1:${probe_port} ssl crt ${ca}/server.pem alpn h2
  bind [::1]:${probe_port} v6only ssl crt ${ca}/server.pem alpn h2
  http-request return status 200 hdr X-Upstream-Protocol %[ssl_fc_alpn] content-type text/plain lf-string %[path]`);
        for(let n=0;n<length(rules);n++) {
            const rule=rules[n],name=`r${n}`;
            if(rule.strategy!='h2') continue;
            push(lines,`backend ${name}_convert`);
            if(rule.match=='suffix') push(lines,`  tcp-request content set-var(proc.${name}_sni) req.ssl_sni,lower`);
            push(lines,`  server local ${sockets}/${name}.sock send-proxy-v2
frontend ${name}_http
  mode http
  option http-no-delay
  bind ${sockets}/${name}.sock accept-proxy mode 600 ssl crt ${ca}/server.pem ca-sign-file ${ca}/mitmproxy-ca.pem generate-certificates alpn http/1.1
  use_backend ${name}_websocket if { hdr(Upgrade) -i websocket }
  default_backend ${name}_h2`);
            for(let suffix in ['h2','websocket']) {
                const protocol=suffix=='h2'?'h2':'http/1.1';
                push(lines,`backend ${name}_${suffix}
  mode http
  option abortonclose
  option http-no-delay
  http-reuse safe
  use-server v4 if { dst -m ip 0.0.0.0/0 }
  use-server v6 if { dst -m ip ::/0 }`);
                for(let family in ['4','6']) push(lines,`  server v${family} ${family=='4'?'0.0.0.0':'[::]'}:0 ssl alpn ${protocol} proto ${suffix=='h2'?'h2':'h1'} verify required ca-file ${ca}/upstream-trust.pem sni ssl_fc_sni${source[family]}`);
            }
        }
        return {text:join('\n',lines)+'\n',mapping};
    }
    function command(request) {
        const conn=socket.connect({path:RUN+'/engine/engine.sock'},null,null,400);
        if(!conn) die('health_socket_unavailable');
        const deadline=io.now()+0.4;
        let output='',remaining=request+'\n',failure;
        try {
            while(length(remaining)) {
                if(io.now()>=deadline||!length(socket.poll(int((deadline-io.now())*1000),[conn,socket.POLLOUT]) ?? [])) die('health_socket_timeout');
                const count=conn.send(remaining,socket.MSG_DONTWAIT|socket.MSG_NOSIGNAL);
                if(count==null||count<1) die('health_socket_unavailable');
                remaining=substr(remaining,count);
            }
            while(true) {
                if(io.now()>=deadline||!length(socket.poll(int((deadline-io.now())*1000),[conn,socket.POLLIN]) ?? [])) die('health_socket_timeout');
                const part=conn.recv(65536,socket.MSG_DONTWAIT);
                if(part==null) die('health_socket_unavailable');
                if(!length(part)) break;
                output+=part;if(length(output)>262144) die('health_response_invalid');
            }
        } catch(error) {failure=error;}
        conn.close();if(failure) die(failure.message);return output;
    }
    function switches(effective,mapping) {
        const result={};for(let name,id in mapping) result[name]=index(effective.blocked_rules ?? [],id)>=0?'0':'1';return result;
    }
    function sources(effective,mapping) {
        const result={};
        for(let name,id in mapping) {
            const rule=filter(effective.rules,row=>row.id==id)[0],addresses=[];
            for(let device in effective.devices) if(index(rule.devices,device.id)>=0)
                push(addresses,...map(device.addresses,address=>address+(index(address,':')>=0?'/128':'/32')));
            result[name]=sort(uniq(addresses));
        }
        return result;
    }
    function write_source(path,addresses) {
        const previous=fs.stat(path),temporary=path+'.next';
        io.write(temporary,join('\n',addresses)+'\n');
        if(previous&&(!fs.chown(temporary,0,previous.gid)||!fs.chmod(temporary,previous.mode&0777))) die('engine_source_acl_update_failed');
        if(!fs.rename(temporary,path)) die('engine_source_acl_update_failed');
    }
    function prepare(effective) {
        const result=configuration(effective,RUN,revision(effective));
        const values=switches(effective,result.mapping);
        for(let name,addresses in sources(effective,result.mapping)) write_source(`${RUN}/sources-${name}.acl`,addresses);
        io.write(RUN+'/rules.map',join('',map(keys(values),name=>`${name} ${values[name]}\n`)));
        io.write(RUN+'/haproxy.cfg.pending',result.text);
        io.command([BINARY,'-c','-f',RUN+'/haproxy.cfg.pending'],5);
        if(!fs.rename(RUN+'/haproxy.cfg.pending',RUN+'/haproxy.cfg')) die('engine_configuration_failed');
        io.atomic(RUN+'/haproxy-rules.json',result.mapping);
    }
    let synchronized=null;
    function sync_rule_switches(effective,health) {
        const mapping=io.read(RUN+'/haproxy-rules.json',{}),expected=switches(effective,mapping),addresses=sources(effective,mapping);
        const identity=io.canonical([health.pid,health.revision,expected,addresses]);
        if(identity==synchronized) return;
        synchronized=null;
        function current() {
            const result={};for(let line in split(command(`show map ${RUN}/rules.map`),'\n')) {
                const fields=split(trim(line),/\s+/);if(length(fields)==3&&index(fields[0],'0x')==0) result[fields[1]]=fields[2];
            }return result;
        }
        const before=current();
        if(io.canonical(sort(keys(before)))!=io.canonical(sort(keys(expected)))) die('engine_rule_map_mismatch');
        const updates=map(filter(keys(expected),name=>expected[name]!=before[name]),name=>`set map ${RUN}/rules.map ${name} ${expected[name]}`);
        if(length(updates)&&length(trim(command(join(';',updates))))) die('engine_rule_map_update_failed');
        if(io.canonical(current())!=io.canonical(expected)) die('engine_rule_map_mismatch');
        for(let name,wanted in addresses) {
            const path=`${RUN}/sources-${name}.acl`;
            function observed() {
                const result=[];
                for(let line in split(command(`show acl ${path}`),'\n')) {
                    const parts=split(trim(line),/\s+/);
                    if(length(parts)==2&&index(parts[0],'0x')==0) {
                        const raw=split(parts[1],'/'),bytes=iptoarr(raw[0]);
                        if(!bytes||(length(raw)>1&&+raw[1]!=(length(bytes)==4?32:128))) die('engine_source_acl_mismatch');
                        push(result,arrtoip(bytes)+(length(bytes)==4?'/32':'/128'));
                    }
                }
                return sort(result);
            }
            const before=observed(),changes=[];
            for(let address in before) if(index(wanted,address)<0) push(changes,`del acl ${path} ${address}`);
            for(let address in wanted) if(index(before,address)<0) push(changes,`add acl ${path} ${address}`);
            if(length(changes)&&length(trim(command(join(';',changes))))) die('engine_source_acl_update_failed');
            if(io.canonical(observed())!=io.canonical(wanted)) die('engine_source_acl_mismatch');
            if(length(changes)) write_source(path,wanted);
        }
        synchronized=identity;
    }
    function health() {
        const info={},lines=split(command('show stat'),'\n');
        for(let line in split(command('show info'),'\n')) {const n=index(line,': ');if(n>=0) info[substr(line,0,n)]=substr(line,n+2);}
        const headers=split(replace(shift(lines),/^# /,''),','),rows=[];
        for(let line in lines) if(length(line)) {const parts=split(line,','),row={};for(let n=0;n<length(headers);n++) row[headers[n]]=parts[n];push(rows,row);}
        const ingress=filter(rows,row=>row.pxname=='ingress'&&row.svname=='FRONTEND')[0],probes=filter(rows,row=>row.pxname=='loopback_convert'&&row.svname=='BACKEND')[0];
        if(!ingress||!probes||!match(info.description ?? '',/^[0-9a-f]{64}$/)||!(+info.Pid>0)) die('health_response_invalid');
        const connections=max(0,+ingress.scur-(+probes.scur)),mapping=io.read(RUN+'/haproxy-rules.json',{}),rules={},events=[],observed={};
        if(length(mapping)) for(let line in split(command(join(';',map(keys(mapping),name=>`get var proc.${name}_sni`))),'\n')) {
            const value=match(line,/^proc\.(r[0-9]+)_sni: type=str value=<([a-z0-9.-]{1,253})>$/);
            if(value&&mapping[value[1]]) observed[mapping[value[1]]]={domain:value[2]};
        }
        for(let row in rows) {
            const name=replace(row.pxname,/_h2$/,'');
            if(row.svname!='BACKEND'||!mapping[name]||!match(row.pxname,/_h2$/)) continue;
            const id=mapping[name],errors=+(row.econ||0)+(+row.eresp||0);
            rules[id]={requests:+(row.req_tot||0),active_requests:+row.scur,upstream_protocol:(+row.hrsp_2xx||0)+(+row.hrsp_3xx||0)+(+row.hrsp_4xx||0)>0?'h2':null};
            if(errors) push(events,{id:errors,rule:id,reason:'upstream_transport_failed'});
        }
        let active_requests=0;for(let rule in values(rules)) active_requests+=rule.active_requests;
        return {ready:true,pid:+info.Pid,revision:info.description,active_connections:connections,active_requests,
            unassigned_connections:connections,rules,failure_events:events,observed,engine:'haproxy',engine_version:info.Version};
    }
    function probe(family,uid) {
        try {return json(io.command([io.root+'/tls-probe','local',RUN,family ?? 0,uid],2,null,true));}
        catch (_) {return {ok:false,reason:'local_conversion_failed'};}
    }
    return {fingerprint,prepare_ca,revision,configuration,prepare,sync_rule_switches,health,probe};
};
