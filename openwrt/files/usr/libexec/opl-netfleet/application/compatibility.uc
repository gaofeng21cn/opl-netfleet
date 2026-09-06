import * as fs from "fs";
import { shell_quote } from "../adapters/uci.uc";

const OWNER = "/usr/libexec/opl-netfleet-compat/control.py";

export function dispatch(action, envelope) {
	if (fs.stat(OWNER) == null) return action == "get" ? { ok: true, result: {
		installed: false, requested: false, intercepting: false, reason: "component_not_installed",
		revision: null, config: { schema: 1, enabled: false, devices: [], rules: [] }, trust: {}, rules: {}, events: []
	} } : { ok: false, error: "compatibility_component_not_installed" };
	const command = `/usr/bin/python3 ${OWNER} ${shell_quote(action)}` + (envelope ? ` ${shell_quote(envelope)}` : "");
	const process = fs.popen(command + " 2>/dev/null");
	if (process == null) return { ok: false, error: "compatibility_owner_unavailable" };
	const raw = process.read("all");
	process.close();
	try { return json(raw); } catch (error) { return { ok: false, error: "compatibility_owner_no_response" }; }
};
