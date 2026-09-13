# Sourced only by the isolated native network fixture after wire is defined.
bench=/tmp/https-native-network/benchmark
mkdir -p "$bench"
bench_capture() {
 ucode - <<'UC'
import * as fs from 'fs';
const groups={};
for(let name in ['netfleet-compat','netfleet-compat-manager','services/opl-netfleet-core/core']) {
 const path='/sys/fs/cgroup/'+name,stats={};
 for(let line in split(trim(fs.readfile(path+'/cpu.stat') ?? ''),'\n')) {const v=split(line,/\s+/);if(length(v)==2)stats[v[0]]=+v[1];}
 let rss=0,count=0;
 for(let pid in split(trim(fs.readfile(path+'/cgroup.procs') ?? ''),/\s+/)) {
  if(!length(pid))continue;
  const status=fs.readfile('/proc/'+pid+'/status');if(!status)continue;
  rss+=(+(match(status,/\nVmRSS:\s*([0-9]+)/)?.[1] ?? 0))*1024;count++;
 }
 groups[name]={...stats,memory:+fs.readfile(path+'/memory.current'),rss,processes:count};
}
printf('%J\n',{at:+split(fs.readfile('/proc/uptime'),' ')[0],groups});
UC
}
bench_enable() {
 ucode - <<'UC'
import * as fs from 'fs';
const p='/tmp/bench-enable.json',main='/usr/libexec/opl-netfleet/main.uc';
let pipe=fs.popen('ucode '+main+' compatibility-get'),v=json(pipe.read('all'));if(pipe.close()||!v.ok)die('state');
fs.writefile(p,sprintf('%J',{request:{revision:v.result.revision}}));
if(system('ucode '+main+' compatibility-enable '+p+' >/dev/null'))die('enable');fs.unlink(p);
UC
 wait_intercepting
}
dd if=/dev/zero of="$bench/upload.bin" bs=1024 count=128 2>/dev/null
for rep in 1 2 3; do
 for scene in off idle load ui; do
  versions='old new'; [ "$rep" != 2 ] || versions='new old'
  for version in $versions; do
  out="$bench/$version-$rep-$scene"; mkdir -p "$out"
  # Same guest and base, actual signed APK replacement, balanced A/B order.
  # The preceding package-cycle fixture supplies the guarded installer.
  if [ "$version" = old ]; then cycle_install "$cycle_old"; else cycle_install "$cycle_new"; fi
  if [ "$scene" = off ]; then
   ucode /tmp/tests/https_native_guest.uc disable >"$out/intent.log"
   sleep 12
  else wait_intercepting; fi
  apk info -v opl-netfleet-https-compat >"$out/package.txt"
  sleep 10
  deadline=$(($(date +%s)+300))
  bench_capture >"$out/before.json"
  if [ "$scene" = load ] || [ "$scene" = ui ]; then
   (
    while [ "$(date +%s)" -lt "$deadline" ]; do
     rc=0; wire -sS --data-binary "@$bench/upload.bin" -D "$out/upload.headers" -o /dev/null -w '%{http_code} %{time_starttransfer} %{time_total}\n' 'https://wire.example/compat-wire/echo' >>"$out/upload.tsv" 2>>"$out/errors.log" || rc=$?
     grep -iq '^x-upstream-protocol: h2' "$out/upload.headers" || echo upload_protocol_mismatch >>"$out/errors.log"
     echo "$rc" >>"$out/codes"; sleep 1
    done
   ) & upload_pid=$!
   (
    while [ "$(date +%s)" -lt "$deadline" ]; do
     rc=0; wire -sSN -D "$out/sse.headers" -o /dev/null -w '%{http_code} %{time_starttransfer} %{time_total}\n' 'https://wire.example/compat-wire/events' >>"$out/sse.tsv" 2>>"$out/errors.log" || rc=$?
     grep -iq '^x-upstream-protocol: h2' "$out/sse.headers" || echo sse_protocol_mismatch >>"$out/errors.log"
     echo "$rc" >>"$out/codes"
    done
   ) & events_pid=$!
  fi
  if [ "$scene" = ui ]; then
   (while [ "$(date +%s)" -lt "$deadline" ]; do
    ucode - "$out" <<'UC' || echo ui >>"$out/errors.log"
import * as fs from 'fs';
function clock(){return +split(fs.readfile('/proc/uptime'),' ')[0];}
function ticks(){const s=fs.readfile('/proc/self/stat'),v=split(substr(s,index(s,')')+2),' ');return +v[11]+ +v[12]+ +v[13]+ +v[14];}
const start=clock(),cpu=ticks(),p=fs.popen('ucode /usr/libexec/opl-netfleet/main.uc compatibility-get'),raw=p.read('all'),rc=p.close(),elapsed=clock()-start,used=ticks()-cpu;
fs.writefile(ARGV[0]+'/ui.json',raw);
const f=fs.open(ARGV[0]+'/ui.jsonl','a');f.write(sprintf('%J\n',{seconds:elapsed,cpu_ticks:used,ok:rc==0&&json(raw)?.ok==true}));f.close();
if(rc||json(raw)?.ok!=true)die('ui_query_failed');
UC
    sleep 10
   done) & ui_pid=$!
  fi
  while [ "$(date +%s)" -lt "$deadline" ]; do
   bench_capture >>"$out/samples.jsonl"
   sleep 2
  done
  bench_capture >"$out/after.json"
  if [ "$scene" = load ] || [ "$scene" = ui ]; then wait "$upload_pid";wait "$events_pid";fi
  [ "$scene" != ui ] || wait "$ui_pid"
  test "$(pidof mihomo)" = "$base_pid"
  sha256sum -c "$work/base.sha256" >/dev/null
  echo "BENCHMARK $version $rep $scene completed" >&2
  # Off measurements leave intent disabled. Restore it before the next
  # installer, whose postcondition deliberately requires a real H2 path.
  [ "$scene" != off ] || bench_enable
  done
 done
