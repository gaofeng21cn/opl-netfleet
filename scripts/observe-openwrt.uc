import * as fs from 'fs';

// Bounded target-local observation: no selection, refresh, or restart commands.
const seconds = int(ARGV[0]), output = ARGV[1];
if (seconds < 10 || seconds > 1800 || type(output) != 'string') exit(2);
const samples = [], started = time();
function read(command) {
 const pipe = fs.popen(command + ' 2>/dev/null');
 if (pipe == null) return null;
 const raw = pipe.read('all');
 if (pipe.close() != 0) return null;
 try { return json(raw); } catch (error) { return null; }
}
function processes() {
 const result = {};
 for (let name in ['opl-netfleet-core', 'opl-netfleet']) {
  const value = read(`ubus call service list '{"name":"${name}"}'`);
  for (let key, entry in value?.[name]?.instances ?? {}) {
   if (!entry.running) continue;
   const fields = split(replace(fs.readfile(`/proc/${entry.pid}/stat`) ?? '', /^.*\) /, ''), ' ');
   const status = fs.readfile(`/proc/${entry.pid}/status`) ?? '';
   result[`${name}/${key}`] = { pid: entry.pid, ticks: int(fields[11]) + int(fields[12]),
    rss_kib: int(match(status, /VmRSS:\s*(\d+)/)?.[1] ?? 0) };
  }
 }
 return result;
}
const before = processes();
let healthy = true;
while (true) {
 const begin = (+split(fs.readfile("/proc/uptime"), " ")[0]);
 const status = read('ucode /usr/libexec/opl-netfleet/main.uc status');
 const elapsed = ((+split(fs.readfile("/proc/uptime"), " ")[0]) - begin) * 1000;
 const runtime = status?.result?.runtime;
 const ok = status?.ok == true && status.result.active == true && runtime?.controller_available == true &&
  runtime?.lan_runtime?.dns_ready == true && runtime?.lan_runtime?.transparent_proxy_ready == true;
 healthy = healthy && ok;
 push(samples, { elapsed_ms: elapsed, ok, processes: processes() });
 if (time() - started >= seconds) break;
 system('sleep 5');
}
const probe = read('ucode /usr/libexec/opl-netfleet/main.uc probe');
healthy = healthy && probe?.ok == true && probe.result?.ok == true;
const after = processes(), delays = sort(map(samples, sample => sample.elapsed_ms), (a,b) => a-b);
let stable = true;
for (let name, value in before) {
 if (after[name]?.pid != value.pid) stable = false;
 for (let sample in samples) if (sample.processes[name]?.pid != value.pid) stable = false;
}
const result = { ok: healthy && stable, duration_seconds: time() - started, samples: length(samples),
 status_p50_ms: delays[int((length(delays)-1)*0.5)], status_p95_ms: delays[int((length(delays)-1)*0.95)],
 runtime_healthy: healthy, owner_pids_stable: stable, before, after, protected_probe: probe?.result?.ok == true };
const file = fs.open(output, 'w', 0600);
if (file == null) exit(1);
file.write(sprintf('%J\n', result)); file.close();
exit(result.ok ? 0 : 1);
