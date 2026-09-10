# Sourced by https_native_network.sh in a disposable migration VM only.
# The host stages verified old/new APKs and the signed upstream indexes with
# their dependency archives. Nothing is downloaded during the transaction.
test -f /tmp/netfleet-compat-vm-authorized
test -d "$upgrade/old"
test -d "$upgrade/new"
test -d "$upgrade/dependencies"
stage=old_native_migration
sha256sum /etc/opl-netfleet/compatibility/ca/mitmproxy-ca.pem >"$work/migration-ca.sha256"
package_transaction() {
    (
        exec 9>/var/lock/opl-netfleet-deploy.lock
        flock -w 10 9
        apk "$@" 9>&-
    )
}
new_backend=$(find "$upgrade/new" -name 'opl-netfleet-plugin-mihomo-*.apk')
test -f "$new_backend"
# A backend-only update must reject the older platform before running hooks.
if apk --no-network --repositories-file /dev/null --simulate add "$new_backend" >"$work/dependency-rejection.log" 2>&1; then exit 1; fi
test "$(pidof mihomo)" = "$base_pid"
package_transaction --no-network --repositories-file /dev/null add \
    "$upgrade/new"/opl-netfleet-plugin-platform-*.apk "$new_backend" >"$work/migration-backend.log" 2>&1
for attempt in $(seq 1 30); do
    ucode /usr/libexec/opl-netfleet/main.uc native-gateway-status >"$work/gateway.json"
    [ "$(jsonfilter -i "$work/gateway.json" -e '@.result.ready')" != true ] || break
    sleep 1
done
test "$(jsonfilter -i "$work/gateway.json" -e '@.result.ready')" = true
base_pid=$(pidof mihomo)
test -n "$base_pid"
optional_install() {
    package_transaction --no-network --repositories-file /dev/null \
        -X "$upgrade/dependencies/base.adb" -X "$upgrade/dependencies/packages.adb" add \
        "$1"/opl-netfleet-plugin-https-compat-*.apk \
        "$1"/opl-netfleet-https-compat-*.apk \
        "$1"/opl-netfleet-plugin-device-identity-*.apk
}
preserved() {
    test "$(pidof mihomo)" = "$base_pid"
    sha256sum -c "$work/base.sha256"
    sha256sum -c "$work/migration-ca.sha256"
    probe 4 http/1.1
    probe 6 http/1.1
}
optional_install "$upgrade/new" >"$work/migration-install.log" 2>&1
preserved
# Model a failed post-install acceptance: restore only the optional packages.
# Keep the already-qualified native backend alive throughout the rollback.
optional_install "$upgrade/old" >"$work/migration-rollback.log" 2>&1
preserved
optional_install "$upgrade/new" >"$work/migration-retry.log" 2>&1
preserved
! command -v python3 >/dev/null
ucode /tmp/tests/https_native_guest.uc load >>"$work/migration-retry.log" 2>&1
printf '%s\n' 'native migration: old packages -> native, offline optional rollback, retry, stable CA and base path passed'
