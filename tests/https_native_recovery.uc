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
state=null;step(0,true);step(30,true);
step(31,false,{reason:'transparent_chain_failed',transient_transparent_chain:true});
check(!step(32,true).intercepting,'transient_probe_admitted_immediately');
check(!step(39,true).intercepting,'transient_probe_early_admission');
check(step(40,true).intercepting,'transient_probe_recovery_missing');
step(41,false,{reason:'transparent_chain_failed',transient_transparent_chain:true});
step(42,true);step(45,false,{reason:'transparent_chain_failed',count_failure:false});
check(!step(54,true).intercepting,'repeated_probe_failure_kept_short_hold');
check(step(84,true).intercepting,'repeated_probe_failure_did_not_recover');
state=null;step(0,true);step(30,true);step(31,false);step(32,true);step(62,true);
check(length(step(700,false).faults)==1,'fault_window_not_expired');
print('native recovery: 30s default, 8s transient hold, repeated fault reset, 10min window and latch passed\n');
