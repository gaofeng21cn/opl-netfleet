#!/bin/sh
# Run only in a disposable root-owned Linux/OpenWrt fixture. Package and
# lifecycle commands are simulated; filesystem, JSON, hashes and locks are real.
set -eu
guard=${1:?guard script required}
test "$(id -u)" = 0
fixture=$(mktemp -d /tmp/netfleet-guard-regression.XXXXXX)
GUARD_FIXTURE_ID=$(tr -d '-' </proc/sys/kernel/random/uuid)
export GUARD_FIXTURE_ID
GUARD_FIXTURE_TRANSACTION=/etc/opl-netfleet/package-transactions/$GUARD_FIXTURE_ID
export GUARD_FIXTURE_TRANSACTION
trap 'rm -rf "$fixture" "$GUARD_FIXTURE_TRANSACTION"' EXIT
mkdir "$fixture/bin"
cat >"$fixture/bin/jsonfilter" <<'SH'
#!/bin/sh
if [ "$2" = /etc/opl-netfleet/package-transactions/request.json ]; then
 printf '%s\n' "$GUARD_FIXTURE_ID"
else exec /usr/bin/jsonfilter "$@"; fi
SH
cat >"$fixture/bin/apk" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$FIXTURE/calls"
case "$*" in
 *verify*) exit 0 ;;
 *query*) cat "$FIXTURE/installed.json" ;;
 *add*) [ "${FAIL_INSTALL:-0}" = 0 ] || exit 1
        printf '[{"name":"opl-netfleet-https-compat","version":"0.6.6"}]\n' >"$FIXTURE/installed.json" ;;
 *) exit 1 ;;
esac
SH
cat >"$fixture/bin/pidof" <<'SH'
#!/bin/sh
printf '%s\n' 123
SH
cat >"$fixture/bin/ucode" <<'SH'
#!/bin/sh
if [ "$1" = "$GUARD_FIXTURE_TRANSACTION/code/plugins/components/recover.uc" ]; then
 printf '%s\n' "$*" >>"$FIXTURE/calls"
 [ "${FAIL_INSTALL:-0}" = 0 ] || exit 1
 printf '[{"name":"opl-netfleet-https-compat","version":"0.6.6"}]\n' >"$FIXTURE/installed.json"
 printf '{"phase":"rolled_back"}\n' >"$GUARD_FIXTURE_TRANSACTION/journal.json"
 printf '{"ok":true}\n'
elif [ "$1" = /usr/libexec/opl-netfleet/main.uc ]; then
 printf '%s\n' "$*" >>"$FIXTURE/calls"
 case "$2" in
  plugin-package-drain) printf '{"ok":true}\n' ;;
  compatibility-get) printf '{"ok":true,"result":{"intercepting":true}}\n' ;;
  *) exit 1 ;;
 esac
else exec /usr/bin/ucode "$@"; fi
SH
cat >"$fixture/bin/date" <<'SH'
#!/bin/sh
cat "$FIXTURE/clock"
SH
cat >"$fixture/bin/sleep" <<'SH'
#!/bin/sh
clock=$(cat "$FIXTURE/clock")
printf '%s\n' "$((clock+10))" >"$FIXTURE/clock"
[ "${FIX_ACCEPTANCE:-0}" != 1 ] || cp "$FIXTURE/accepted.json" "$FIXTURE/canary-accepted.json"
SH
chmod 0755 "$fixture/bin/"*
export PATH="$fixture/bin:$PATH"
new_case() {
 export FIXTURE="$fixture/$1" FIX_ACCEPTANCE=0 FAIL_INSTALL=0
 mkdir -m 0700 "$FIXTURE" "$FIXTURE/old" "$FIXTURE/new"
 printf old >"$FIXTURE/old/opl-netfleet-https-compat-0.6.6.apk"
 printf new >"$FIXTURE/new/opl-netfleet-https-compat-0.6.9.apk"
 printf private >"$FIXTURE/private"
 printf runtime >"$FIXTURE/runtime"
 sha256sum "$FIXTURE/private" >"$FIXTURE/private.sha256"
 sha256sum "$FIXTURE/runtime" >"$FIXTURE/new-runtime.sha256"
 printf '0\n' >"$FIXTURE/clock"
 printf '[{"name":"opl-netfleet-https-compat","version":"0.6.9"}]\n' >"$FIXTURE/installed.json"
 /usr/bin/ucode - "$FIXTURE" <<'UC'
import * as fs from 'fs';import {sha256} from 'digest';
const dir=ARGV[0];
function artifact(version) {
 const file='opl-netfleet-https-compat-'+version+'.apk',key=version=='0.6.6'?'old':'new';
 return {version,artifact:file,sha256:sha256(fs.readfile(dir+'/'+key+'/'+file))};
}
const old=artifact('0.6.6'),candidate=artifact('0.6.9');
fs.writefile(dir+'/rollback.json',sprintf('%J',{package:'opl-netfleet-https-compat',timeout_seconds:30,
 core_pid:'123',intercepting:true,old,new:candidate}));
fs.writefile(dir+'/accepted.json',sprintf('%J',{accepted:true,business:true,sha256:candidate.sha256}));
UC
 mkdir -p "$GUARD_FIXTURE_TRANSACTION/old" "$GUARD_FIXTURE_TRANSACTION/new"
 cp "$FIXTURE/old/"*.apk "$GUARD_FIXTURE_TRANSACTION/old/"
 cp "$FIXTURE/new/"*.apk "$GUARD_FIXTURE_TRANSACTION/new/"
 printf '{"phase":"complete","names":["opl-netfleet-https-compat"],"before":{"runtime_retained":true},"versions":{"opl-netfleet-https-compat":"0.6.6"},"candidates":{"opl-netfleet-https-compat":"0.6.9"}}\n' >"$GUARD_FIXTURE_TRANSACTION/journal.json"
}
assert_state() { test "$(jsonfilter -i "$FIXTURE/guard-state.json" -e '@.state')" = "$1"; }
assert_no_install() { ! sed -n '/ rollback /p' "$FIXTURE/calls" | sed -n '1p' | read -r ignored; }

new_case preflight
sh "$guard" "$FIXTURE" validate
test ! -e "$FIXTURE/guard-state.json"
assert_no_install

new_case stale_snapshot
sed -i 's/"123"/"124"/' "$FIXTURE/rollback.json"
if sh "$guard" "$FIXTURE" guard; then exit 1; fi
assert_state recovery_failed
assert_no_install

new_case malformed_acceptance
printf '{"accepted":true}\\n' >"$FIXTURE/canary-accepted.json"
sh "$guard" "$FIXTURE" guard
assert_state restored
test "$(cat "$FIXTURE/clock")" = 30
test "$(jsonfilter -i "$FIXTURE/installed.json" -e '@[0].version')" = 0.6.6

new_case corrected_acceptance
printf '{' >"$FIXTURE/canary-accepted.json"
export FIX_ACCEPTANCE=1
sh "$guard" "$FIXTURE" guard
assert_state accepted
assert_no_install

new_case valid_acceptance
cp "$FIXTURE/accepted.json" "$FIXTURE/canary-accepted.json"
sh "$guard" "$FIXTURE" guard
assert_state accepted
assert_no_install

new_case failed_install
export FAIL_INSTALL=1
if sh "$guard" "$FIXTURE" guard; then exit 1; fi
assert_state recovery_failed
printf '%s\n' 'HTTPS guard: preflight, stale snapshot, malformed/corrected/valid acceptance, and failed restore passed (simulated package boundary)'
