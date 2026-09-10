// Measurements from the disposable guest, excluding host test tools.
import * as fs from 'fs';
function counters(path) {
    const result={};
    for(let line in split(trim(fs.readfile(path) ?? ''),'\n')) {
        const parts=split(line,/\s+/);if(length(parts)==2) result[parts[0]]=+parts[1];
    }
    return result;
}
if(ARGV[0]=='capture') {
    const groups={};
    for(let name in ['netfleet-compat','netfleet-compat-manager']) {
        const path='/sys/fs/cgroup/'+name;let rss=0;
        for(let pid in split(trim(fs.readfile(path+'/cgroup.procs') ?? ''),/\s+/)) {
            const status=fs.readfile('/proc/'+pid+'/status') ?? '';
            rss+=(+(match(status,/\nVmRSS:\s*([0-9]+)/)?.[1] ?? 0))*1024;
        }
        groups[name]={...counters(path+'/cpu.stat'),cgroup_memory_bytes:+fs.readfile(path+'/memory.current'),rss_bytes:rss};
    }
    printf('%J\n',{monotonic:+split(fs.readfile('/proc/uptime'),' ')[0],groups});
} else {
    const root=ARGV[1],result={};
    for(let row in [['idle','idle-before','idle-after'],['20_requests','idle-after','load-after']]) {
        const before=json(fs.readfile(root+'/'+row[1]+'.json')),after=json(fs.readfile(root+'/'+row[2]+'.json'));
        const elapsed=after.monotonic-before.monotonic,groups={};
        if(elapsed<=0) die('measurement_window_empty');
        for(let name,end in after.groups) {
            const start=before.groups[name];
            groups[name]={cpu_percent_of_one_core:(end.usage_usec-start.usage_usec)/(elapsed*10000.0),
                throttled_periods:end.nr_throttled-start.nr_throttled,total_periods:end.nr_periods-start.nr_periods,
                cgroup_memory_bytes:end.cgroup_memory_bytes,rss_bytes:end.rss_bytes};
        }
        result[row[0]]={seconds:elapsed,groups};
    }
    printf('%J\n',{environment:'isolated_openwrt_qemu',measurements:result});
}
