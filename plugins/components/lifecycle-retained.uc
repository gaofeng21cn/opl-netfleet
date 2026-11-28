// Use the existing kernel code lease after payload/runtime identity validation.
import { run } from '../../kernel/host.uc';
import { create } from '../../adapters/openwrt.uc';
const root = sourcepath(0, true) + '/../..';
if (length(ARGV) != 2 || ARGV[1] != 'mihomo' ||
    index(['plugin-package-drain', 'plugin-package-resume'], ARGV[0]) < 0)
    die('retained_lifecycle_scope_invalid');
run(ARGV, root, { adapter: create(root), lifecycle_instances: [] });
