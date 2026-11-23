import * as fs from "fs";
const plugins_root = fs.realpath(replace(sourcepath(), /[^/]+$/, "../plugins"));
const factory = loadfile(`${plugins_root}/mihomo/lib/controller.uc`)();
const q = value => `'${replace(`${value}`, "'", "'\\''")}'`;
const controller = factory({ use: name => name == "platform.runtime" ? { API: ARGV[0], RUN_DIR: "/tmp" } :
 name == "platform.process" ? { shell_quote: q } : {} });
const result = controller.test_group_path("fixture", "preferred", { latency: {
 url: ARGV[1], timeout_ms: 1000, expected_status: ARGV[3] == null ? 200 : int(ARGV[3])
} });
printf('%J\n', result);
if (result != (ARGV[2] == "true")) die("expected-status health mismatch");
