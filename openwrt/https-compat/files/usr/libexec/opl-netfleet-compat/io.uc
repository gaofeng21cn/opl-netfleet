import * as fs from 'fs';
import { sha256 } from 'digest';
return function(options) {
    const root = options.root;
    const quote = value => "'" + replace(`${value}`, "'", "'\\''") + "'";
    const now = () => +split(fs.readfile('/proc/uptime'), ' ')[0];
    const profiling = getenv('NETFLEET_COMPAT_PROFILE') == '1';
    const timings = {};
    function record(name, elapsed, cpu) {
        const row=timings[name] ?? {count:0,total_ms:0,cpu_ms:0,max_ms:0,samples:[]};
        row.count++;row.total_ms+=elapsed;row.cpu_ms+=cpu ?? 0;row.max_ms=max(row.max_ms,elapsed);
        push(row.samples,elapsed);row.samples=slice(row.samples,-300);timings[name]=row;
    }
    function cpu() {
        const raw=fs.readfile('/proc/self/stat'),fields=split(substr(raw,rindex(raw,') ')+2),/\s+/);
        return (+fields[11]+(+fields[12])+(+fields[13])+(+fields[14]))*10;
    }
    function measure(name, work) {
        if (!profiling) return work();
        const started=now(),used=cpu();let value,error;
        try {value=work();} catch (failure) {error=failure;}
        record(name,max(0,int((now()-started)*1000)),max(0,cpu()-used));
        if(error) die(error.message);return value;
    }
    function profile(path) {
        if(profiling) atomic(path,{stages:timings,monotonic:now()});
    }
    function read(path, fallback) {
        const info = fs.lstat(path);
        if (!info) return fallback;
        if (info.type != 'file' || info.uid != 0 || info.mode & 0022 || info.size > 2097152) die('compatibility_state_unsafe');
        try { return json(fs.readfile(path)); } catch (_) { die('compatibility_state_invalid'); }
    }
    function mkdir(path, mode) {
        const info = fs.lstat(path);
        if (info) {
            if (info.type != 'directory' || info.uid != 0 || info.mode & 0022) die('compatibility_directory_unsafe');
            return;
        }
        mkdir(fs.dirname(path), 0700);
        if (!fs.mkdir(path, mode ?? 0700)) die('compatibility_storage_unavailable');
    }
    function command(args, timeout, input, accept_failure) {
        const result = measure('subprocess',()=>options.process.capture(join(' ', map(args, quote)), timeout ?? 2, input));
        const output = result.output, status = result.status;
        if (status == 124 || status == 137) die('compatibility_command_timeout');
        if (status != 0 && !accept_failure || output == null || length(output) > 2097152) die('compatibility_command_failed');
        return output;
    }
    function write(path, content, durable) {
        mkdir(fs.dirname(path));
        const temp = path + '.new';
        if (fs.lstat(temp)) fs.unlink(temp);
        const file = fs.open(temp, 'we', 0600);
        if (!file) die('compatibility_storage_unavailable');
        const count = file.write(content), closed = file.close();
        if (count != length(content) || !closed) { fs.unlink(temp); die('compatibility_storage_unavailable'); }
        if (durable) command([root + '/atomic-replace', fs.dirname(path), fs.basename(temp), fs.basename(path)], 3);
        else if (!fs.rename(temp, path)) { fs.unlink(temp); die('compatibility_storage_unavailable'); }
    }
    function canonical(value) {
        if (type(value) == 'object') return '{' + join(',', map(sort(keys(value)), key => sprintf('%J', key) + ':' + canonical(value[key]))) + '}';
        if (type(value) == 'array') return '[' + join(',', map(value, canonical)) + ']';
        return sprintf('%J', value);
    }
    function atomic(path, value) {
        const durable = index(path, '/etc/') == 0;
        write(path, (durable ? canonical(value) : sprintf('%J', value)) + '\n', durable);
    }
    function ancestor_lock(path) {
        const target = fs.stat(path); let pid = +fs.readlink('/proc/self');
        if (!target) return false;
        const visited = {};
        for (let n = 0; n < 64 && pid && !visited[pid]; n++) {
            visited[pid] = true;
            if (fs.stat(`/proc/${pid}`)?.uid != 0) return false;
            for (let name in fs.lsdir(`/proc/${pid}/fdinfo`) ?? []) {
                const fd = fs.stat(`/proc/${pid}/fd/${name}`);
                if (fd?.inode == target.inode && fd.dev.major == target.dev.major && fd.dev.minor == target.dev.minor &&
                    match(fs.readfile(`/proc/${pid}/fdinfo/${name}`) ?? '', /lock:.*FLOCK\s+ADVISORY\s+WRITE\s/)) return true;
            }
            pid = +(match(fs.readfile(`/proc/${pid}/status`) ?? '', /\nPPid:\s*(\d+)/)?.[1] ?? 0);
        }
        return false;
    }
    function lock(wait) {
        const path = '/var/lock/opl-netfleet-deploy.lock', file = fs.open(path, 'ae', 0600);
        if (!file) die('mutation_busy');
        if (file.lock('xn')) {lock_started();return file;}
        if (ancestor_lock(path)) { file.close(); return null; }
        const deadline = now() + (wait ?? 0);
        while (now() < deadline) {
            sleep(20);
            if (file.lock('xn')) {lock_started();return file;}
        }
        file.close(); die('mutation_busy');
    }
    let locked_at=null,renewed_at=null;
    function lock_started() { if(profiling) locked_at=now(); }
    function lock_stopped() { if(profiling&&locked_at!=null) {record('lock_held',int((now()-locked_at)*1000));locked_at=null;} }
    function renewed() { if(profiling) {const at=now();if(renewed_at!=null)record('renewal_interval',int((at-renewed_at)*1000));renewed_at=at;} }
    function unlock(file) { if (file) { lock_stopped();file.lock('u'); file.close(); } }
    return {root, quote, now, read, mkdir, command, write, atomic, canonical, sha256, lock, unlock,measure,profile,lock_started,lock_stopped,renewed};
};
