import { popen, writefile, readfile, stat, lstat, mkdtemp, unlink, rmdir, rename, mkdir as fs_mkdir } from "fs";

return function(context) {
	const shell_quote = context.use("platform.process").shell_quote;
	const state = context.state ?? {};
	state.yaml_cache ??= [];
	let native_sha256 = null;
	try { native_sha256 = require("digest").sha256; } catch (error) {}
	// Store only expensive YAML conversions. JSON already has a native parser.
	// Exact source bytes, not mtime, decide reuse; callers receive a fresh object.
	function forget_yaml(path) {
		state.yaml_cache = filter(state.yaml_cache, item => item.path != path);
	}

	function read_yaml(path, quiet) {
		// Native artifacts retain .yaml paths for Mihomo but contain validated JSON.
		const source = readfile(path);
		if (source == null) { forget_yaml(path); return null; }
		try { const value = json(source); forget_yaml(path); return value; } catch (error) {}
		const cached = filter(state.yaml_cache, item => item.path == path && item.source == source)[0];
		if (cached != null) return json(cached.encoded);
		forget_yaml(path);
		// Convert an immutable private copy, never a path that can be replaced
		// after reading the bytes used as the cache identity.
		if (length(source) <= 524288) {
			const directory = mkdtemp("/tmp/netfleet-yaml.XXXXXX");
			if (directory == null) return null;
			const input = `${directory}/source`;
			let encoded = null, process, status;
			try {
				if (writefile(input, source) == length(source)) {
					process = popen(`yq -M -p yaml -o json ${shell_quote(input)}${quiet ? " 2>/dev/null" : ""}`);
					encoded = process?.read("all");
				}
			} catch (error) {}
			status = process?.close();
			unlink(input); rmdir(directory);
			if (status != 0 || encoded == null) return null;
			let value;
			try { value = json(encoded); } catch (error) { return null; }
			if (length(encoded) <= 524288) {
				if (length(state.yaml_cache) >= 4) shift(state.yaml_cache);
				push(state.yaml_cache, { path, source, encoded });
			}
			return value;
		}
		const process = popen(`yq -M -p yaml -o json ${shell_quote(path)}${quiet ? " 2>/dev/null" : ""}`);
		if (!process) return null;
		let result = null;
		try { result = json(process); } catch (error) {}
		return process.close() == 0 ? result : null;
	}
	function read_json(path) {
		if (stat(path)?.type != "file") return null;
		try { return json(readfile(path)); } catch (error) { return null; }
	}
	function sha256(path) {
		if (native_sha256 != null) {
			const info = stat(path);
			if (info?.type != "file") return null;
			if (info.size <= 16777216) {
				const content = readfile(path);
				return content == null ? null : native_sha256(content);
			}
		}
		const process = popen(`sha256sum ${shell_quote(path)}`);
		if (!process) return null;
		const line = process.read("line");
		const status = process.close();
		return status == 0 && line ? split(trim(line), " ")[0] : null;
	}
	function file_mtime(path) {
		const info = stat(path);
		return info?.type == "file" && info.mtime > 0 ? int(info.mtime) : null;
	}
	function sha256_text(value) {
		if (native_sha256 != null) return native_sha256(`${value}`);
		const process = popen(`printf '%s' ${shell_quote(value)} | sha256sum`);
		if (!process) return null;
		const line = process.read("line");
		const status = process.close();
		return status == 0 && line ? split(trim(line), " ")[0] : null;
	}
	function write_text(path, content) {
		const written = writefile(path, content);
		return type(written) == "int" && written == length(content);
	}
	function mkdir(path) {
		if (type(path) != "string" || length(path) == 0) return false;
		const clean = path == "/" ? "/" : replace(path, /\/+$/, "");
		if (length(clean) == 0) return true;
		if (stat(clean)?.type == "directory") return true;
		if (lstat(clean) != null) return false;
		const parent = replace(clean, /\/[^/]+$/, "");
		if (length(parent) > 0 && parent != clean && !mkdir(parent)) return false;
		return fs_mkdir(clean, 0755) == true || stat(clean)?.type == "directory";
	}
	function write_json_atomic(path, value) {
		const content = sprintf("%J", value), temporary = `${path}.tmp`;
		if (content == null || !write_text(temporary, content)) {
			unlink(temporary);
			return false;
		}
		let parsed = null;
		const staged = readfile(temporary);
		if (staged != content) {
			unlink(temporary);
			return false;
		}
		try { parsed = json(staged); } catch (error) { parsed = null; }
		if (parsed == null) {
			unlink(temporary);
			return false;
		}
		if (!rename(temporary, path) || readfile(path) != content) {
			unlink(temporary);
			return false;
		}
		return true;
	}
	return { read_yaml, read_json, sha256, file_mtime, sha256_text, write_text, mkdir, write_json_atomic };
};
