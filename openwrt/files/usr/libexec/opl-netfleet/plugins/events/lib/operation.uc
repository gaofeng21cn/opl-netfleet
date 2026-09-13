import * as fs from "fs";

return function(context) {
// Bind the service functions before assigning closures that may reference them.
let path, public_snapshot, persist, details_update, begin, update, finish, get;



const process_identity = context.use("platform.process").process_identity;
const OPERATION_DIR = context.use("platform.paths").OPERATION_DIR;
let current = null;

path = function(kind) {
	return index(["subscription", "selection", "packages", "configuration", "mode"], kind) >= 0 ? `${OPERATION_DIR}/opl-netfleet-operation-${kind}.json` : null;
};


public_snapshot = function(value) {
	if (value == null) return null;
	return { id: value.id, parent_id: value.parent_id ?? null, kind: value.kind, state: value.state, phase: value.phase,
		started_at: value.started_at, updated_at: value.updated_at, finished_at: value.finished_at,
		completed: value.completed, total: value.total, subject: value.subject, error: value.error, recovery: value.recovery ?? null,
		failure_detail: value.failure_detail ?? null,
		...(value.kind == "mode" ? { requested_mode: value.requested_mode ?? null, actual_mode: value.actual_mode ?? null } : {}) };
};

persist = function() {
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

details_update = function(details) {
	if (type(details?.total) == "int" && details.total >= 0) current.total = details.total;
	if (type(details?.completed) == "int" && details.completed >= 0)
		current.completed = details.completed < current.total ? details.completed : current.total;
	if (index(keys(details ?? {}), "subject") >= 0)
		current.subject = type(details.subject) == "string" && !match(details.subject, /:\/\//) ? substr(details.subject, 0, 160) : null;
	if (current.kind == "mode") for (let field in ["requested_mode", "actual_mode"])
		if (field in (details ?? {})) current[field] = index(["openwrt", "mihomo", "netfleet"], details[field]) >= 0 ? details[field] : null;
};

begin = function(kind, phase, details) {
	if (path(kind) == null) return null;
	const owner = process_identity("self");
	const now = int(time());
	const id = type(details?.id) == "string" && match(details.id, /^[A-Za-z0-9_-]+$/) ? details.id : `${kind}-${now}-${owner?.pid ?? 0}`;
	const parent_id = type(details?.parent_id) == "string" && match(details.parent_id, /^subscription-[A-Za-z0-9_-]+$/) ? details.parent_id : null;
	current = { id: id, parent_id: parent_id, kind: kind, state: "running", phase: phase,
		started_at: now, updated_at: now, finished_at: null, completed: 0, total: 0, subject: null, error: null,
		owner: owner };
	details_update(details);
	persist();
	return public_snapshot(current);
};

update = function(phase, details) {
	if (current == null || current.state != "running") return null;
	current.phase = phase;
	current.updated_at = int(time());
	details_update(details);
	persist();
	return public_snapshot(current);
};

finish = function(ok, error, result) {
	if (current == null || current.state != "running") return null;
	const reason = error ?? result?.error ?? result?.reason;
	current.state = ok == true ? "succeeded" : "failed";
	current.updated_at = int(time());
	current.finished_at = current.updated_at;
	current.error = ok == true ? null : type(reason) == "string" && match(reason, /^[a-z][a-z0-9_]*$/) ? reason : "operation_failed";
	current.recovery = result?.rollback?.ok == true ? "restored" :
		result?.recovery?.ok == true && result.recovery.mode == "direct" ? "direct" :
		result?.rollback?.ok == false ? "failed" : null;
	if (current.kind == "mode") {
		details_update({ actual_mode: result?.mode });
		current.recovery = index(["restored", "native", "direct", "failed", "unchanged"], result?.recovery) >= 0 ? result.recovery : null;
	}
	// Preserve the narrow controller failure across browser disconnects. Other
	// result fields can contain private profiles or command output and stay out.
	const detail = result?.detail?.cause ?? result?.detail ?? result;
	if (current.error == "candidate_group_reset_failed" && type(detail?.http_status) == "int")
		current.failure_detail = { http_status: detail.http_status, transport_code: detail.transport_code,
			attempts: detail.attempts, group: type(detail.group) == "string" && !match(detail.group, /:\/\//) ? substr(detail.group, 0, 160) : null };
	persist();
	return public_snapshot(current);
};

get = function(kind) {
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

return { begin, update, finish, get };
};
