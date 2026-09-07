function create(bus, parent) {
	const resources = [];
	let is_closed = false, detach_parent = null;
	function assert_open() { if (is_closed) die('plugin_scope_closed'); };
	function event_name(event) {
		if (type(event) != 'string' || !length(event)) die('plugin_scope_event_invalid');
	};
	function effect(cleanup) {
		assert_open();
		if (type(cleanup) != 'function') die('plugin_scope_callback_invalid');
		let active = true;
		function revoke() {
			if (!active) return false;
			active = false;
			const position = index(resources, revoke);
			if (position >= 0) splice(resources, position, 1);
			const callback = cleanup;
			cleanup = null;
			callback();
			return true;
		};
		push(resources, revoke);
		return revoke;
	};
	function on(event, handler) {
		assert_open(); event_name(event);
		if (type(handler) != 'function') die('plugin_scope_callback_invalid');
		const listener = { event, handler, active: true, open: () => !is_closed };
		push(bus.listeners, listener);
		return effect(() => {
			listener.active = false;
			listener.handler = null;
			const position = index(bus.listeners, listener);
			if (position >= 0) splice(bus.listeners, position, 1);
		});
	};
	function emit(event, payload) {
		assert_open(); event_name(event);
		const errors = [], listeners = [...bus.listeners];
		let delivered = 0;
		for (let listener in listeners) {
			if (is_closed) break;
			if (!listener.active || !listener.open() || listener.event != event) continue;
			delivered++;
			try { listener.handler(payload); }
			catch (error) { push(errors, error.message); }
		}
		if (length(errors)) die(`plugin_scope_emit_failed: ${join('; ', errors)}`);
		return delivered;
	};
	function dispose() {
		if (is_closed) return false;
		is_closed = true;
		const errors = [];
		// Detach a child before cleanup so early disposal releases its parent entry.
		if (detach_parent != null) {
			const detach = detach_parent;
			detach_parent = null;
			try { detach(); } catch (error) { push(errors, error.message); }
		}
		while (length(resources)) {
			const revoke = pop(resources);
			try { revoke(); } catch (error) { push(errors, error.message); }
		}
		if (length(errors)) die(`plugin_scope_dispose_failed: ${join('; ', errors)}`);
		return true;
	};
	let scope;
	scope = {
		effect, on, emit, dispose,
		closed: () => is_closed,
		scope: () => { assert_open(); return create(bus, scope); },
	};
	if (parent != null) detach_parent = parent.effect(dispose);
	return scope;
};

export function create_scope(parent) {
	if (parent == null) return create({ listeners: [] }, null);
	if (type(parent) != 'object' || type(parent.scope) != 'function') die('plugin_scope_parent_invalid');
	return parent.scope();
};
