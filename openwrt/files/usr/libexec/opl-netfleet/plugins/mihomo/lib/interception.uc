import * as fs from 'fs';
import {sha256} from 'digest';

return function(context) {
    const gateway=context.use('mihomo.gateway'), files=context.use('platform.files');
    const quote=context.use('platform.process').shell_quote;
    const policy=loadfile(`${context.root}/plugins/${context.id}/lib/interception-policy.uc`)()();
    const TABLE='netfleet_compat', PORT=18443, CLAIM='/var/run/opl-netfleet-core/interception.json';
    const paths=['/etc/opl-netfleet/native/run/config.yaml','/etc/config/netfleet','/var/run/opl-netfleet-core/ownership.json',
        '/etc/opl-netfleet/backend.json','/proc/sys/net/ipv4/ip_local_port_range'];
    function run(args,input) {
        let directory=null, path=null;
        if (input!=null) {
            directory=fs.mkdtemp('/tmp/netfleet-interception.XXXXXX');
            if (!directory) die('lease_request_unavailable');
            path=`${directory}/input`;
            if (!files.write_private(path,input)) {fs.unlink(path);fs.rmdir(directory);die('lease_request_unavailable');}
        }
        const process=fs.popen(`timeout -k 1 1 ${join(' ',map(args,quote))}${path?' < '+quote(path):''} 2>/dev/null`);
        let output=null,status=1;
        if (process) {output=process.read(2097153);status=process.close();}
        if (path) {fs.unlink(path);fs.rmdir(directory);}
        if (status || output==null || length(output)>2097152) die('gateway_command_failed');
        return output;
    }
    function table() {
        const tables=json(run(['nft','-j','list','tables']));
        if (!length(filter(tables.nftables ?? [],row=>row.table?.family=='inet'&&row.table?.name==TABLE))) return null;
        return json(run(['nft','-j','list','table','inet',TABLE]));
    }
    function bypass() {
        if (table()) run(['nft','-f','-'],`flush set inet ${TABLE} targets4\nflush set inet ${TABLE} targets6\n`);
    }
    function status() {
        const current=table(); let leases=0;
        for (let row in current?.nftables ?? []) for (let item in row.set?.elem ?? []) if (item.elem?.expires>0) leases++;
        return {intercepting:leases>0,leases};
    }
    function prepare(network,uid,owner,excluded) {
        const interfaces=network.interfaces,dscp=network.dscp_bypass ?? [];
        if (type(interfaces)!='array' || !length(interfaces) || length(interfaces)>16 || length(filter(interfaces,x=>type(x)!='string'||!match(x,/^[A-Za-z0-9_.:-]{1,15}$/)))) die('lan_interfaces_required');
        if (type(dscp)!='array' || length(filter(dscp,x=>type(x)!='int'||x<0||x>63))) die('invalid_dscp_bypass');
        if (length(filter(excluded,x=>type(x)!='int'||x<1||x>65535))) die('invalid_source_port_exclusions');
        const signature=sha256(sprintf('%J',[7,interfaces,dscp,uid,owner,excluded])), current=table();
        if (length(filter(current?.nftables ?? [],row=>row.table?.comment==signature))) return;
        const names=join(', ',map(interfaces,x=>sprintf('%J',x)));
        let exclusions=length(dscp)?`ip dscp { ${join(', ',dscp)} } return\n  ip6 dscp { ${join(', ',dscp)} } return`:'';
        if (length(excluded)) exclusions+=`\n  tcp sport { ${join(', ',excluded)} } return`;
        run(['nft','-f','-'],(current?`delete table inet ${TABLE}\n`:'')+`table inet ${TABLE} {
 comment "${signature}"
 set targets4 { type ipv4_addr . ipv4_addr . inet_service; flags interval,timeout; timeout 10s; }
 set targets6 { type ipv6_addr . ipv6_addr . inet_service; flags interval,timeout; timeout 10s; }
 chain assign {
  type filter hook prerouting priority -153; policy accept;
  ${exclusions}
  ct status confirmed return
  iifname { ${names} } ct state new tcp flags & (syn | ack) == syn ip saddr . ip daddr . tcp dport @targets4 ct mark set ct mark | 0x01000000
  iifname { ${names} } ct state new tcp flags & (syn | ack) == syn ip6 saddr . ip6 daddr . tcp dport @targets6 ct mark set ct mark | 0x01000000
 }
 chain intercept {
  type nat hook prerouting priority -101; policy accept;
  ct direction original ct mark & 0x01000000 != 0 meta l4proto tcp redirect to :${PORT}
 }
 chain private_listener {
  type filter hook input priority -1; policy accept;
  tcp dport ${PORT} ct status dnat accept
  tcp dport ${PORT} reject with tcp reset
 }
 chain local_probe {
  type nat hook output priority -101; policy accept;
  meta skuid ${uid} meta priority 6 ip saddr 127.0.0.1 ip daddr 127.0.0.1 tcp dport 18445 redirect to :${PORT}
  meta skuid ${uid} meta priority 6 ip6 saddr ::1 ip6 daddr ::1 tcp dport 18445 redirect to :${PORT}
 }
}\n`);
    }
    function source(value) {
        if (type(value)!='string' || index(value,'%')>=0) die('invalid_lease_candidate');
        const bytes=iptoarr(value);
        if (!bytes || !length(filter(bytes,x=>x!=0))) die('invalid_lease_candidate');
        if (length(bytes)==4 ? bytes[0]==127 || bytes[0]>=224 && bytes[0]<=239 || bytes[0]==169 && bytes[1]==254 :
            bytes[0]==255 || bytes[0]==254 && (bytes[1]&192)==128 || !length(filter(slice(bytes,0,15),x=>x!=0)) && bytes[15]==1) die('invalid_lease_candidate');
        return bytes;
    }
    function destination(value,size) {
        if (type(value)!='string' || index(value,'%')>=0) die('invalid_lease_candidate');
        const parts=split(value,'/'),bytes=iptoarr(parts[0]),bits=size*8;
        if (!bytes || length(bytes)!=size || length(parts)>2 || length(parts)==2 && !match(parts[1],/^[0-9]{1,3}$/)) die('invalid_lease_candidate');
        const prefix=length(parts)==2?+parts[1]:bits;
        if (prefix<0 || prefix>bits) die('invalid_lease_candidate');
        for (let bit=prefix;bit<bits;bit++) if (bytes[int(bit/8)] & (1 << (7-bit%8))) die('invalid_lease_candidate');
        return `${arrtoip(bytes)}/${prefix}`;
    }
    function renew(candidates) {
        if (type(candidates)!='array'||length(candidates)>4096) die('lease_candidate_limit');
        const groups={'4':[],'6':[]};
        for (let row in candidates) {
            if (type(row)!='array'||length(row)!=3||type(row[2])!='int'||row[2]<1||row[2]>65535) die('invalid_lease_candidate');
            const bytes=source(row[0]),dst=destination(row[1],length(bytes));
            push(groups[length(bytes)==4?'4':'6'],`${arrtoip(bytes)} . ${dst} . ${row[2]} timeout 10s`);
        }
        let batch='';
        for (let family in ['4','6']) {
            batch+=`flush set inet ${TABLE} targets${family}\n`;
            if (length(groups[family])) batch+=`add element inet ${TABLE} targets${family} { ${join(', ',sort(uniq(groups[family])))} }\n`;
        }
        run(['nft','-f','-'],batch);
    }
    function network_lock_held() {
        const target=fs.stat('/var/lock/opl-netfleet-deploy.lock');
        if (!target) return false;
        let parent=+fs.readlink('/proc/self'); const visited={};
        for (let i=0;i<64 && parent && !visited[parent];i++) {
            visited[parent]=true; const process=`/proc/${parent}`;
            if (fs.stat(process)?.uid!=0) return false;
            for (let name in fs.lsdir(`${process}/fdinfo`) ?? []) {
                const fd=fs.stat(`${process}/fd/${name}`);
                if (fd?.inode==target.inode && fd.dev.major==target.dev.major && fd.dev.minor==target.dev.minor &&
                    match(fs.readfile(`${process}/fdinfo/${name}`) ?? '',/lock:.*FLOCK\s+ADVISORY\s+WRITE\s/)) return true;
            }
            parent=+(match(fs.readfile(`${process}/status`) ?? '',/\nPPid:\s*(\d+)/)?.[1] ?? 0);
        }
        return false;
    }
    function descriptor(value) {
        if (type(value)!='object'||sprintf('%J',sort(keys(value)))!=sprintf('%J',['instance','owner','service','user']) ||
            length(filter(values(value),x=>type(x)!='string'||!match(x,/^[a-z][a-z0-9-]{0,47}$/)))) die('lease_owner_invalid');
    }
    function listener_owned(pid,uid) {
        if (type(pid)!='int'||pid<1) return false;
        const process=`/proc/${pid}`, credentials=match(fs.readfile(`${process}/status`) ?? '',/\nUid:\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)/);
        if (!credentials || length(filter(slice(credentials,1),x=>+x!=uid))) return false;
        const sockets=map(fs.lsdir(`${process}/fd`) ?? [],fd=>fs.readlink(`${process}/fd/${fd}`)); let found=false;
        for (let family in ['tcp','tcp6']) for (let row in slice(split(fs.readfile(`${process}/net/${family}`) ?? '', '\n'),1)) {
            const fields=split(trim(row),/\s+/);
            if (length(fields)<10 || fields[3]!='0A' || int(split(fields[1],':')[1],16)!=PORT) continue;
            if (index(sockets,`socket:[${fields[9]}]`)<0 || +fields[7]!=uid) return false;
            found=true;
        }
        return found;
    }
    function epoch(network) {
        let data=''; for (let path in paths) data+=(fs.readfile(path) ?? '')+'\u0000';
        for (let key in ['core_pid','engine_pid']) {
            const pid=network[key], stat=fs.readfile(`/proc/${pid}/stat`), fields=stat?split(trim(substr(stat,rindex(stat,') ')+2)),/\s+/):[];
            data+=(fields[19] ?? '')+(pid==null?'None':`${pid}`)+'\u0000';
        }
        return sha256(data);
    }
    function egress(profile) {
        const ports=map(split(trim(fs.readfile(paths[4]) ?? ''),/\s+/),x=>+x), result=policy.egress_policy(profile,ports);
        if (result.port_range) {
            try { run(['/usr/libexec/opl-netfleet-compat/port-range',...result.port_range]); }
            catch (_) { die('egress_port_range_unsupported'); }
        }
        return result;
    }
    function read_profile() { try { return json(fs.readfile(paths[0]) ?? '{}'); } catch (_) { die('routing_rule_unreadable'); } }
    function dispatch(owner,input) {
        descriptor(owner);
        if (type(input)!='object'||length(filter(keys(input),key=>index(['action','epoch','candidates'],key)<0))) die('lease_request_invalid');
        const action=input.action;
        if (action=='status') return status();
        const network=index(['snapshot','prepare','renew'],action)>=0?(gateway.interception_snapshot(owner)?.result ?? {}):{};
        if (action=='snapshot') {
            const profile=read_profile(); let reason=policy.admission(profile,network),egress_policy=null;
            if (!reason) { try { egress_policy=egress(profile); } catch (error) {reason=error.message;} }
            return {...network,epoch:epoch(network),reason,egress:egress_policy};
        }
        if (index(['prepare','renew','bypass','remove'],action)<0) die('lease_action_invalid');
        if (!network_lock_held()) die('lease_network_lock_required');
        const claimed=fs.stat(CLAIM)?json(fs.readfile(CLAIM)):null;
        if (claimed && (type(claimed)!='object' || length(keys(claimed))!=length(keys(owner)) || length(filter(keys(owner),key=>owner[key]!=claimed[key])))) die('lease_owner_conflict');
        if (action=='bypass'||action=='remove') {
            if (action=='bypass') bypass();
            else { if (table()) run(['nft','delete','table','inet',TABLE]); fs.unlink(CLAIM); }
            return status();
        }
        const profile=read_profile(),reason=policy.admission(profile,network);
        if (reason) { bypass(); die(reason); }
        if (input.epoch!=epoch(network)) { bypass(); die('lease_gateway_changed'); }
        const account=filter(split(fs.readfile('/etc/passwd') ?? '', '\n'),line=>split(line,':')[0]==owner.user)[0];
        const uid=account?+split(account,':')[2]:null;
        if (uid==null||uid==0) die('lease_unprivileged_listener_required');
        if (!listener_owned(network.engine_pid,uid)) {bypass();die('lease_listener_unconfirmed');}
        if (!claimed && !files.atomic_json(CLAIM,owner)) die('lease_owner_unavailable');
        try {
            const routing=egress(profile); prepare(network,uid,owner,routing.excluded_ports);
            if (action=='renew') renew(input.candidates);
        } catch (error) {
            try { bypass(); } catch (_) {}
            die(error.message);
        }
        return status();
    }
    function request(owner,input) {
        try { return {ok:true,result:dispatch(owner,input)}; }
        catch (error) { return {ok:false,error:match(error.message ?? '',/^[a-z_]+$/)?error.message:'lease_operation_failed'}; }
    }
    return {request};
};
