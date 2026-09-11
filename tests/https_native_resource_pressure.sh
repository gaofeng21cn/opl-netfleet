# Sourced by the isolated network fixture. Fault injection never reaches devices.
(
 test -f /tmp/netfleet-compat-vm-authorized
 group=/sys/fs/cgroup/netfleet-compat
 manager_group=/sys/fs/cgroup/netfleet-compat-manager
 memory_limit=$(cat "$group/memory.max")
 cpu_limit=$(cat "$manager_group/cpu.max")
 process_limit=$(cat "$manager_group/pids.max")
 restore_limits() {
  printf '%s\n' "$memory_limit" >"$group/memory.max"
  printf '%s\n' "$cpu_limit" >"$manager_group/cpu.max"
  printf '%s\n' "$process_limit" >"$manager_group/pids.max"
 }
 trap restore_limits EXIT INT TERM
 for fault in cpu processes memory; do
  case "$fault" in
   cpu) printf '1000 100000\n' >"$manager_group/cpu.max";;
   processes) printf '1\n' >"$manager_group/pids.max";;
   memory) cat "$group/memory.events" >"$work/memory-before"; printf '1048576\n' >"$group/memory.max";;
  esac
  sleep 12
  # Either a healthy converter or original path is allowed; business must complete.
  wire -fsS -o /dev/null https://wire.example/
  test "$(pidof mihomo)" = "$base_pid"
  sha256sum -c "$work/base.sha256" >/dev/null
  if [ "$fault" = memory ]; then
   cat "$group/memory.events" >"$work/memory-after"
   ucode - "$work" <<'UC'
import * as fs from 'fs';
function count(file){return +(match(fs.readfile(file),/oom_kill (\d+)/)?.[1] ?? 0);}
if(count(ARGV[0]+'/memory-after')<=count(ARGV[0]+'/memory-before'))die('memory_fault_not_exercised');
UC
  fi
  restore_limits
  ucode /tmp/tests/https_native_guest.uc recover >"$work/resource-recover-$fault.json"
  wait_intercepting
  probe 4 h2;probe 6 h2
 done
)
