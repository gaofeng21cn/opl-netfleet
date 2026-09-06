#!/bin/sh
# Run only inside the repository's disposable native-backend qualification guest.
set -eu
umask 077
test -f /tmp/netfleet-native-vm-authorized || test -f /tmp/netfleet-setup-vm-authorized
test "$(jsonfilter -i /etc/opl-netfleet/backend.json -e '@.kind')" = native-mihomo
command -v unzip >/dev/null
work=$(mktemp -d /tmp/netfleet-rules-dashboard.XXXXXX)
owner=/usr/libexec/opl-netfleet/application/dashboard.uc
state=/etc/opl-netfleet/native/dashboard.json
cache=/tmp/opl-netfleet-dashboard
mkdir "$work/bin"
export NETFLEET_DASHBOARD_TEST_WORK="$work"
export NETFLEET_DASHBOARD_TEST_CURL="$(command -v curl)"
ui=$(ucode -e 'import { read_yaml } from "/usr/libexec/opl-netfleet/adapters/uci.uc";
 import { RUN_DIR } from "/usr/libexec/opl-netfleet/adapters/runtime.uc";
 import { cursor } from "uci";
 const path = read_yaml(`${RUN_DIR}/config.yaml`, true)?.["external-ui"] ?? cursor().get("netfleet", "mixin", "ui_path");
 print(substr(path, 0, 1) == "/" ? path : `${RUN_DIR}/${path}`);')
case "$ui" in /etc/opl-netfleet/native/run/*) ;; *) exit 1 ;; esac
test ! -e "$ui.netfleet-stage"
test ! -e "$ui.netfleet-previous"
if [ -e "$ui" ]; then mv "$ui" "$work/original-ui"; fi
if [ -f "$state" ]; then mv "$state" "$work/original-state"; fi
if [ -d "$cache" ]; then mv "$cache" "$work/original-cache"; fi
finish() {
	rc=$?
	trap - EXIT INT TERM
	rm -rf "$ui" "$ui.netfleet-stage" "$ui.netfleet-previous" "$cache"
	[ ! -d "$work/original-ui" ] || mv "$work/original-ui" "$ui"
	rm -f "$state"
	[ ! -f "$work/original-state" ] || mv "$work/original-state" "$state"
	[ ! -d "$work/original-cache" ] || mv "$work/original-cache" "$cache"
	if [ "$rc" -ne 0 ]; then echo "Rules/dashboard qualification failed; evidence: $work" >&2; fi
	exit "$rc"
}
trap finish EXIT INT TERM
mkdir -p "$ui"
printf '<!doctype html><title>Previous dashboard</title>\n' >"$ui/index.html"
printf '%s\n' "$ui" >"$work/ui-path"
# Two deterministic ZIP fixtures, produced with Python's standard zipfile:
# one regular dist/index.html, one symlink entry with the same path.
ucode - "$work" <<'UCODE'
import * as fs from "fs";
const work = ARGV[0];
fs.writefile(`${work}/valid.zip`, b64dec("UEsDBBQAAAAAAAAAIQDuSKZfQwAAAEMAAAAPAAAAZGlzdC9pbmRleC5odG1sPCFkb2N0eXBlIGh0bWw+PHRpdGxlPlphc2hib2FyZCBmaXh0dXJlPC90aXRsZT48cD5uZXcgcmVzb3VyY2VzPC9wPlBLAQIUAxQAAAAAAAAAIQDuSKZfQwAAAEMAAAAPAAAAAAAAAAAAAACkgQAAAABkaXN0L2luZGV4Lmh0bWxQSwUGAAAAAAEAAQA9AAAAcAAAAAAA"));
fs.writefile(`${work}/link.zip`, b64dec("UEsDBBQAAAAAAAAAIQBheWBSFAAAABQAAAAPAAAAZGlzdC9pbmRleC5odG1sL2V0Yy9jb25maWcvbmV0ZmxlZXRQSwECFAMUAAAAAAAAACEAYXlgUhQAAAAUAAAADwAAAAAAAAAAAAAA/6EAAAAAZGlzdC9pbmRleC5odG1sUEsFBgAAAAABAAEAPQAAAEEAAAAAAA=="));
UCODE
cat >"$work/bin/curl" <<'CURL'
#!/bin/sh
set -eu
work=$NETFLEET_DASHBOARD_TEST_WORK
output=
previous=
url=
for argument in "$@"; do
	[ "$previous" != -o ] || output=$argument
	case "$argument" in http://*|https://*) url=$argument ;; esac
	previous=$argument
done
printf '.\n' >>"$work/curl-count"
case "$url" in
	https://api.github.com/repos/Zephyruso/zashboard/releases/latest)
		[ ! -f "$work/fail-check" ] || exit 22
		cat "$work/release.json" ;;
	https://github.com/Zephyruso/zashboard/releases/download/*/dist-cdn-fonts.zip)
		[ ! -f "$work/fail-download" ] || exit 22
		cp "$work/download.zip" "$output" ;;
	http://127.0.0.1:9090/ui/)
		[ ! -f "$work/fail-readback" ] || exit 22
		exec "$NETFLEET_DASHBOARD_TEST_CURL" "$@" ;;
	*) exec "$NETFLEET_DASHBOARD_TEST_CURL" "$@" ;;
