#!/usr/bin/ucode
import { create_scope } from '../openwrt/files/usr/libexec/opl-netfleet/kernel/scope.uc';

let assertions = 0;
function check(value, message) { if (!value) die(message); assertions++; };
function rejects(callback, expected) {
	try { callback(); }
	catch (error) { check(index(error.message, expected) >= 0, `${expected}: ${error.message}`); return; }
	die(`expected ${expected}`);
};

const first = create_scope(), second = create_scope();
let first_value = 0, second_value = 0;
const off = first.on('changed', value => { first_value += value; });
second.on('changed', value => { second_value += value; });
check(first.emit('changed', 2) == 1 && first_value == 2 && second_value == 0, 'root event buses are isolated');
check(second.emit('changed', 3) == 1 && second_value == 3, 'second instance receives its own events');
check(off() && !off(), 'unsubscribe is idempotent');
check(first.emit('changed', 5) == 0 && first_value == 2, 'early unsubscribe stops delivery');

const left = first.scope(), right = create_scope(first), descendant = left.scope();
let left_value = 0, right_value = 0, descendant_value = 0;
left.on('shared', value => { left_value += value; });
right.on('shared', value => { right_value += value; });
descendant.on('shared', value => { descendant_value += value; });
check(left.emit('shared', 1) == 3, 'children inherit the parent event bus');
check(left_value == 1 && right_value == 1 && descendant_value == 1, 'child emission reaches siblings and descendants');
check(left.dispose() && left.closed() && descendant.closed(), 'child disposal closes descendants');
check(!first.closed() && !right.closed(), 'child disposal leaves parent and sibling open');
check(first.emit('shared', 2) == 1 && right_value == 3 && left_value == 1 && descendant_value == 1, 'disposed subtree listeners are removed');
check(first.dispose() && right.closed() && !first.dispose(), 'parent disposal closes remaining children once');
check(second.emit('changed', 4) == 1 && second_value == 7, 'other root survives disposal');
second.dispose();
rejects(() => first.effect(() => {}), 'plugin_scope_closed');
rejects(() => first.on('changed', () => {}), 'plugin_scope_closed');
rejects(() => first.emit('changed', null), 'plugin_scope_closed');
rejects(() => first.scope(), 'plugin_scope_closed');
rejects(() => create_scope(first), 'plugin_scope_closed');

const ordered = create_scope(), order = [];
ordered.effect(() => { push(order, 'first'); });
const early = ordered.effect(() => { push(order, 'early'); });
const nested = ordered.scope();
nested.effect(() => { push(order, 'child-first'); });
nested.effect(() => { push(order, 'child-last'); });
ordered.effect(() => { push(order, 'last'); });
check(early() && !early(), 'resource cancellation is idempotent');
ordered.dispose();
check(join(',', order) == 'early,last,child-last,child-first,first', 'parent and child resources clean up in reverse registration order');
check(!early() && !nested.dispose() && !ordered.dispose(), 'disposed resources cannot be cleaned twice');

const failing = create_scope(), cleaned = [];
failing.effect(() => { push(cleaned, 'first'); die('first failure'); });
const failing_child = failing.scope();
failing_child.effect(() => { push(cleaned, 'child-first'); });
failing_child.effect(() => { push(cleaned, 'child-last'); die('child failure'); });
failing.effect(() => { push(cleaned, 'last'); die('last failure'); });
try { failing.dispose(); die('expected cleanup failure'); }
catch (error) {
	check(index(error.message, 'plugin_scope_dispose_failed') >= 0 &&
		index(error.message, 'first failure') >= 0 && index(error.message, 'child failure') >= 0 &&
		index(error.message, 'last failure') >= 0, 'cleanup aggregates failures');
}
check(join(',', cleaned) == 'last,child-last,child-first,first', 'cleanup failures do not skip remaining resources');
check(failing.closed() && failing_child.closed() && !failing.dispose(), 'failed cleanup still closes the full subtree');
const early_failure = create_scope();
let cleanup_calls = 0;
const fail_once = early_failure.effect(() => { cleanup_calls++; die('early failure'); });
rejects(fail_once, 'early failure');
check(!fail_once() && early_failure.dispose() && cleanup_calls == 1, 'failed early cancellation is not retried');

const events = create_scope(), calls = [];
let off_second = null, add_late = true;
events.on('change', () => {
	push(calls, 'first'); off_second();
	if (add_late) { add_late = false; events.on('change', () => { push(calls, 'late'); }); }
});
off_second = events.on('change', () => { push(calls, 'second'); });
check(events.emit('change') == 1 && join(',', calls) == 'first', 'emission skips cancelled listeners and defers newly registered listeners');
check(events.emit('change') == 2 && join(',', calls) == 'first,first,late', 'new listener receives the next emission');
events.on('failure', () => { push(calls, 'failure'); die('handler failure'); });
events.on('failure', () => { push(calls, 'after-failure'); });
rejects(() => events.emit('failure'), 'plugin_scope_emit_failed: handler failure');
check(calls[-1] == 'after-failure', 'handler failure does not skip other listeners');
events.dispose();

const closing = create_scope();
let after_close = false;
closing.on('close', () => closing.dispose());
closing.on('close', () => { after_close = true; });
check(closing.emit('close') == 1 && !after_close, 'closing emitter stops remaining delivery');

const cleanup_events = create_scope(), cleanup_child = cleanup_events.scope();
let closing_listener_called = false, live_listener_called = false;
cleanup_child.on('cleanup', () => { closing_listener_called = true; });
cleanup_events.on('cleanup', () => { live_listener_called = true; });
cleanup_child.effect(() => cleanup_events.emit('cleanup'));
cleanup_child.dispose();
check(!closing_listener_called && live_listener_called, 'cleanup emission cannot invoke a listener whose scope is already closing');
cleanup_events.dispose();

const invalid = create_scope();
rejects(() => invalid.effect(null), 'plugin_scope_callback_invalid');
rejects(() => invalid.on('test', null), 'plugin_scope_callback_invalid');
rejects(() => invalid.on('', () => {}), 'plugin_scope_event_invalid');
rejects(() => invalid.emit(123), 'plugin_scope_event_invalid');
rejects(() => create_scope({}), 'plugin_scope_parent_invalid');
invalid.dispose();
printf('scope contract: %d assertions passed\n', assertions);
