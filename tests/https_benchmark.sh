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
 groups[name]={...stats,memory:+fs.readfile(path+'/memory.current'),processes:length(split(trim(fs.readfile(path+'/cgroup.procs') ?? ''),/\s+/))};
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
  out="$bench/$rep-$scene"; mkdir -p "$out"
  if [ "$scene" = off ]; then
   ucode /tmp/tests/https_native_guest.uc disable >"$out/intent.log"
   sleep 12
  elif [ "$scene" = idle ]; then bench_enable; fi
  sleep 10
  deadline=$(($(date +%s)+300))
  bench_capture >"$out/before.json"
  if [ "$scene" = load ] || [ "$scene" = ui ]; then
   (
    while [ "$(date +%s)" -lt "$deadline" ]; do
     rc=0; wire -sS --data-binary "@$bench/upload.bin" -o /dev/null -w '%{http_code} %{time_starttransfer} %{time_total}\n' 'https://wire.example/compat-wire/echo' >>"$out/upload.tsv" 2>>"$out/errors.log" || rc=$?
     echo "$rc" >>"$out/codes"; sleep 1
    done
   ) & upload_pid=$!
   (
    while [ "$(date +%s)" -lt "$deadline" ]; do
     rc=0; wire -sSN -o /dev/null -w '%{http_code} %{time_starttransfer} %{time_total}\n' 'https://wire.example/compat-wire/events' >>"$out/sse.tsv" 2>>"$out/errors.log" || rc=$?
     echo "$rc" >>"$out/codes"
    done
   ) & events_pid=$!
  fi
  if [ "$scene" = ui ]; then
   (while [ "$(date +%s)" -lt "$deadline" ]; do
    ucode /usr/libexec/opl-netfleet/main.uc compatibility-get >"$out/ui.json" || echo ui >>"$out/errors.log"
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
  echo "BENCHMARK $rep $scene completed" >&2
 done
done
ucode - "$bench" <<'UC' >"$work/benchmark.json"
import * as fs from 'fs';
const root=ARGV[0],rows=[];
for(let name in fs.lsdir(root)) {
 if(!match(name,/^[123]-(off|idle|load|ui)$/))continue;
 const before=json(fs.readfile(root+'/'+name+'/before.json')),after=json(fs.readfile(root+'/'+name+'/after.json'));
 const groups={},elapsed=after.at-before.at;
 for(let id,end in after.groups){const start=before.groups[id];groups[id]={cpu_percent:(end.usage_usec-start.usage_usec)/(elapsed*10000),memory:end.memory,throttled:end.nr_throttled-start.nr_throttled};}
 const requests={};for(let kind in ['upload','sse']){const values=[];for(let line in split(trim(fs.readfile(root+'/'+name+'/'+kind+'.tsv') ?? ''),'\n')){const v=split(line,' ');if(length(v)==3)push(values,{code:+v[0],ttfb:+v[1],total:+v[2]});}requests[kind]=values;}
 push(rows,{name,seconds:elapsed,groups,requests,errors:trim(fs.readfile(root+'/'+name+'/errors.log') ?? ''),codes:trim(fs.readfile(root+'/'+name+'/codes') ?? '')});
}printf('%J\n',{environment:'isolated_openwrt',seconds:300,repeats:3,rows});
UC
