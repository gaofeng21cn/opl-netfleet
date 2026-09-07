import { popen, writefile, readfile, stat } from "fs";

return function(context) {
	const shell_quote = context.use("platform.process").shell_quote;

	function read_yaml(path, quiet) {
		// Native artifacts retain .yaml paths for Mihomo but contain validated JSON.
		const source = readfile(path);
		if (source == null) return null;
		try { return json(source); } catch (error) {}
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
	function mkdir(path) { return system(`mkdir -p ${shell_quote(path)}`) == 0; }
	function write_json_atomic(path, value) {
		const content = sprintf("%J", value), temporary = `${path}.tmp`;
		if (content == null || !write_text(temporary, content) || read_json(temporary) == null) {
			system(`rm -f ${shell_quote(temporary)}`);
			return false;
		}
		const digest = sha256(temporary);
		if (digest == null || system(`mv -f ${shell_quote(temporary)} ${shell_quote(path)}`) != 0 || sha256(path) != digest) {
			system(`rm -f ${shell_quote(temporary)}`);
			return false;
		}
		return true;
	}
	return { read_yaml, read_json, sha256, file_mtime, sha256_text, write_text, mkdir, write_json_atomic };
};
