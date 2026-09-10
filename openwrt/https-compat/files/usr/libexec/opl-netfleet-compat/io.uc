import * as fs from 'fs';
import { sha256 } from 'digest';
return function(options) {
    const root = options.root;
    const quote = value => "'" + replace(`${value}`, "'", "'\\''") + "'";
    const now = () => +split(fs.readfile('/proc/uptime'), ' ')[0];
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
        const result = options.process.capture(join(' ', map(args, quote)), timeout ?? 2, input);
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
        if (file.lock('xn')) return file;
        if (ancestor_lock(path)) { file.close(); return null; }
        const deadline = now() + (wait ?? 0);
        while (now() < deadline) {
            sleep(20);
            if (file.lock('xn')) return file;
        }
        file.close(); die('mutation_busy');
    }
    function unlock(file) { if (file) { file.lock('u'); file.close(); } }
    return {root, quote, now, read, mkdir, command, write, atomic, canonical, sha256, lock, unlock};
};
