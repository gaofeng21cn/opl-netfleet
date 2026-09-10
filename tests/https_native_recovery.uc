const advance=loadfile(ARGV[0]+'/recovery.uc')();
function check(value,message){if(!value) die(message);}
let state;
function step(now,healthy,extra){state=advance(state,{now,requested:true,healthy,reason:'engine_unavailable',...(extra ?? {})});return state;}
check(!step(0,true).intercepting,'initial_admission');
check(!step(29,true).intercepting,'early_admission');
check(step(30,true).intercepting,'healthy_admission_missing');
check(length(step(31,false).faults)==1,'fault_missing');
check(length(step(33,false).faults)==1,'same_fault_counted_twice');
step(34,true);check(step(64,true).intercepting,'recovery_missing');
step(65,false);step(66,true);step(96,true);
check(step(97,false).latched,'third_fault_not_latched');
step(98,true);check(!step(150,true).intercepting,'automatic_unlock');
check(!step(151,true,{requested:false}).intercepting,'disabled_admission');
check(!step(152,true,{manual_reset:true}).intercepting,'manual_reset_skipped_hold');
check(step(182,true).intercepting,'manual_recovery_failed');
check(!step(183,false,{count_failure:false}).latched,'unadmitted_failure_counted');
state=null;step(0,true);step(30,true);step(31,false);step(32,true);step(62,true);
check(length(step(700,false).faults)==1,'fault_window_not_expired');
print('native recovery: 30s hold, independent faults, 10min window, latch, manual reset, disable passed\n');
