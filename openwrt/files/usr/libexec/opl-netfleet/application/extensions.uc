import * as compatibility from "./compatibility.uc";
import * as dashboard from "./dashboard.uc";
import { resolve, admission, component } from "../core/extensions.uc";
import { KIND } from "../adapters/runtime.uc";

// Only compiled-in adapters can contribute commands; declarations never load code.
const MODULES = [compatibility, dashboard];

export function dispatch(command, envelope) {
	const entry = resolve(map(MODULES, module => module.extension), command);
	if (entry == null) return null;
	if (entry.error != null) return { ok: false, error: entry.error };
	const module = filter(MODULES, value => value.extension.id == entry.id)[0];
	const observed = module.inspection();
	const error = admission(module.extension, observed, command, KIND);
	if (error != null) return { ok: false, error: error };
	return module.dispatch(entry.method, envelope);
};

export function inventory(versions, resources) {
	return map(MODULES, module => component(module.extension,
		module.inspection(resources?.[module.extension.id]), versions, KIND));
};