esac
CURL
chmod 0755 "$work/bin/curl"
PATH="$work/bin:$PATH" flock /var/lock/opl-netfleet-deploy.lock ucode - "$work" <<'UCODE'
import * as fs from "fs";
import { resource, check, update } from "/usr/libexec/opl-netfleet/application/dashboard.uc";
import { sha256, shell_quote as q } from "/usr/libexec/opl-netfleet/adapters/uci.uc";
import { core_service } from "/usr/libexec/opl-netfleet/adapters/native.uc";
const work = ARGV[0];
const ui = trim(fs.readfile(`${work}/ui-path`));
const old = sha256(`${ui}/index.html`);
const identity = sprintf("%J", core_service().service?.instances?.core);
const config = sha256("/etc/config/netfleet");
const runtime = sha256("/etc/opl-netfleet/native/run/config.yaml");
const policy = sha256("/etc/opl-netfleet/policy.json");
const results = {};
function assert(value, name) { if (!value) die(name); results[name] = true; };
function candidate(version, archive) {
	assert(system(`cp ${q(`${work}/${archive}`)} ${q(`${work}/download.zip`)}`) == 0, "fixture_archive");
	const data = { tag_name: version, draft: false, prerelease: false, assets: [{
		name: "dist-cdn-fonts.zip", size: fs.stat(`${work}/download.zip`).size,
		browser_download_url: `https://github.com/Zephyruso/zashboard/releases/download/${version}/dist-cdn-fonts.zip`,
		digest: `sha256:${sha256(`${work}/download.zip`)}` }] };
	fs.writefile(`${work}/release.json`, sprintf("%J", data));
};
assert(resource().managed && resource().available && resource().installed_version == null, "unrecorded_version_is_unknown");
assert(fs.lstat(`${work}/curl-count`) == null, "read_only_without_network");
candidate("v99.1.0", "valid.zip");
assert(check().ok === true && resource().available_version == "v99.1.0", "explicit_upstream_check");
assert(update("v99.0.0").error == "dashboard_candidate_changed" && sha256(`${ui}/index.html`) == old, "stale_candidate_rejected");
fs.writefile(`${work}/fail-download`, "1");
assert(update("v99.1.0").error == "dashboard_download_failed" && sha256(`${ui}/index.html`) == old, "download_failure_preserves_resources");
fs.unlink(`${work}/fail-download`);
fs.writefile(`${work}/download.zip`, "corrupt");
assert(update("v99.1.0").error == "dashboard_asset_mismatch" && sha256(`${ui}/index.html`) == old, "digest_failure_preserves_resources");
candidate("v99.1.0", "link.zip");
assert(check().ok === true && update("v99.1.0").error == "dashboard_archive_invalid" && sha256(`${ui}/index.html`) == old, "archive_links_rejected");
candidate("v99.1.0", "valid.zip");
assert(check().ok === true, "valid_asset_checked");
const installed = update("v99.1.0");
assert(installed.ok === true && resource().installed_version == "v99.1.0" && sha256(`${ui}/index.html`) != old, "resource_update");
const current = sha256(`${ui}/index.html`);
candidate("v99.2.0", "valid.zip");
assert(check().ok === true, "next_asset_checked");
fs.writefile(`${work}/fail-readback`, "1");
const failed = update("v99.2.0");
fs.unlink(`${work}/fail-readback`);
assert(failed.error == "dashboard_readback_failed" && failed.rollback?.ok === true &&
	sha256(`${ui}/index.html`) == current && resource().installed_version == "v99.1.0", "readback_failure_rolls_back");
assert(fs.rename(ui, `${ui}.netfleet-previous`) && fs.mkdir(ui, 0700), "interrupted_fixture");
fs.writefile(`${ui}/index.html`, "interrupted replacement");
candidate("v99.1.0", "valid.zip");
assert(check().ok === true && update("v99.1.0").ok === true && sha256(`${ui}/index.html`) == current &&
	fs.lstat(`${ui}.netfleet-previous`) == null, "interrupted_update_recovered");
fs.writefile(`${work}/fail-check`, "1");
assert(check().error == "dashboard_release_check_failed" && resource().installed_version == "v99.1.0", "check_failure_preserves_installed_version");
assert(identity == sprintf("%J", core_service().service?.instances?.core), "core_process_unchanged");
assert(config == sha256("/etc/config/netfleet") && runtime == sha256("/etc/opl-netfleet/native/run/config.yaml") &&
	policy == sha256("/etc/opl-netfleet/policy.json"), "configuration_unchanged");
printf("%J\n", { ok: true, checks: results });
UCODE
