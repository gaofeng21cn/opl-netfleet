import * as fs from "fs";

let current = null;

function path(kind) {
	return index(["subscription", "selection", "packages"], kind) >= 0 ? `/tmp/opl-netfleet-operation-${kind}.json` : null;
};

function process_identity(pid) {
	const source = fs.readfile(`/proc/${pid}/stat`);
	const fields = source == null ? null : match(source, /^([0-9]+) \(.*\) (.*)$/);
	if (fields == null) return null;
	const tail = split(trim(fields[2]), " ");
	return length(tail) > 19 ? { pid: int(fields[1]), started: tail[19], alive: tail[0] != "Z" && tail[0] != "X" } : null;
};

function public_snapshot(value) {
	if (value == null) return null;
	return { id: value.id, kind: value.kind, state: value.state, phase: value.phase,
		started_at: value.started_at, updated_at: value.updated_at, finished_at: value.finished_at,
		completed: value.completed, total: value.total, subject: value.subject, error: value.error, recovery: value.recovery ?? null };
};

function persist() {
	const destination = path(current.kind);
	const temporary = `${destination}.tmp`;
	const existing = fs.lstat(temporary);
	if (existing != null && (existing.type != "file" || (existing.mode & 077) != 0)) return false;
	const file = fs.open(temporary, "w", 0600);
	if (file == null) return false;
	const content = sprintf("%J", current);
	const written = file.write(content);
	const closed = file.close();
	if (written != length(content) || !closed || !fs.chmod(temporary, 0600) || !fs.rename(temporary, destination)) {
		fs.unlink(temporary);
		return false;
	}
	return true;
};

function details_update(details) {
	if (type(details?.total) == "int" && details.total >= 0) current.total = details.total;
	if (type(details?.completed) == "int" && details.completed >= 0)
		current.completed = details.completed < current.total ? details.completed : current.total;
	if (index(keys(details ?? {}), "subject") >= 0)
		current.subject = type(details.subject) == "string" && !match(details.subject, /:\/\//) ? substr(details.subject, 0, 160) : null;
};

export function begin(kind, phase, details) {
	if (path(kind) == null) return null;
	const owner = process_identity("self");
	const now = int(time());
	const id = type(details?.id) == "string" && match(details.id, /^[A-Za-z0-9_-]+$/) ? details.id : `${kind}-${now}-${owner?.pid ?? 0}`;
	current = { id: id, kind: kind, state: "running", phase: phase,
		started_at: now, updated_at: now, finished_at: null, completed: 0, total: 0, subject: null, error: null,
		owner: owner };
	details_update(details);
	persist();
	return public_snapshot(current);
};

export function update(phase, details) {
	if (current == null || current.state != "running") return null;
	current.phase = phase;
	current.updated_at = int(time());
	details_update(details);
	persist();
	return public_snapshot(current);
};

export function finish(ok, error, result) {
	if (current == null || current.state != "running") return null;
	const reason = error ?? result?.error ?? result?.reason;
	current.state = ok == true ? "succeeded" : "failed";
	current.updated_at = int(time());
	current.finished_at = current.updated_at;
	current.error = ok == true ? null : type(reason) == "string" && match(reason, /^[a-z][a-z0-9_]*$/) ? reason : "operation_failed";
	current.recovery = result?.rollback?.ok == true ? "restored" :
		result?.recovery?.ok == true && result.recovery.mode == "direct" ? "direct" :
		result?.rollback?.ok == false ? "failed" : null;
	persist();
	return public_snapshot(current);
};

export function get(kind) {
	const source = path(kind);
	if (source == null) return null;
	let value;
	try { value = json(fs.readfile(source)); } catch (error) { return null; }
	if (type(value) != "object" || value.kind != kind || type(value.id) != "string" ||
		index(["running", "succeeded", "failed"], value.state) < 0) return null;
	if (value.state == "running") {
		const owner = value.owner?.pid > 0 ? process_identity(value.owner.pid) : null;
		if (owner == null || !owner.alive || owner.started != value.owner?.started) {
			value.state = "interrupted";
			value.error = "operation_interrupted";
		}
	}
	return public_snapshot(value);
};