done
# Leave the candidate installed for the remaining fault qualification.
cycle_install "$cycle_new"
ucode - "$bench" <<'UC' >"$work/benchmark.json"
import * as fs from 'fs';
const root=ARGV[0],rows=[];
for(let name in fs.lsdir(root)) {
 if(!match(name,/^(old|new)-[123]-(off|idle|load|ui)$/))continue;
 const before=json(fs.readfile(root+'/'+name+'/before.json')),after=json(fs.readfile(root+'/'+name+'/after.json'));
 const groups={},elapsed=after.at-before.at;
 const samples=[];for(let line in split(trim(fs.readfile(root+'/'+name+'/samples.jsonl') ?? ''),'\n'))if(length(line))push(samples,json(line));
 for(let id,end in after.groups){const start=before.groups[id];let peak_memory=0,peak_rss=0;for(let sample in samples){peak_memory=max(peak_memory,sample.groups[id].memory);peak_rss=max(peak_rss,sample.groups[id].rss);}groups[id]={cpu_percent:(end.usage_usec-start.usage_usec)/(elapsed*10000),memory:end.memory,peak_memory,peak_rss,throttled:end.nr_throttled-start.nr_throttled};}
 const requests={};for(let kind in ['upload','sse']){const values=[];for(let line in split(trim(fs.readfile(root+'/'+name+'/'+kind+'.tsv') ?? ''),'\n')){const v=split(line,' ');if(length(v)==3)push(values,{code:+v[0],ttfb:+v[1],total:+v[2]});}requests[kind]=values;}
 const ui=[];for(let line in split(trim(fs.readfile(root+'/'+name+'/ui.jsonl') ?? ''),'\n'))if(length(line))push(ui,json(line));
 const parts=split(name,'-');push(rows,{name:parts[1]+'-'+parts[2],version:parts[0],package:trim(fs.readfile(root+'/'+name+'/package.txt')),seconds:elapsed,groups,requests,ui,errors:trim(fs.readfile(root+'/'+name+'/errors.log') ?? ''),codes:trim(fs.readfile(root+'/'+name+'/codes') ?? '')});
}printf('%J\n',{environment:'isolated_openwrt',seconds:300,repeats:3,comparison:'alternating_signed_packages_same_guest',cpu_ticks_per_second:100,rows});
UC
