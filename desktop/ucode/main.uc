import * as fs from 'fs';
import { execute } from './kernel/host.uc';
import { create } from './adapters/macos.uc';
import { set_executor, invoke } from './bridge.uc';

const root = sourcepath(0, true);
const adapter = create(root);
set_executor(argv => execute(argv, root, { adapter }));
// One actual flock covers command entry, all recursive owner calls and readback.
const lock = adapter.network_lock(adapter.paths.network_lock, true);
if (lock == null) { printf('%J\n', { ok: false, error: 'mutation_busy' }); exit(1); }
const result = invoke(ARGV);
lock.close();
if (result != null) printf('%J\n', result);
if (result?.ok == false) exit(1);
