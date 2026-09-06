#!/bin/sh
set -eu
umask 077
commit=${1:?}
tree=${2:?}

test "$(uname -m)" = aarch64
test "$(readlink /var)" = tmp
apk update >&2
apk add python3 python3-pip libstdcpp libopenssl ca-bundle >&2
export PYTHONPATH=/tmp/compat-runtime/vendor
launcher=/tmp/openwrt/https-compat/files/usr/libexec/opl-netfleet-compat/mitmdump
chmod 0755 "$launcher"
"$launcher" --version >&2
python3 -m pip install --break-system-packages --target /tmp/compat-test-deps hypercorn==0.18.0 httpx==0.28.1 >&2
export PYTHONPATH=/tmp/compat-runtime/vendor:/tmp/compat-test-deps
export PATH=/tmp/openwrt/https-compat/files/usr/libexec/opl-netfleet-compat:$PATH
python3 /tmp/tests/https_compat_protocol.py >&2
du -sk /tmp/compat-runtime/vendor >&2
python3 - "$commit" "$tree" <<'PY'
import json, sys
print(json.dumps({"ok": True, "source_commit": sys.argv[1], "source_tree": sys.argv[2],
                  "checks": {"musl_runtime": True, "protocol_wire": True}, "production_ready": False}))
PY
