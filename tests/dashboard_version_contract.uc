import * as fs from "fs";
import { script_version, bundled_version } from "../openwrt/files/usr/libexec/opl-netfleet/adapters/dashboard_version.uc";

function check(value, label) { if (!value) die(label); };
const release = "https://api.github.com/repos/Zephyruso/zashboard/releases/latest";
function script(binding, version, quote) {
	return `var dependency=ref("9.9.9"),${binding}=ref(${quote}${version}${quote});async function check(){return await fetchCached("${release}",${binding}.value)}`;
};
for (let quote in ["\"", "'", "`"]) {
	check(script_version(script("$version_7", "3.25.0", quote)) == "v3.25.0", "recognize compiled version independently of minifier names and quote style");
}
check(script_version(`const current = vueRef('3.24.1'); fetchCached('${release}', current.value )`) == "v3.24.1", "unminified binding supported");
check(script_version(`var av=ref('9.9.9'),v=rv('3.24.1'); fetchCached('${release}',v.value)`) == "v3.24.1", "identifier suffix and reference-function overlap handled");
check(script_version("var vue=ref('3.5.0'); var sanitizer=ref('3.1.0');") == null, "dependency versions are not dashboard versions");
check(script_version(`fetchCached('${release}',missing.value); var other=ref('1.2.3');`) == null, "unresolved binding is not guessed");
check(script_version(script("v", "3.25.0", "\"") + '; v=ref("1.2.3");') == null, "ambiguous binding rejected");
check(script_version(script("v", "3.25.0", "\"") + script("w", "3.24.0", "'")) == null, "ambiguous release check rejected");
check(script_version(null) == null, "missing resource handled");

const work = fs.mkdtemp("/tmp/netfleet-dashboard-version.XXXXXX");
check(work != null && fs.mkdir(`${work}/assets`), "create isolated resource fixture");
const entry = `${work}/index.html`, asset = `${work}/assets/index-build.js`;
const html = '<html><script type="module" crossorigin src="./assets/index-build.js"></script></html>';
fs.writefile(entry, html);
fs.writefile(asset, script("v", "3.25.0", "`"));
fs.writefile(`${work}/assets/old.js`, script("old", "1.0.0", "'"));
check(bundled_version(work) == "v3.25.0", "only the actual entry resource is used, not stale assets");
fs.writefile(asset, script("changed", "3.26.0", "\""));
check(bundled_version(work) == "v3.26.0", "asset replacement reflected without stale version cache");
fs.writefile(entry, '<script src="assets/index-build.js" type="module"></script>');
check(bundled_version(work) == "v3.26.0", "attribute order and relative asset path supported");
fs.writefile(entry, '<script type="module" src="https://example.test/index-build.js"></script>');
check(bundled_version(work) == null, "external resource is not fetched");
fs.writefile(entry, '<script type="module" src="./assets/../index-build.js"></script>');
check(bundled_version(work) == null, "traversal rejected");
fs.writefile(entry, html + '<script type="module" src="assets/old.js"></script>');
check(bundled_version(work) == null, "conflicting entry versions not guessed");
fs.writefile(entry, html);
fs.unlink(asset);
check(bundled_version(work) == null, "missing resource not treated as installed version");
fs.symlink(`${work}/assets/old.js`, asset);
check(bundled_version(work) == null, "linked asset not read");
fs.unlink(asset);
const large = fs.open(asset, "w");
large.truncate(8388609);
large.close();
check(bundled_version(work) == null, "resource read budget enforced");
fs.unlink(asset);
fs.unlink(`${work}/assets/old.js`);
fs.rmdir(`${work}/assets`);
fs.unlink(entry);
fs.rmdir(work);
print("dashboard_version_contract_ok\n");
