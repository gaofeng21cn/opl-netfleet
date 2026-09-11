import * as fs from 'fs';
const root=ARGV[0],dir=fs.mkdtemp('/tmp/compat-profile-test.XXXXXX'),path=dir+'/profile.json';
const io=loadfile(root+'/io.uc')()({root,process:{capture:()=>({status:0,output:'ok'})}});
const lock=io.lock(0),other=fs.open('/var/lock/opl-netfleet-deploy.lock','ae',0600);
if(other.lock('xn'))die('lock_not_held');
io.lock_stopped();lock.lock('u');
if(!other.lock('xn'))die('lock_not_released');other.lock('u');other.close();
if(!lock.lock('xn'))die('lock_reacquire_failed');io.lock_started();
if(io.command(['fixture'],1)!='ok')die('command_result_changed');
for(let n=0;n<400;n++)if(io.measure('test',()=>17)!=17)die('measure_result_changed');
let failed=false;try{io.measure('failed',()=>die('expected_failure'));}catch(e){failed=e.message=='expected_failure';}
if(!failed)die('measure_error_lost');
io.renewed();sleep(20);io.renewed();io.unlock(lock);io.profile(path);
const profiled=getenv('NETFLEET_COMPAT_PROFILE')=='1',raw=fs.readfile(path);
if(profiled){const stages=json(raw).stages;if(stages.test.count!=400||length(stages.test.samples)!=300||stages.failed.count!=1||stages.subprocess.count!=1||stages.lock_held.count!=2||stages.renewal_interval.count!=1)die('profile_accounting_failed');}
else if(raw!=null)die('profiling_not_opt_in');
fs.unlink(path);fs.rmdir(dir);print('profile: bounded accounting, exception propagation and actual lock release passed\n');
