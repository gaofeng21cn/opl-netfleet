import * as fs from "fs";

function bounded_file(path, limit) {
	const info = fs.lstat(path);
	if (info?.type != "file" || info.size <= 0 || info.size > limit) return null;
	const file = fs.open(path, "r");
	if (file == null) return null;
	const data = file.read(limit + 1);
	file.close();
	return length(data) <= limit ? data : null;
};

export function script_version(source) {
	if (type(source) != "string") return null;
	// Upstream assembly/version.ts passes ref(__APP_VERSION__).value to its
	// release checker. Follow that binding, never an arbitrary dependency semver.
	const endpoint = "https://api.github.com/repos/Zephyruso/zashboard/releases/latest";
	const offset = index(source, endpoint);
	if (offset < 1 || offset != rindex(source, endpoint)) return null;
	const check = match(substr(source, offset - 1, 256), /^["'`]https:\/\/api\.github\.com\/repos\/Zephyruso\/zashboard\/releases\/latest["'`][[:space:]]*,[[:space:]]*([A-Za-z_$][A-Za-z0-9_$]*)\.value[[:space:]]*\)/);
	if (check == null) return null;
	const parts = split(source, check[1], 4096);
	if (length(parts) >= 4096) return null;
	let version = null, position = 0;
	for (let i = 1; i < length(parts); i++) {
		position += length(parts[i - 1]);
		const before = position > 0 ? substr(source, position - 1, 1) : "";
		position += length(check[1]);
		if (before != "" && !match(before, /[;,[:space:]]/)) continue;
		const definition = match(substr(source, position, 128), /^[[:space:]]*=[[:space:]]*[A-Za-z_$][A-Za-z0-9_$]*\([[:space:]]*(["'`])([0-9]+\.[0-9]+\.[0-9]+)(["'`])[[:space:]]*\)/);
		if (definition == null || definition[1] != definition[3]) continue;
		if (version != null) return null;
		version = `v${definition[2]}`;
	}
	return version;
};

export function bundled_version(directory) {
	if (type(directory) != "string" || fs.lstat(directory)?.type != "directory" ||
		fs.lstat(`${directory}/assets`)?.type != "directory") return null;
	const html = bounded_file(`${directory}/index.html`, 65536);
	if (html == null) return null;
	const scripts = match(html, /<script[[:space:]][^>]*>/g) ?? [];
	if (length(scripts) > 8) return null;
	let version = null, remaining = 8388608;
	for (let script in scripts) {
		if (!match(script[0], /[[:space:]]type=["']module["']/)) continue;
		const src = match(script[0], /[[:space:]]src=["'](\.\/)?(assets\/[A-Za-z0-9_.-]+\.js)["']/);
		if (src == null) continue;
		const source = bounded_file(`${directory}/${src[2]}`, remaining);
		if (source == null) continue;
		remaining -= length(source);
		const detected = script_version(source);
		if (detected == null) continue;
		if (version != null && detected != version) return null;
		version = detected;
	}
	return version;
};
