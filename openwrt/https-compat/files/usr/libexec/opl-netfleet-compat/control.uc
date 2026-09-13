import * as fs from 'fs';
import * as uloop from 'uloop';

// Loaded through https-compat.control; the existing gateway remains the network owner.
return function(context, options) {
    const root=options?.root ?? '/usr/libexec/opl-netfleet-compat';
    const BASE=options?.base ?? '/etc/opl-netfleet/compatibility',RUN=options?.run ?? '/var/run/opl-netfleet-compat';
    const CONFIG=BASE+'/config.json',TRUST=BASE+'/trust.json',STATE=RUN+'/state.json',EFFECTIVE=RUN+'/effective.json',CA=BASE+'/ca';
    const SERVICE='/etc/init.d/opl-netfleet-compat',DEFAULT={schema:1,enabled:false,devices:[],rules:[]};
    const io=loadfile(root+'/io.uc')()({root,process:context.use('platform.process')});
    const policy=loadfile(root+'/policy.uc')()();
    const engine=loadfile(root+'/haproxy.uc')()(io,policy,{run:RUN,ca:CA});
    const identity=loadfile(root+'/identity.uc')()(io);
    const isolation=loadfile(root+'/isolation.uc')()(io,BASE,RUN);
    const probes=loadfile(root+'/probes.uc')()(io,RUN);
    const advance=loadfile(root+'/recovery.uc')();
    const gateway=context.use('mihomo.interception');
    const owner={owner:'https-compat',service:'opl-netfleet-compat',instance:'engine',user:'netfleet-compat'};
    let epoch=null,renewal=null,preview=null,verified=null,certificate=null,ca_cache=null,cleared=false;
    let state_cache=null;
    function read_state() {
        return io.measure('state_read',()=>{
            const raw=io.source(STATE);
            if(raw==null) {state_cache=null;return {};}
            if(!state_cache||state_cache.raw!=raw) {
                let value;try {value=json(raw);}catch(_){die('compatibility_state_invalid');}
                const events=value.events ?? [];delete value.events;
                state_cache={raw,body:sprintf('%J',value),events,encoded:sprintf('%J',events)};
            }
            // History is immutable inside the controller. Mutable recovery fields
            // receive a fresh copy so a failed tick cannot change saved state.
            return {...json(state_cache.body),events:state_cache.events};
        });
    }
    function write_state(value) {
        return io.measure('state_publish',()=>{
            const body={...value},events=body.events ?? [];delete body.events;
            const unchanged=state_cache&&length(events)==length(state_cache.events)&&
                !length(filter(events,(event,i)=>event!==state_cache.events[i]));
            const encoded=unchanged?state_cache.encoded:sprintf('%J',events),summary=sprintf('%J',body);
            const raw=substr(summary,0,length(summary)-1)+(length(keys(body))?',':'')+'"events":'+encoded+'}\n';
            io.write(STATE,raw);
            state_cache={raw,body:summary,events,encoded};
        });
    }
    function call(action,params) {
        if(action=='prepare'||action=='renew') cleared=false;
        const response=io.measure('gateway_'+action,()=>gateway.request(owner,{action,...(params ?? {})}));
        if(response?.ok!==true) {preview=null;renewal=null;epoch=null;die(response?.error ?? 'lease_operation_failed');}
        return response.result;
    }
    function bypass() {
        // Clearing target leases retains the prepared probe chains. A later
        // renew still checks the current gateway epoch before admitting traffic.
        renewal=null;io.renewed(false);
        if(cleared) return {intercepting:false,leases:0};
        const value=call('bypass');cleared=value.intercepting===false&&value.leases===0;return value;
    }
    function revision() {
        const config=fs.readfile(CONFIG);return config==null?null:io.sha256(config+'\u0000'+(fs.readfile(TRUST) ?? ''));
    }
    function fingerprint() {
        const raw=fs.readfile(CA+'/mitmproxy-ca-cert.pem');
        if(!raw) return null;
        const hash=io.sha256(raw);
        if(ca_cache?.hash!=hash) ca_cache={hash,value:engine.fingerprint()};
        return ca_cache.value;
    }
    function service(action,params) {
        const raw=io.command(['ubus','call','service',action,sprintf('%J',{name:'opl-netfleet-compat',...(params ?? {})})],2);
        return length(trim(raw))?json(raw):{};
    }
    function health(probe) {
        const before=probe?isolation.counters():null;
        if(!probe) engine.close_probe();
        try {
            const value=io.measure('engine_status',()=>engine.health()),key=io.canonical([value.pid,value.revision]),now=io.now();
            let proofs=verified?.key==key?{...verified.proofs}:{},full=verified?.key!=key||now-verified.at>=60;
            if(probe) {
                const ids=isolation.account();
                if(full) proofs.processing=io.measure('private_probe',()=>engine.probe(null,ids.uid));
                const pair=io.measure('dual_stack_probe',()=>engine.probe_pair(ids.uid,ids.gid,key));
                proofs.ipv4=pair.ipv4;proofs.ipv6=pair.ipv6;
                if(length(values(proofs))==3&&!length(filter(values(proofs),value=>value.ok!==true)))
                    verified={key,at:full?now:verified.at,proofs};
                else verified=null;
            }
            return {...value,processing_chain:proofs.processing?.ok===true,
                transparent_chain:proofs.ipv4?.ok===true&&proofs.ipv6?.ok===true,local_probes:proofs,
                health_counters:probe?isolation.delta(before):null};
        } catch(error) {
            verified=null;
            let connections=null,pid=null,starting=false;
            try {
                const current=service('list')?.['opl-netfleet-compat']?.instances?.engine;
                if(!current?.running) connections=0;
                else if(type(current.pid)=='int') {
                    pid=current.pid;const stat=fs.readfile(`/proc/${pid}/stat`);
                    const fields=split(trim(substr(stat,rindex(stat,') ')+2)),/\s+/);
                    // Linux exposes process times in USER_HZ (100), independently of scheduler HZ.
                    const age=io.now()-(+fields[19])/100;starting=age>=0&&age<60;
                }
            } catch (_) {}
            return {ready:false,active_requests:null,active_connections:connections,rules:{},pid,starting,
                health_counters:probe?isolation.delta(before):null,
                health_error:match(error.message ?? '',/^[a-z_]+$/)?error.message:'health_chain_unavailable'};
        }
    }
    function verified_trust(config,trust,fp) {
        const result={};
        for(let device in config.devices) if(fp&&trust[device.id]?.ca_sha256==fp&&trust[device.id].verified===true&&identity.trust_matches(device,trust[device.id])) result[device.id]=trust[device.id];
        return result;
    }
    function effective(config,trust,source) {
        const trusted=verified_trust(config,trust,fingerprint()),owners={};
        const resolved=map(config.devices,device=>({...device,addresses:identity.addresses(device,source)}));
        for(let device in resolved) for(let address in device.addresses) {owners[address]??={};owners[address][device.id]=true;}
        for(let device in resolved) device.addresses=sort(uniq(filter(device.addresses,address=>length(owners[address])==1)));
        // Identity evidence controls admission addresses, not engine structure.
        // Retain a trusted binding through an empty/expired sample so its ACL
        // can become empty without restarting other healthy connections.
        const eligible=map(filter(resolved,device=>trusted[device.id]&&(length(device.addresses)||device.identity)),device=>device.id);
        return {...config,devices:filter(resolved,device=>length(device.addresses)||device.identity),
            rules:map(filter(config.rules,rule=>length(filter(rule.devices,id=>index(eligible,id)>=0))),
                rule=>({...rule,devices:filter(rule.devices,id=>index(eligible,id)>=0)}))};
    }
    function status() {
        const config=policy.validate(io.read(CONFIG,DEFAULT)),state=read_state(),live=health(),kernel=call('status');
        const fp=fingerprint(),source=identity.resolve(config),trust=io.read(TRUST,{}),active=effective(config,trust,source);
        let reason=kernel.intercepting?null:state.reason ?? (config.enabled?'not_ready':'disabled');
        if(!kernel.intercepting&&state.intercepting) reason='lease_expired';
        if(!config.enabled) reason=live.active_connections?'draining':'disabled';
        else if(!fp) reason='ca_not_ready';
        const device_addresses={},device_connections={},eligible={};
        for(let device in config.devices) {
            device_addresses[device.id]=filter(active.devices,item=>item.id==device.id)[0]?.addresses ?? [];
            device_connections[device.id]=live.unassigned_connections===0?(live.clients_by_device?.[device.id] ?? 0):live.active_connections===0?0:null;
        }
        for(let rule in active.rules) for(let id in rule.devices) eligible[id]=true;
        return {installed:true,engine:{name:'HAProxy',version:live.engine_version},revision:revision(),config,requested:config.enabled,...kernel,
            isolation:isolation.status(),reason,active_connections:live.active_connections,active_requests:live.active_requests,
            address_source:source,device_addresses,device_connections,eligible_devices:sort(keys(eligible)),rules:live.rules,
            recovery:state.recovery ?? {},ca_sha256:fp,last_failure:state.last_failure,engine_restart:state.engine_restart ?? {},
            rule_recovery:state.rule_recovery ?? {},local_probes:state.local_probes ?? {},trust:verified_trust(config,trust,fp),events:json(sprintf('%J',slice(state.events ?? [],-100)))};
    }
    function save(state,previous) {
        // Eligibility is not evidence that a rule actually owned a kernel lease.
        if(!state.intercepting) {
            const rules={};
            for(let id,current in state.rule_recovery ?? {}) rules[id]={...current,admitted:false};
            state.rule_recovery=rules;
        }
        let events=[...(previous.events ?? [])];
        if(state.reason!=previous.reason||state.intercepting!=previous.intercepting) push(events,{at:time(),reason:state.reason,
            intercepting:state.intercepting ?? false,local_probes:state.local_probes ?? {},failure:state.last_failure,engine_restart:state.engine_restart ?? {}});
        for(let id,current in state.rule_recovery ?? {}) {
            const old=previous.rule_recovery?.[id] ?? {};
            if(current.reason!=old.reason||current.intercepting!=old.intercepting) push(events,{at:time(),rule:id,reason:current.reason,
                intercepting:current.intercepting ?? false,failure:current.last_failure,probe:current.probe});
        }
        write_state({...state,events:slice(events,-100),last_tick:io.now()});
    }
    function unlocked(lock,work) {
        if(!lock) die('compatibility_probe_requires_independent_lock');
        const paths=[CONFIG,TRUST,STATE,EFFECTIVE,CA+'/mitmproxy-ca-cert.pem','/etc/opl-netfleet/native/run/config.yaml',
            '/etc/config/netfleet','/var/run/opl-netfleet-core/ownership.json'];
        const before=map(paths,path=>fs.readfile(path));
        io.lock_stopped();lock.lock('u');let result,failure;
        try {result=work();}catch(error){failure=error;}
        if(!lock.lock('xn')) die('mutation_busy');io.lock_started();
        for(let i=0;i<length(paths);i++) if(fs.readfile(paths[i])!=before[i]) die('compatibility_probe_stale');
        if(failure) die(failure.message);return result;
    }
    function prepare_engine() {
        const config=policy.validate(io.read(CONFIG,DEFAULT));
        if(!config.enabled) return {prepared:false};
        engine.prepare_ca();
        if(!fs.lstat(EFFECTIVE)) io.atomic(EFFECTIVE,effective(config,io.read(TRUST,{}),identity.resolve(config)));
        isolation.prepare();engine.prepare(io.read(EFFECTIVE));isolation.readable();return {prepared:true};
    }
    function reconcile(live,active,expected) {
        const now=io.now();
        const certkey=io.canonical([live.pid,fs.stat(CA+'/probe-cert.pem')?.mtime]);
        if(certificate?.key!=certkey||now-certificate.at>=3600) {
            let renew=false;try {io.command(['openssl','x509','-in',CA+'/probe-cert.pem','-checkend','604800','-noout']);}catch(_){renew=true;}
            certificate={key:certkey,at:now,renew};
        }
        if(live.revision==expected&&!certificate.renew) {engine.sync_rule_switches(active,live);return false;}
        bypass();
        if(live.ready&&live.active_connections===0) {prepare_engine();service('signal',{instance:'engine',signal:15});}
        return true;
    }
    function snapshot() {
        if(preview&&io.now()-preview.at>=0&&io.now()-preview.at<10) return preview.value;
        const value=call('snapshot');preview=value.ready&&!value.reason?{at:io.now(),value}:null;return value;
    }
    function tick(lock,delayed) {
        if(delayed) {preview=null;renewal=null;}
        const config=policy.validate(io.read(CONFIG,DEFAULT)),previous=read_state(),now=io.now();
        if(now-(previous.last_tick ?? now)>10&&!delayed) {
            if(previous.intercepting===true) previous.last_failure={at:time(),reason:'management_lease_expired'};
            previous.recovery=advance(previous.recovery,{requested:config.enabled,healthy:false,reason:'management_lease_expired',now,
                count_failure:previous.intercepting===true});
        }
        if(!config.enabled) {
            bypass();const live=health();save({...previous,intercepting:false,reason:'disabled'},previous);
            if(live.active_connections===0) service('delete');return;
        }
        if(previous.maintenance||previous.recovery?.latched) {
            bypass();save({...previous,intercepting:false,reason:previous.maintenance?'maintenance':'manual_recovery_required'},previous);return;
        }
        const source=io.measure('identity_read',()=>identity.resolve(config,true));let network={},reason,current=io.read(EFFECTIVE,{});
        try {
            network=snapshot();reason=network.reason ?? (network.ready?null:'native_gateway_unavailable');
            if(!reason) {
                if(io.canonical(current.egress)!=io.canonical(network.egress)) {bypass();current={...current,egress:network.egress};io.atomic(EFFECTIVE,current);}
                if(epoch!=network.epoch) {call('prepare',{epoch:network.epoch});epoch=network.epoch;}
            }
        } catch(error) {reason=error.message;}
        // No gateway admission means no transparent loopback path to prove.
        // Keep process/config readback, and resume wire probes before any lease.
        const live=unlocked(lock,()=>health(!reason));
        const expected=fs.lstat(EFFECTIVE)?engine.revision(current):null;
        if(live.ready&&reconcile(live,current,expected)) {save({...previous,intercepting:false,reason:'engine_config_pending'},previous);return;}
        const starting=live.starting&&live.pid!=previous.ready_engine_pid;
        // Gateway admission also disappears during an engine restart. That is
        // a consequence of the crash, not a reason to discard its fault count.
        if(previous.intercepting===true&&previous.ready_engine_pid&&live.pid!=previous.ready_engine_pid)
            reason=live.pid?'engine_restarted':'engine_unavailable';
        const healthy=!reason&&live.ready&&live.processing_chain===true&&live.transparent_chain===true&&live.revision==expected;
        reason??=!live.ready?'engine_unavailable':!live.processing_chain?'processing_chain_failed':!live.transparent_chain?'transparent_chain_failed':'engine_revision_mismatch';
        const own_failure=index(['engine_unavailable','engine_restarted','processing_chain_failed','transparent_chain_failed','engine_revision_mismatch'],reason)>=0;
        if(!healthy) epoch=null;
        const recovery=advance(previous.recovery,{requested:true,healthy,reason,now,count_failure:own_failure&&previous.intercepting===true});
        const state={...previous,recovery,intercepting:false,reason:recovery.reason,local_probes:live.local_probes ?? {},engine_pid:live.pid ?? previous.engine_pid};
        if(!healthy&&previous.intercepting===true&&own_failure) state.last_failure={at:time(),reason,health_error:live.health_error,
            local_probes:live.local_probes ?? {},health_counters:live.health_counters,engine_pid:live.pid,previous_engine_pid:previous.ready_engine_pid};
        if(live.ready&&live.pid) state.ready_engine_pid=live.pid;
        if(!recovery.intercepting) {
            bypass();
            if(!live.ready||!live.processing_chain||!live.transparent_chain) {
                state.unhealthy_since=previous.unhealthy_since ?? now;
                const restart=previous.engine_restart ?? {};
                if(now-state.unhealthy_since>=8&&!starting&&!recovery.latched&&network.ready&&now>=(restart.next_at ?? 0)) {
                    const attempts=min((restart.attempts ?? 0)+1,1000000);
                    state.engine_restart={attempts,next_at:now+min(60,8*(2**min(attempts-1,3)))};
                    state.unhealthy_since=now;save(state,previous);
                    service('signal',{instance:'engine',signal:9});io.command([SERVICE,'start'],3);
                }
            } else delete state.unhealthy_since;
            save(state,previous);return;
        }
        delete state.engine_restart;
        const active=effective(config,io.read(TRUST,{}),source);
        if(network.egress!=null) active.egress=network.egress;
        let rule_states={...(previous.rule_recovery ?? {})};
        if(previous.engine_pid!=live.pid) for(let id in rule_states) rule_states[id]={...rule_states[id],last_error:0};
        const seen={...(previous.observed ?? {}),...(live.observed ?? {})},observed={};
        for(let rule in active.rules) if(rule.match=='suffix'&&type(seen[rule.id]?.domain)=='string'&&
            (seen[rule.id].domain==rule.domain||substr(seen[rule.id].domain,-length(rule.domain)-1)=='.'+rule.domain)) observed[rule.id]={domain:seen[rule.id].domain};
        state.observed=observed;
        for(let rule in active.rules) {
            if(!rule.enabled||rule.strategy!='h2') continue;
            const old=rule_states[rule.id] ?? {},errors=filter(live.failure_events ?? [],event=>event.rule==rule.id&&event.id>(old.last_error ?? 0));
            const new_error=length(errors)>0;
            const result=!old.latched&&old.intercepting!==true&&(rule.match=='exact'||observed[rule.id])?
                probes.request('upstream',{...rule,...(observed[rule.id] ?? {})},network.egress):null;
            const probe=result ?? old.probe ?? {},probe_ok=probe.ok ?? old.probe_ok ?? (rule.match=='suffix');
            const failure=new_error?errors[length(errors)-1]:old.last_failure;
            const why=new_error?(failure.reason ?? 'upstream_transport_failed'):(probe.reason ?? 'upstream_protocol_failed');
            const current=advance(old,{requested:true,healthy:probe_ok&&!new_error,reason:why,now,count_failure:previous.intercepting===true&&old.admitted===true});
            rule_states[rule.id]={...current,probe,last_failure:failure,probe_ok:new_error?false:probe_ok,
                last_error:new_error?max(...map(errors,event=>event.id)):(old.last_error ?? 0)};
            if(!current.intercepting) {active.blocked_rules??=[];push(active.blocked_rules,rule.id);}
        }
        state.rule_recovery=rule_states;
        if(io.canonical(current)!=io.canonical(active)) {
            const same_engine=engine.revision(active)==live.revision;
            if(!same_engine) bypass();
            io.atomic(EFFECTIVE,active);
            if(!same_engine) {state.reason='rules_recovering';save(state,previous);return;}
            engine.sync_rule_switches(active,live);
        }
        const target_rules=filter(active.rules,rule=>rule.enabled&&rule.strategy=='h2'&&index(active.blocked_rules ?? [],rule.id)<0),candidates=[];
        for(let current in values(rule_states)) current.admitted=false;
        for(let rule in target_rules) {
            const before=length(candidates);
            const targets=rule.match=='suffix'?['0.0.0.0/0','::/0']:(probes.request('resolve',rule,network.egress)?.addresses ?? []);
            for(let device in active.devices) if(index(rule.devices,device.id)>=0) for(let address in device.addresses) {
                const family=index(address,':')>=0?6:4;
                if(!network[`ipv${family}_proxy`]) continue;
                for(let destination in targets) if((index(destination,':')>=0)==(family==6)) push(candidates,[address,destination,rule.port]);
            }
            rule_states[rule.id].admitted=length(candidates)>before;
        }
        if(length(candidates)) {
            const key=io.canonical([epoch,candidates]);
            if(!renewal||renewal.key!=key||now-renewal.at<0||now-renewal.at>=4) {
                call('renew',{epoch,candidates});io.renewed();renewal={key,at:now};
                // The gateway just revalidated this exact epoch, including live
                // process/listener/routing admission. Failures clear preview in call().
                if(preview?.value.epoch==epoch) preview.at=io.now();
            }
        } else {bypass();state.reason=!length(target_rules)&&length(active.rules)?'rules_bypassed':'no_verified_targets';}
        state.intercepting=length(candidates)>0;save(state,previous);
    }
    function apply(action,request) {
        if(request.revision!=revision()) die('compatibility_revision_conflict');
        const original=policy.validate(io.read(CONFIG,DEFAULT)),trust=io.read(TRUST,{});
        const config=action=='apply'?policy.validate(request.config):{...original,enabled:action=='enable'};
        const source=identity.resolve(config);
        if(action=='apply') {
            const verified=verified_trust(original,trust,fingerprint());
            for(let device in config.devices) {
                const old=filter(original.devices,item=>item.id==device.id)[0];
                if(old&&!old.identity&&device.identity&&verified[device.id]) {
                    if(!length(filter(old.addresses,address=>index(identity.addresses(device,source),address)>=0))) die('device_identity_not_confirmed');
                    trust[device.id]={...trust[device.id],identity:device.identity};
                }
            }
        }
        bypass();if(action!='disable'&&(config.enabled||length(config.devices))) engine.prepare_ca();
        for(let id in keys(trust)) if(!length(filter(config.devices,device=>device.id==id))) delete trust[id];
        io.atomic(CONFIG,config);io.atomic(TRUST,trust);io.atomic(EFFECTIVE,effective(config,trust,source));
        const previous=read_state(),kept=original.enabled&&config.enabled&&action=='apply'?previous:{};
        save({...kept,intercepting:false,reason:config.enabled?'recovering':'disabled'},previous);
        io.command([SERVICE,config.enabled?'enable':'disable'],2);
        if(config.enabled) io.command([SERVICE,'start'],15);
        return status();
    }
    function trust_action(request) {
        const config=policy.validate(io.read(CONFIG,DEFAULT)),device=filter(config.devices,item=>item.id==request.device)[0];
        if(!device) die('unknown_device');
        const trust=io.read(TRUST,{});bypass();
        if(request.operation=='trust_revoke') delete trust[device.id];
        else {
            const report=request.report ?? {},fp=fingerprint();
            if(!fp||report.ca_sha256!=fp||report.system!==true) die('device_trust_not_verified');
            if(device.identity&&!length(identity.addresses(device,identity.resolve(config)))) die('device_identity_not_confirmed');
            const runtimes={system:true};for(let name in ['codex_app','codex_cli','images']) runtimes[name]=type(report[name])=='bool'?report[name]:null;
            trust[device.id]={verified:true,ca_sha256:fp,addresses:device.addresses,...(device.identity?{identity:device.identity}:{}),verified_at:time(),runtimes};
        }
        io.atomic(TRUST,trust);io.atomic(EFFECTIVE,effective(config,trust,identity.resolve(config)));return status();
    }
    function drain() {
        bypass();const deadline=io.now()+30,live=health(),pid=live.pid;
        if(!pid&&live.active_connections===0) return {drained:true};
        if(type(pid)!='int'||pid<=1) die('draining_engine_unconfirmed');
        function birth() {
            const stat=fs.readfile(`/proc/${pid}/stat`);
            return stat?split(trim(substr(stat,rindex(stat,') ')+2)),/\s+/)[19]:null;
        }
        const started=birth();if(started==null) return {drained:true};
        // SIGUSR1 closes idle HTTP connections, while active responses finish.
        // Stats listeners may close first; only the original process exiting is proof.
        service('signal',{instance:'engine',signal:10});
        while(birth()==started) {
            if(io.now()>=deadline) die('healthy_connections_still_draining');
            sleep(200);
        }
        return {drained:true};
    }
    function mutate(action,request,lock) {
        io.mkdir(RUN);
        if(action=='prepare-engine') {
            if(health().ready) return {prepared:true,running:true};
            return prepare_engine();
        }
        if(action=='tick') {tick(lock,false);return {reconciled:true};}
        if(action=='private-backup') {
            const destination=request.path,parent=type(destination)=='string'?fs.dirname(destination):null,info=parent?fs.lstat(parent):null;
            if(type(destination)!='string'||index(destination,'/')!=0||info?.type!='directory'||info.uid!=0||info.mode&0077) die('private_backup_directory_required');
            if(!fs.lstat(CA+'/mitmproxy-ca.pem')) die('ca_not_prepared');
            const output=fs.open(destination,'wxe',0600);
            if(!output) die('private_backup_destination_exists');
            output.close();
            try {
                const names=filter(['config.json','trust.json','ca'],name=>fs.lstat(BASE+'/'+name)!=null);
                const data=io.command(['tar','-czf','-','-C',BASE,...names],10);
                io.write(destination,data,true);
            } catch(error) {fs.unlink(destination);die(error.message);}
            return {private_backup_created:true,ca_sha256:fingerprint()};
        }
        if(index(['apply','enable','disable'],action)>=0) return apply(action,request);
        if(action=='bypass') {bypass();return {intercepting:false};}
        const previous=read_state();
        if(action=='suspend') {
            const instances=service('list')?.['opl-netfleet-compat']?.instances ?? {};
            const prior=previous.suspended;
            const saved=prior?{...prior,keep_maintenance:(prior.keep_maintenance ?? true)||request.lifecycle!==true}:
                {revision:revision(),requested:io.read(CONFIG,DEFAULT).enabled,running:length(filter(values(instances),item=>item.running))>0,
                    keep_maintenance:!!previous.maintenance||request.lifecycle!==true};
            save({...previous,recovery:{...(previous.recovery ?? {}),intercepting:false,healthy_since:null},suspended:saved,maintenance:true,intercepting:false,reason:'maintenance'},previous);
            drain();call('remove');if(length(instances)) service('delete');return saved;
        }
        if(action=='resume') {
            if(request.running&&request.requested&&request.revision==revision()&&io.read(CONFIG,DEFAULT).enabled) {
                const keep=request.keep_maintenance ?? true;
                if(keep) previous.maintenance=true;else delete previous.maintenance;
                delete previous.suspended;
                const recovery={...(previous.recovery ?? {}),intercepting:false,healthy_since:null};
                save({...previous,recovery,intercepting:false,reason:keep?'maintenance':recovery.latched?'manual_recovery_required':'recovering'},previous);
                io.command([SERVICE,'start'],15);
            }
            return {intercepting:false};
        }
        if(action=='drain'||action=='remove') {
            save({...previous,recovery:{...(previous.recovery ?? {}),intercepting:false,healthy_since:null},maintenance:true,intercepting:false,reason:'maintenance'},previous);
            const result=drain();if(action=='remove') call('remove');return result;
        }
        if(action=='probe') {
            if(request.revision!=revision()) die('compatibility_revision_conflict');
            if(index(['trust_record','trust_revoke'],request.operation)>=0) return trust_action(request);
            if(request.operation=='recover') {
                if(request.rule) {
                    const config=io.read(CONFIG,DEFAULT);
                    if(!length(filter(config.rules,rule=>rule.id==request.rule))) die('unknown_rule');
                    const old=previous.rule_recovery?.[request.rule] ?? {};
                    const counts=map(filter(health().failure_events ?? [],event=>event.rule==request.rule),event=>event.id);
                    previous.rule_recovery??={};previous.rule_recovery[request.rule]={last_error:max(old.last_error ?? 0,...counts)};
                } else for(let name in ['recovery','unhealthy_since','engine_restart','maintenance']) delete previous[name];
                write_state(previous);
            }
            return status();
        }
        die('unknown_compatibility_action');
    }
    function dispatch(action,request) {
        if(action=='get') return status();
        if(action=='ca') return {pem:fs.readfile(CA+'/mitmproxy-ca-cert.pem'),sha256:fingerprint()};
        const lock=io.lock(2);let result,failure;
        try {result=mutate(action,request ?? {},lock);}catch(error){failure=error;}
        io.unlock(lock);if(failure) die(failure.message);return result;
    }
    function watch() {
        uloop.init();let delayed=false;
        let timer;
        timer=uloop.timer(0,function() {
            const started=io.now();let lock;
            try {lock=io.lock(0);io.measure('tick',()=>tick(lock,delayed));delayed=false;}
            catch(error) {
                const reason=match(error.message ?? '',/^[a-z_]+$/)?error.message:'compatibility_controller_failed';
                delayed=reason=='mutation_busy';
                if(index(['mutation_busy','compatibility_probe_stale'],reason)<0) try {
                    if(!lock) lock=io.lock(0);
                    try {bypass();}catch(_){}
                    const previous=read_state(),config=io.read(CONFIG,DEFAULT);
                    const recovery=advance(previous.recovery,{requested:config.enabled,healthy:false,reason,now:io.now(),
                        count_failure:previous.intercepting===true&&index(['gateway_command_failed','compatibility_controller_failed'],reason)>=0});
                    save({...previous,recovery,intercepting:false,reason:recovery.reason,last_failure:{at:time(),reason}},previous);
                } catch (_) {}
            }
            io.unlock(lock);
            try {io.profile(RUN+'/profile.json');} catch (_) {}
            timer.set(max(50,int(2000-(io.now()-started)*1000)));
        });
        uloop.run();return {stopped:true};
    }
    return {dispatch,watch,tick,effective,verified_trust,revision,status};
};
