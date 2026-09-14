import { create } from '../../kernel/host.uc';
import { create as adapter } from '../../adapters/openwrt.uc';

// This file is executed from the retained transaction copy by the recovery init.
// Installed plugin maintenance must not hide the retained recovery implementation.
const root = sourcepath(0, true) + '/../..';
const host = create(root, { adapter: adapter(root), allow_maintenance: true, code_locks: false });
host.call('components.control', 'command', ['components-recover']);
