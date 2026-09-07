import * as fs from "fs";

return function(context) {
	const path = context.config?.data_path;
	const configured = type(path) == "string" && substr(path, 0, 1) == "/" &&
		!match(path, /[[:cntrl:]]/) && !match(path, /(^|\/)\.\.?($|\/)/) &&
		length(fs.basename(path)) > 0 && fs.stat(fs.dirname(path))?.type == "directory";

	function valid(value) {
		return type(value) == "object" && length(keys(value)) == 3 &&
			type(value.title) == "string" && length(trim(value.title)) > 0 && length(value.title) <= 120 &&
			!match(value.title, /[[:cntrl:]]/) && type(value.text) == "string" && length(value.text) <= 8192 &&
			type(value.generation) == "int" && value.generation >= 0;
	};

	function read(params) {
		if (!configured) return { ok: false, error: "not_configured" };
		const info = fs.lstat(path);
		if (info == null) return { ok: true, result: { title: "Workspace note", text: "", generation: 0 } };
		if (info.type != "file" || info.size > 65536) return { ok: false, error: "invalid_document" };
		let value;
		try { value = json(fs.readfile(path)); } catch (error) { return { ok: false, error: "invalid_document" }; }
		return valid(value) ? { ok: true, result: value } : { ok: false, error: "invalid_document" };
	};

	function save(params) {
		if (!valid(params)) return { ok: false, error: "invalid_configuration" };
		const current = read({});
		if (!current.ok) return current;
		if (params.generation != current.result.generation) return { ok: false, error: "configuration_conflict" };
		const value = { title: trim(params.title), text: params.text, generation: params.generation + 1 };
		const text = sprintf("%J\n", value);
		const transaction = context.scope();
		const directory = fs.mkdtemp(`${path}.XXXXXX`);
		if (directory == null) { transaction.dispose(); return { ok: false, error: "storage_unavailable" }; }
		const temporary = `${directory}/value.json`;
		transaction.effect(() => { fs.unlink(temporary); fs.rmdir(directory); });
		const file = fs.open(temporary, "wxe", 0600);
		if (file == null) { transaction.dispose(); return { ok: false, error: "storage_unavailable" }; }
		let closed = false;
		transaction.effect(() => { if (!closed) file.close(); });
		const written = file.write(text) == length(text) && file.flush();
		closed = file.close() == true;
		let verified = false;
		try { verified = fs.readfile(temporary) == text && valid(json(fs.readfile(temporary))); } catch (error) {}
		if (!written || !closed || !verified || !fs.rename(temporary, path)) {
			transaction.dispose();
			return { ok: false, error: "save_failed" };
		}
		transaction.dispose();
		const result = read({});
		if (!result.ok || result.result.generation != value.generation || fs.readfile(path) != text)
			return { ok: false, error: "save_readback_failed" };
		return result;
	};

	function inspect(argv) {
		return length(argv) == 1 ? read({}) : { ok: false, error: "unexpected_arguments" };
	};

	return { read, save, inspect };
};
