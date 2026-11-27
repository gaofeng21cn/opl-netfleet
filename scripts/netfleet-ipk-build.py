#!/usr/bin/env python3
"""Zero-SDK deterministic .ipk, OPKG feed (Packages.gz + usign), and Release Bundle builder."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SEMVER_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")


def _load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load module from {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _tar_gz_from_fs(root: Path, *, mode_overrides: dict[str, int] | None = None) -> tuple[bytes, int]:
    """Build deterministic ./-prefixed GNU tar.gz matching OpenWrt ipkg-build.

    Returns (compressed_tar_gz_bytes, uncompressed_tar_bytes_len).
    """
    tar_buf = io.BytesIO()
    with tarfile.open(fileobj=tar_buf, mode="w", format=tarfile.GNU_FORMAT) as tf:
        root_info = tarfile.TarInfo(name="./")
        root_info.type = tarfile.DIRTYPE
        root_info.mode = 0o755
        root_info.uid = 0
        root_info.gid = 0
        root_info.uname = "root"
        root_info.gname = "root"
        root_info.mtime = 0
        tf.addfile(root_info)

        items: list[Path] = []

        def walk(parent: Path) -> None:
            for child in sorted(parent.iterdir(), key=lambda p: p.name):
                items.append(child)
                if child.is_dir() and not child.is_symlink():
                    walk(child)

        walk(root)
        for item in items:
            rel = "./" + item.relative_to(root).as_posix()
            info = tarfile.TarInfo(name=rel)
            info.uid = 0
            info.gid = 0
            info.uname = "root"
            info.gname = "root"
            info.mtime = 0
            if item.is_symlink():
                info.type = tarfile.SYMTYPE
                info.linkname = os.readlink(item)
                info.mode = 0o777
                tf.addfile(info)
            elif item.is_dir():
                info.type = tarfile.DIRTYPE
                info.mode = 0o755
                tf.addfile(info)
            elif item.is_file():
                info.type = tarfile.REGTYPE
                if mode_overrides and item.relative_to(root).as_posix() in mode_overrides:
                    info.mode = mode_overrides[item.relative_to(root).as_posix()]
                else:
                    info.mode = 0o755 if (item.lstat().st_mode & 0o111) else 0o644
                data = item.read_bytes()
                info.size = len(data)
                tf.addfile(info, io.BytesIO(data))
            else:
                raise ValueError(f"unsupported file in ipk tree: {item}")

    raw_tar = tar_buf.getvalue()
    gz_buf = io.BytesIO()
    with gzip.GzipFile(fileobj=gz_buf, mode="wb", mtime=0, compresslevel=9) as gz:
        gz.write(raw_tar)
    return gz_buf.getvalue(), len(raw_tar)


def _assemble_ipk(data_dir: Path, control_fields: dict[str, str], scripts: dict[str, str], out_ipk: Path) -> dict[str, object]:
    """Assemble a deterministic OpenWrt .ipk (gzipped GNU tar of debian-binary, data.tar.gz, control.tar.gz)."""
    data_gz, installed_size = _tar_gz_from_fs(data_dir)
    fields = dict(control_fields)
    fields["Installed-Size"] = str(installed_size)

    order = [
        "Package", "Version", "Depends", "Provides", "Conflicts", "Replaces",
        "Alternatives", "Source", "SourceName", "License", "Section", "Category",
        "Architecture", "Maintainer", "Installed-Size", "Description",
    ]
    lines: list[str] = []
    for key in order:
        val = fields.get(key)
        if not val:
            continue
        if key == "Description":
            lines.append(f"Description: {val}")
        else:
            lines.append(f"{key}: {val}")
    control_text = "\n".join(lines) + "\n"

    with tempfile.TemporaryDirectory(prefix="netfleet-ipk-ctl-") as ctl_tmp:
        ctl_dir = Path(ctl_tmp)
        (ctl_dir / "control").write_text(control_text, encoding="utf-8")
        mode_map = {"control": 0o644}
        for name, content in scripts.items():
            if not content:
                continue
            (ctl_dir / name).write_text(content, encoding="utf-8")
            mode_map[name] = 0o755
        control_gz, _ = _tar_gz_from_fs(ctl_dir, mode_overrides=mode_map)

    outer_buf = io.BytesIO()
    with tarfile.open(fileobj=outer_buf, mode="w", format=tarfile.GNU_FORMAT) as outer:
        for member_name, member_bytes in (
            ("./debian-binary", b"2.0\n"),
            ("./data.tar.gz", data_gz),
            ("./control.tar.gz", control_gz),
        ):
            info = tarfile.TarInfo(name=member_name)
            info.type = tarfile.REGTYPE
            info.mode = 0o644
            info.uid = 0
            info.gid = 0
            info.uname = "root"
            info.gname = "root"
            info.mtime = 0
            info.size = len(member_bytes)
            outer.addfile(info, io.BytesIO(member_bytes))

    ipk_gz_buf = io.BytesIO()
    with gzip.GzipFile(fileobj=ipk_gz_buf, mode="wb", mtime=0, compresslevel=9) as gz:
        gz.write(outer_buf.getvalue())
    ipk_bytes = ipk_gz_buf.getvalue()
    out_ipk.parent.mkdir(parents=True, exist_ok=True)
    out_ipk.write_bytes(ipk_bytes)
    out_ipk.chmod(0o644)

    sha = hashlib.sha256(ipk_bytes).hexdigest()
    stanza_lines = [line for line in lines]
    stanza_lines.insert(-1, f"Filename: {out_ipk.name}")
    stanza_lines.insert(-1, f"Size: {len(ipk_bytes)}")
    stanza_lines.insert(-1, f"SHA256sum: {sha}")
    return {
        "package": fields["Package"],
        "version": fields["Version"],
        "arch": fields["Architecture"],
        "name": out_ipk.name,
        "size": len(ipk_bytes),
        "sha256": sha,
        "stanza": "\n".join(stanza_lines) + "\n",
    }


def _copy_file(src: Path, dst: Path, mode: int) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(src, dst)
    dst.chmod(mode)


def _shell_scripts(version: str) -> dict[str, str]:
    preinst = """#!/bin/sh
[ -z "${IPKG_INSTROOT:-}" ] || exit 0
main=/usr/libexec/opl-netfleet/main.uc
upgrade_state=/tmp/opl-netfleet-package-upgrade-state
run_step() {
\tlabel="$1"; shift
\tout=$("$@" 2>&1) && return 0
\trc=$?
\tprintf 'opl-netfleet preinst: %s failed (exit %s): %s\\n' "$label" "$rc" "$out" >&2
\treturn "$rc"
}
stop_netfleet() {
\tif [ -x /etc/init.d/opl-netfleet ] && /etc/init.d/opl-netfleet running >/dev/null 2>&1; then
\t\trun_step "opl-netfleet stop" /etc/init.d/opl-netfleet stop || return 1
\telif [ -x /etc/init.d/opl-netfleet ]; then
\t\t/etc/init.d/opl-netfleet stop >/dev/null 2>&1 || true
\tfi
}
stop_core() {
\t[ -x /etc/init.d/opl-netfleet-core ] || return 0
\tif /etc/init.d/opl-netfleet-core running >/dev/null 2>&1; then
\t\trun_step "opl-netfleet-core stop" /etc/init.d/opl-netfleet-core stop || return 1
\telse
\t\t/etc/init.d/opl-netfleet-core stop >/dev/null 2>&1 || return 1
\tfi
}
is_upgrade=0
[ "${PKG_UPGRADE:-0}" != 1 ] || is_upgrade=1
[ "${1:-}" != upgrade ] || is_upgrade=1
[ "$is_upgrade" = 1 ] || exit 0
[ ! -e "$upgrade_state" ] || {
\tprintf '%s\\n' 'opl-netfleet: previous package state restoration is incomplete' >&2
\texit 1
}
backend=nikki-mihomo
if [ -e /etc/opl-netfleet/backend.json ]; then
\tbackend=$(jsonfilter -i /etc/opl-netfleet/backend.json -e '@.kind') || {
\t\tprintf '%s\\n' 'opl-netfleet preinst: failed to read backend.json' >&2
\t\texit 1
\t}
fi
case "$backend" in nikki-mihomo|native-mihomo) ;; *)
\tprintf 'opl-netfleet preinst: invalid backend %s\\n' "$backend" >&2
\texit 1
;; esac
enabled=0; running=0; core_enabled=0; core_running=0
if [ -x /etc/init.d/opl-netfleet ]; then
\t/etc/init.d/opl-netfleet enabled >/dev/null 2>&1 && enabled=1 || true
\t/etc/init.d/opl-netfleet running >/dev/null 2>&1 && running=1 || true
fi
if [ "$backend" = native-mihomo ] && [ -x /etc/init.d/opl-netfleet-core ]; then
\t/etc/init.d/opl-netfleet-core enabled >/dev/null 2>&1 && core_enabled=1 || true
\t/etc/init.d/opl-netfleet-core running >/dev/null 2>&1 && core_running=1 || true
fi
umask 077
printf '%s %s %s %s %s\\n' "$backend" "$enabled" "$running" "$core_enabled" "$core_running" >"$upgrade_state" || {
\tprintf '%s\\n' 'opl-netfleet preinst: cannot write upgrade state' >&2
\texit 1
}
stop_netfleet || exit 1
if [ "$backend" = native-mihomo ]; then
\tstop_core || exit 1
fi
for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
\tif [ ! -x /etc/init.d/opl-netfleet ] || ! /etc/init.d/opl-netfleet running >/dev/null 2>&1; then
\t\tif [ "$backend" != native-mihomo ]; then
\t\t\texit 0
\t\tfi
\t\tcore_status=$(ucode "$main" native-gateway-status) || {
\t\t\tprintf 'opl-netfleet preinst: native-gateway-status failed: %s\\n' "$core_status" >&2
\t\t\texit 1
\t\t}
\t\tstopped=$(printf '%s' "$core_status" | jsonfilter -e '@.result.core_running')
\t\tclean=$(printf '%s' "$core_status" | jsonfilter -e '@.result.clean')
\t\t[ "$stopped" != false ] || [ "$clean" != true ] || exit 0
\tfi
\tsleep 1
done
printf '%s\\n' 'opl-netfleet: old processes did not stop before upgrade' >&2
exit 1
"""
    postinst = f"""#!/bin/sh
[ -z "${{IPKG_INSTROOT:-}}" ] || exit 0
run_step() {{
\tlabel="$1"; shift
\tout=$("$@" 2>&1) && return 0
\trc=$?
\tprintf 'opl-netfleet postinst: %s failed (exit %s): %s\\n' "$label" "$rc" "$out" >&2
\treturn "$rc"
}}
bundle_root=/usr/share/opl-netfleet
release_dir="releases/{version}"
run_step "mkdir bundle dirs" mkdir -p "$bundle_root/releases" /usr/libexec/opl-netfleet/plugins /etc/opl-netfleet/extensions || exit 1
ucode -e '
\timport * as fs from "fs";
\tconst root = ARGV[0], ver = ARGV[1], rel = ARGV[2];
\tfunction swap(link_path, target) {{
\t\tconst parent = fs.dirname(link_path);
\t\tconst tmp = parent + "/." + fs.basename(link_path) + ".next";
\t\tfs.unlink(tmp);
\t\tif (!fs.symlink(target, tmp) || !fs.rename(tmp, link_path)) {{ fs.unlink(tmp); die("symlink_failed:" + link_path); }}
\t}}
\tfunction ver_ge(a, b) {{
\t\tif (b == null) return true;
\t\tconst pa = split(a, "."), pb = split(b, ".");
\t\tif (length(pa) != 3 || length(pb) != 3) return true;
\t\tfor (let i = 0; i < 3; i++) {{
\t\t\tif (int(pa[i]) != int(pb[i])) return int(pa[i]) > int(pb[i]);
\t\t}}
\t\treturn true;
\t}}
\tconst cur = fs.readlink(root + "/current");
\tlet cur_ver = null;
\ttry {{ cur_ver = json(fs.readfile(root + "/current/share/build.json")).version; }} catch (e) {{}}
\tif (cur == null || fs.stat(root + "/current/runtime") == null || ver_ge(ver, cur_ver)) {{
\t\tif (cur != null && cur != rel && fs.stat(root + "/" + cur + "/share/build.json") != null)
\t\t\tswap(root + "/previous", cur);
\t\tswap(root + "/current", rel);
\t}}
\tfor (let name in ["system.json", "build.json", "nikki", "netfleet.config", "LICENSE.Apache-2.0"]) {{
\t\tconst p = root + "/" + name;
\t\tconst st = fs.lstat(p);
\t\tif (st != null && st.type != "link") {{
\t\t\tif (st.type == "directory") system("rm -rf " + p);
\t\t\telse fs.unlink(p);
\t\t}}
\t\tswap(p, "current/share/" + name);
\t}}
' "$bundle_root" "{version}" "$release_dir" || exit 1
main=/usr/libexec/opl-netfleet/main.uc
upgrade_state=/tmp/opl-netfleet-package-upgrade-state
stop_netfleet() {{
\tif [ -x /etc/init.d/opl-netfleet ] && /etc/init.d/opl-netfleet running >/dev/null 2>&1; then
\t\trun_step "opl-netfleet stop" /etc/init.d/opl-netfleet stop || true
\telif [ -x /etc/init.d/opl-netfleet ]; then
\t\t/etc/init.d/opl-netfleet stop >/dev/null 2>&1 || true
\tfi
\tfor attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
\t\tif [ ! -x /etc/init.d/opl-netfleet ] || ! /etc/init.d/opl-netfleet running >/dev/null 2>&1; then
\t\t\treturn 0
\t\tfi
\t\tsleep 1
\tdone
\tprintf '%s\\n' 'opl-netfleet postinst: service remained running after stop' >&2
\treturn 1
}}
stop_core() {{
\t[ -x /etc/init.d/opl-netfleet-core ] || return 0
\tif /etc/init.d/opl-netfleet-core running >/dev/null 2>&1; then
\t\trun_step "opl-netfleet-core stop" /etc/init.d/opl-netfleet-core stop || return 1
\telse
\t\t/etc/init.d/opl-netfleet-core stop >/dev/null 2>&1 || return 1
\tfi
}}
is_upgrade=0
[ "${{PKG_UPGRADE:-0}}" != 1 ] || is_upgrade=1
[ ! -s "$upgrade_state" ] || is_upgrade=1
if [ "$is_upgrade" != 1 ]; then
\tstop_netfleet || exit 1
\trun_step "opl-netfleet disable" /etc/init.d/opl-netfleet disable || exit 1
\tstop_core || exit 1
\trun_step "opl-netfleet-core disable" /etc/init.d/opl-netfleet-core disable || exit 1
\trm -f "$upgrade_state"
elif [ -s "$upgrade_state" ]; then
\tread -r backend was_enabled was_running core_enabled core_running <"$upgrade_state"
\tif [ "$backend" = native-mihomo ]; then
\t\tif [ "$core_enabled" = 1 ]; then
\t\t\trun_step "opl-netfleet-core enable" /etc/init.d/opl-netfleet-core enable || exit 1
\t\telse
\t\t\trun_step "opl-netfleet-core disable" /etc/init.d/opl-netfleet-core disable || exit 1
\t\tfi
\t\tif [ "$core_running" = 1 ]; then
\t\t\tNETFLEET_PACKAGE_RESTORE=1 run_step "opl-netfleet-core restart" /etc/init.d/opl-netfleet-core restart || exit 1
\t\t\tcore_ready=0
\t\t\tcore_status=
\t\t\tfor attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
\t\t\t\tcore_status=$(ucode "$main" native-gateway-status 2>&1 || true)
\t\t\t\tif [ "$(printf '%s' "$core_status" | jsonfilter -e '@.result.ready' 2>/dev/null || true)" = true ]; then
\t\t\t\t\tcore_ready=1
\t\t\t\t\tbreak
\t\t\t\tfi
\t\t\t\tsleep 1
\t\t\tdone
\t\t\t[ "$core_ready" = 1 ] || {{
\t\t\t\tprintf 'opl-netfleet postinst: native gateway not ready: %s\\n' "$core_status" >&2
\t\t\t\texit 1
\t\t\t}}
\t\telse
\t\t\tstop_core || exit 1
\t\tfi
\telse
\t\tstop_core || exit 1
\t\trun_step "opl-netfleet-core disable" /etc/init.d/opl-netfleet-core disable || exit 1
\tfi
\tif [ "$was_enabled" = 1 ]; then
\t\trun_step "opl-netfleet enable" /etc/init.d/opl-netfleet enable || exit 1
\telse
\t\trun_step "opl-netfleet disable" /etc/init.d/opl-netfleet disable || exit 1
\tfi
\tif [ "$was_running" = 1 ]; then
\t\tNETFLEET_PACKAGE_RESTORE=1 run_step "opl-netfleet restart" /etc/init.d/opl-netfleet restart || exit 1
\t\tnetfleet_running=0
\t\tfor attempt in 1 2 3 4 5 6 7 8 9 10; do
\t\t\tif /etc/init.d/opl-netfleet running >/dev/null 2>&1; then
\t\t\t\tnetfleet_running=1
\t\t\t\tbreak
\t\t\tfi
\t\t\tsleep 1
\t\tdone
\t\t[ "$netfleet_running" = 1 ] || {{
\t\t\tprintf 'opl-netfleet postinst: service failed to remain running after restart\\n' >&2
\t\t\texit 1
\t\t}}
\telse
\t\tstop_netfleet || exit 1
\tfi
\trm -f "$upgrade_state"
else
\tprintf '%s\\n' 'opl-netfleet: package upgrade state is missing' >&2
\texit 1
fi
[ ! -x /etc/init.d/rpcd ] || /etc/init.d/rpcd restart >/dev/null 2>&1 || true
exit 0
"""
    prerm = """#!/bin/sh
[ -z "${IPKG_INSTROOT:-}" ] || exit 0
[ "${PKG_UPGRADE:-0}" != 1 ] && [ "${1:-}" != upgrade ] || exit 0
main=/usr/libexec/opl-netfleet/main.uc
run_step() {
\tlabel="$1"; shift
\tout=$("$@" 2>&1) && return 0
\trc=$?
\tprintf 'opl-netfleet prerm: %s failed (exit %s): %s\\n' "$label" "$rc" "$out" >&2
\treturn "$rc"
}
stop_netfleet() {
\tif [ -x /etc/init.d/opl-netfleet ] && /etc/init.d/opl-netfleet running >/dev/null 2>&1; then
\t\trun_step "opl-netfleet stop" /etc/init.d/opl-netfleet stop || return 1
\telif [ -x /etc/init.d/opl-netfleet ]; then
\t\t/etc/init.d/opl-netfleet stop >/dev/null 2>&1 || true
\tfi
}
stop_core() {
\t[ -x /etc/init.d/opl-netfleet-core ] || return 0
\tif /etc/init.d/opl-netfleet-core running >/dev/null 2>&1; then
\t\trun_step "opl-netfleet-core stop" /etc/init.d/opl-netfleet-core stop || return 1
\telse
\t\t/etc/init.d/opl-netfleet-core stop >/dev/null 2>&1 || true
\t\t[ ! -x "$main" ] || run_step "native-gateway-cleanup" ucode "$main" native-gateway-cleanup || return 1
\tfi
}
backend=nikki-mihomo
if [ -e /etc/opl-netfleet/backend.json ]; then
\tbackend=$(jsonfilter -i /etc/opl-netfleet/backend.json -e '@.kind') || {
\t\tprintf '%s\\n' 'opl-netfleet prerm: failed to read backend.json' >&2
\t\texit 1
\t}
fi
if [ "$backend" = native-mihomo ]; then
\tstop_netfleet || exit 1
\t[ ! -x /etc/init.d/opl-netfleet ] || run_step "opl-netfleet disable" /etc/init.d/opl-netfleet disable || exit 1
\tif uci -q get netfleet.config >/dev/null 2>&1; then
\t\tuci set netfleet.config.enabled=0 && uci commit netfleet || {
\t\t\tprintf '%s\\n' 'opl-netfleet prerm: failed to disable uci config' >&2
\t\t\texit 1
\t\t}
\tfi
\t[ ! -x /etc/init.d/opl-netfleet-core ] || run_step "opl-netfleet-core disable" /etc/init.d/opl-netfleet-core disable || exit 1
\tstop_core || exit 1
\tfor attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
\t\tcore_status=$(ucode "$main" native-gateway-status) || {
\t\t\tprintf 'opl-netfleet prerm: native-gateway-status failed: %s\\n' "$core_status" >&2
\t\t\texit 1
\t\t}
\t\tcore_running=$(printf '%s' "$core_status" | jsonfilter -e '@.result.core_running')
\t\tcore_clean=$(printf '%s' "$core_status" | jsonfilter -e '@.result.clean')
\t\t[ "$core_running" != false ] || [ "$core_clean" != true ] || break
\t\tsleep 1
\tdone
\t[ "${core_running:-true}" = false ] && [ "${core_clean:-false}" = true ] || {
\t\tprintf '%s\\n' 'opl-netfleet: native core cleanup unconfirmed; refusing removal' >&2
\t\texit 1
\t}
\texit 0
fi
if [ ! -e /etc/config/nikki ] && [ ! -e /etc/init.d/nikki ]; then
\tstop_netfleet || true
\t[ ! -x /etc/init.d/opl-netfleet ] || /etc/init.d/opl-netfleet disable >/dev/null 2>&1 || true
\texit 0
fi
active_profile=$(uci -q get nikki.config.profile 2>/dev/null) || {
\tprintf '%s\\n' 'opl-netfleet: cannot inspect Nikki profile; refusing removal' >&2
\texit 1
}
is_netfleet_profile() {
\t[ "$1" = "file:OPL-NetFleet.json" ] || [ "$1" = "file:opl-netfleet/mvp.json" ]
}
if [ -x "$main" ]; then
\tif ! ucode "$main" disable >/dev/null; then
\t\tprintf '%s\\n' 'opl-netfleet: disable/readback failed; refusing removal' >&2
\t\texit 1
\tfi
elif is_netfleet_profile "$active_profile"; then
\tprintf '%s\\n' 'opl-netfleet: active profile but runtime is unavailable; refusing removal' >&2
\texit 1
fi
active_profile=$(uci -q get nikki.config.profile 2>/dev/null) || exit 1
! is_netfleet_profile "$active_profile" || {
\tprintf '%s\\n' 'opl-netfleet: NetFleet profile remains active; refusing removal' >&2
\texit 1
}
[ ! -x /etc/init.d/opl-netfleet ] || /etc/init.d/opl-netfleet stop >/dev/null 2>&1 || true
[ ! -x /etc/init.d/opl-netfleet ] || /etc/init.d/opl-netfleet disable >/dev/null 2>&1 || true
if [ -x "$main" ] && ! ucode "$main" package-cleanup >/dev/null; then
\tprintf '%s\\n' 'opl-netfleet: generated artifact cleanup failed; refusing removal' >&2
\texit 1
fi
exit 0
"""
    postrm = """#!/bin/sh
[ -z "${IPKG_INSTROOT:-}" ] || exit 0
[ "${PKG_UPGRADE:-0}" != 1 ] && [ "${1:-}" != upgrade ] || exit 0
rm -f /usr/share/opl-netfleet/current /usr/share/opl-netfleet/previous \
\t/usr/share/opl-netfleet/system.json /usr/share/opl-netfleet/build.json \
\t/usr/share/opl-netfleet/nikki /usr/share/opl-netfleet/netfleet.config
rm -rf /usr/share/opl-netfleet/releases /var/run/opl-netfleet-plugin-maintenance \
\t/var/lock/opl-netfleet-code /tmp/opl-netfleet-plugin-inspection
[ ! -x /etc/init.d/rpcd ] || /etc/init.d/rpcd restart >/dev/null 2>&1 || true
exit 0
"""
    return {"preinst": preinst, "postinst": postinst, "prerm": prerm, "postrm": postrm}


def _luci_postinst() -> str:
    return """#!/bin/sh
[ -z "${IPKG_INSTROOT:-}" ] || exit 0
changed=0
rpcd_timeout=$(uci -q get 'rpcd.@rpcd[0].timeout' 2>/dev/null || true)
case "$rpcd_timeout" in
\t''|*[!0-9]*) uci set 'rpcd.@rpcd[0].timeout=300' || exit 1; changed=1 ;;
\t*) [ "$rpcd_timeout" -ge 300 ] || { uci set 'rpcd.@rpcd[0].timeout=300' || exit 1; changed=1; } ;;
esac
uhttpd_timeout=$(uci -q get 'uhttpd.main.script_timeout' 2>/dev/null || true)
case "$uhttpd_timeout" in
\t''|*[!0-9]*) uci set 'uhttpd.main.script_timeout=300' || exit 1; changed=1 ;;
\t*) [ "$uhttpd_timeout" -ge 300 ] || { uci set 'uhttpd.main.script_timeout=300' || exit 1; changed=1; } ;;
esac
if [ "$changed" = 1 ]; then
\tuci commit rpcd && uci commit uhttpd || {
\t\tprintf '%s\\n' 'luci-app-netfleet: cannot configure RPC execution timeout' >&2
\t\texit 1
\t}
fi
rm -f /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/
[ ! -x /etc/init.d/rpcd ] || /etc/init.d/rpcd restart >/dev/null 2>&1 || true
[ "$changed" = 1 ] || exit 0
[ ! -x /etc/init.d/uhttpd ] || /etc/init.d/uhttpd restart >/dev/null 2>&1 || true
exit 0
"""


def _luci_postrm() -> str:
    return """#!/bin/sh
[ -z "${IPKG_INSTROOT:-}" ] || exit 0
[ "${PKG_UPGRADE:-0}" != 1 ] && [ "${1:-}" != upgrade ] || exit 0
rm -f /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/
[ ! -x /etc/init.d/rpcd ] || /etc/init.d/rpcd restart >/dev/null 2>&1 || true
[ ! -x /etc/init.d/uhttpd ] || /etc/init.d/uhttpd restart >/dev/null 2>&1 || true
exit 0
"""


def _mihomo_scripts() -> dict[str, str]:
    postinst = """#!/bin/sh
[ -z "${IPKG_INSTROOT:-}" ] || exit 0
mkdir -p /usr/bin
if [ ! -e /usr/bin/mihomo ] || [ -L /usr/bin/mihomo ]; then
\tln -sf /usr/libexec/mihomo /usr/bin/mihomo || exit 1
fi
exit 0
"""
    postrm = """#!/bin/sh
[ -z "${IPKG_INSTROOT:-}" ] || exit 0
[ "${PKG_UPGRADE:-0}" != 1 ] && [ "${1:-}" != upgrade ] || exit 0
if [ -L /usr/bin/mihomo ] && [ "$(readlink /usr/bin/mihomo 2>/dev/null || true)" = /usr/libexec/mihomo ]; then
\trm -f /usr/bin/mihomo
fi
exit 0
"""
    return {"postinst": postinst, "postrm": postrm}


def _resolve_mihomo_asset(repo: Path, source: dict[str, object], explicit: Path | None) -> bytes:
    cache_dir = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "opl-netfleet/openwrt-vm"
    candidates = [p for p in (explicit, cache_dir / str(source["filename"])) if p is not None and p.is_file()]
    if candidates:
        raw_gz = candidates[0].read_bytes()
        if hashlib.sha256(raw_gz).hexdigest() != source["sha256"]:
            raise ValueError(f"mihomo asset sha256 mismatch: {candidates[0]}")
        return gzip.decompress(raw_gz)
    raise FileNotFoundError(
        f"cached upstream mihomo archive not found at {cache_dir / str(source['filename'])}; pass --mihomo-asset or fetch into VM cache"
    )


def build_ipk_feed(
    repo: Path,
    output_dir: Path,
    *,
    version: str | None = None,
    min_shell_version: str | None = None,
    channel: str = "stable",
    core_arch: str = "aarch64_generic",
    skip_core: bool = False,
    mihomo_asset: Path | None = None,
    sign_key: Path | None = None,
    merge_manifest: bool = False,
    source_commit: str | None = None,
    source_tree: str | None = None,
) -> dict[str, object]:
    repo = repo.resolve()
    output_dir = output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    usign = _load_module("netfleet_usign", repo / "scripts/netfleet_usign.py")
    bundle_builder = _load_module("netfleet_bundle_build", repo / "scripts/netfleet-bundle-build.py")

    manifest_out = output_dir / "manifest.json"
    existing_manifest: dict[str, object] | None = None
    if merge_manifest and manifest_out.is_file():
        existing_manifest = json.loads(manifest_out.read_text(encoding="utf-8"))

    if version is None:
        version = json.loads((repo / "product-version.json").read_text(encoding="utf-8"))["version"]
    if not SEMVER_RE.fullmatch(version):
        raise ValueError(f"invalid version: {version}")
    min_shell_version = min_shell_version or version

    if not source_commit or not source_tree:
        if existing_manifest is not None:
            source_commit = str(existing_manifest.get("source_commit") or "")
            source_tree = str(existing_manifest.get("source_tree") or "")
        else:
            source_commit, source_tree = bundle_builder.git_identity(repo)
    resolved_key = Path(
        sign_key or os.environ.get("NETFLEET_BUNDLE_SIGN_KEY") or bundle_builder.DEFAULT_SIGN_KEY
    )

    luci_makefile = (repo / "openwrt/luci-app-netfleet/Makefile").read_text(encoding="utf-8")
    luci_ver_match = re.search(r"^PKG_VERSION:=(\S+)$", luci_makefile, re.M)
    if not luci_ver_match:
        raise ValueError("cannot determine luci-app-netfleet PKG_VERSION")
    luci_version = luci_ver_match.group(1)

    with tempfile.TemporaryDirectory(prefix="netfleet-ipk-stage-") as tmp:
        stage_root = Path(tmp)
        expanded_bundle = stage_root / "expanded-bundle"
        existing_archive = output_dir / f"opl-netfleet-bundle-{version}.tar.gz"
        existing_rmf = output_dir / "release-manifest.json"
        existing_rsig = output_dir / "release-manifest.json.sig"
        existing_rpub = output_dir / "opl-netfleet-bundle.pub"
        if merge_manifest and existing_archive.is_file() and existing_rmf.is_file() and existing_rsig.is_file() and existing_rpub.is_file():
            rmf = json.loads(existing_rmf.read_text(encoding="utf-8"))
            if rmf.get("version") != version or rmf.get("source_commit") != source_commit or rmf.get("source_tree") != source_tree:
                raise ValueError("existing Release Bundle does not match requested IPK build identity")
            expanded_bundle.mkdir(parents=True, exist_ok=True)
            with tarfile.open(existing_archive, "r:gz") as tf:
                for member in tf.getmembers():
                    clean = member.name.lstrip("./")
                    if not clean or member.islnk() or member.issym() or clean.startswith("/") or ".." in Path(clean).parts:
                        raise ValueError(f"unsafe existing bundle archive entry: {member.name}")
                tf.extractall(expanded_bundle, filter="data")
            runtime_payload_hasher = hashlib.sha256()
            for rel in sorted(rmf.get("files", {})):
                meta = rmf["files"][rel]
                runtime_payload_hasher.update(f"{meta['sha256']}  {rel}\n".encode("ascii"))
            bundle_summary = {
                "archive": existing_archive.name,
                "archive_sha256": hashlib.sha256(existing_archive.read_bytes()).hexdigest(),
                "archive_size": existing_archive.stat().st_size,
                "manifest_sha256": hashlib.sha256(existing_rmf.read_bytes()).hexdigest(),
                "manifest_sig_sha256": hashlib.sha256(existing_rsig.read_bytes()).hexdigest(),
                "runtime_payload_sha256": runtime_payload_hasher.hexdigest(),
            }
        else:
            bundle_summary = bundle_builder.build_bundle(
                repo, output_dir,
                version=version, min_shell_version=min_shell_version, channel=channel,
                source_commit=source_commit, source_tree=source_tree,
                sign_key=resolved_key, keep_expanded_dir=expanded_bundle,
            )

        # 1. opl-netfleet_<version>_all.ipk
        shell_data = stage_root / "opl-netfleet"
        init_src = repo / "openwrt/files/etc/init.d"
        for name in ("opl-netfleet", "opl-netfleet-core", "opl-netfleet-update-recovery"):
            _copy_file(init_src / name, shell_data / "etc/init.d" / name, 0o755)
        etc_src = repo / "openwrt/files/etc/opl-netfleet"
        _copy_file(etc_src / "policy.example.json", shell_data / "etc/opl-netfleet/policy.example.json", 0o644)
        for pf in sorted((etc_src / "policy-sources").glob("*.json")):
            _copy_file(pf, shell_data / "etc/opl-netfleet/policy-sources" / pf.name, 0o644)
        _copy_file(etc_src / "rulesets.lock.json", shell_data / "etc/opl-netfleet/rulesets.lock.json", 0o644)
        (shell_data / "etc/opl-netfleet/extensions").mkdir(parents=True, exist_ok=True)

        libexec_src = repo / "openwrt/files/usr/libexec"
        _copy_file(libexec_src / "opl-netfleet/main.uc", shell_data / "usr/libexec/opl-netfleet/main.uc", 0o755)
        _copy_file(libexec_src / "opl-netfleet/supervisor.uc", shell_data / "usr/libexec/opl-netfleet/supervisor.uc", 0o755)
        (shell_data / "usr/libexec/opl-netfleet/plugins").mkdir(parents=True, exist_ok=True)
        _copy_file(libexec_src / "opl-netfleet-plugin-package", shell_data / "usr/libexec/opl-netfleet-plugin-package", 0o755)
        _copy_file(libexec_src / "opl-netfleet-transfer", shell_data / "usr/libexec/opl-netfleet-transfer", 0o755)
        _copy_file(libexec_src / "rpcd/opl-netfleet", shell_data / "usr/libexec/rpcd/opl-netfleet", 0o755)
        _copy_file(libexec_src / "rpcd/opl-netfleet.plugins", shell_data / "usr/libexec/rpcd/opl-netfleet.plugins", 0o755)

        share_root = shell_data / "usr/share/opl-netfleet"
        shutil.copytree(expanded_bundle, share_root / "releases" / version)
        shell_meta_path = share_root / "shell.json"
        shell_meta_path.write_text(
            json.dumps({"schema": "opl-netfleet-shell.v1", "shell_version": version}, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        shell_meta_path.chmod(0o644)
        usign.write_usign_pubkey(resolved_key, share_root / "keys/release-bundle.pub")

        shell_deps = (
            "libc, ucode, ucode-mod-fs, ucode-mod-uci, ucode-mod-ubus, ucode-mod-uloop, "
            "ucode-mod-socket, ucode-mod-digest, yq, curl, ca-bundle, flock, "
            "coreutils-timeout, unzip, ip-full, nftables-json, kmod-nft-socket, kmod-nft-tproxy, usign"
        )
        shell_pkg = _assemble_ipk(
            shell_data,
            {
                "Package": "opl-netfleet",
                "Version": version,
                "Depends": shell_deps,
                "Provides": "netfleet-plugin-api-v1",
                "License": "GPL-3.0-only",
                "Section": "net",
                "Category": "Network",
                "Architecture": "all",
                "Maintainer": "OPL NetFleet",
                "Description": "OPL NetFleet thin shell and immutable Release Bundle runtime",
            },
            _shell_scripts(version),
            output_dir / f"opl-netfleet_{version}_all.ipk",
        )

        # 2. luci-app-netfleet_<luci_version>_all.ipk
        luci_src = repo / "openwrt/luci-app-netfleet"
        luci_data = stage_root / "luci-app-netfleet"
        www_res = luci_data / "www/luci-static/resources"
        _copy_file(luci_src / "htdocs/luci-static/resources/netfleet/api.js", www_res / "netfleet/api.js", 0o644)
        _copy_file(luci_src / "htdocs/luci-static/resources/netfleet/plugin-host.js", www_res / "netfleet/plugin-host.js", 0o644)
        _copy_file(luci_src / "htdocs/luci-static/resources/view/netfleet/overview.js", www_res / "view/netfleet/overview.js", 0o644)
        subprocess.run(
            ["sh", str(luci_src / "stage-assets.sh"), str(www_res), "v" + luci_version.replace(".", "_")],
            check=True,
        )
        (www_res / "netfleet/bundle").symlink_to("/usr/share/opl-netfleet/current/www")
        _copy_file(
            luci_src / "root/usr/share/luci/menu.d/luci-app-netfleet.json",
            luci_data / "usr/share/luci/menu.d/luci-app-netfleet.json",
            0o644,
        )
        _copy_file(
            luci_src / "root/usr/share/rpcd/acl.d/luci-app-netfleet.json",
            luci_data / "usr/share/rpcd/acl.d/luci-app-netfleet.json",
            0o644,
        )
        _copy_file(
            luci_src / "root/lib/upgrade/keep.d/netfleet",
            luci_data / "lib/upgrade/keep.d/netfleet",
            0o644,
        )

        luci_pkg = _assemble_ipk(
            luci_data,
            {
                "Package": "luci-app-netfleet",
                "Version": luci_version,
                "Depends": "libc, luci-base, opl-netfleet",
                "License": "MIT",
                "Section": "luci",
                "Category": "LuCI",
                "Architecture": "all",
                "Maintainer": "OPL NetFleet",
                "Description": "Native LuCI status, configuration, and recovery interface for OPL NetFleet.",
            },
            {"postinst": _luci_postinst(), "postrm": _luci_postrm()},
            output_dir / f"luci-app-netfleet_{luci_version}_all.ipk",
        )

        built_packages = [shell_pkg, luci_pkg]
        dependency_artifacts = []
        if not skip_core:
            core_source_path = repo / "openwrt/mihomo-meta/source.json"
            core_source = json.loads(core_source_path.read_text(encoding="utf-8"))
            core_bin = _resolve_mihomo_asset(repo, core_source, mihomo_asset)
            core_ver = f"{core_source['version']}-1"
            core_data = stage_root / "mihomo-meta"
            (core_data / "usr/libexec").mkdir(parents=True, exist_ok=True)
            mihomo_bin_dst = core_data / "usr/libexec/mihomo"
            mihomo_bin_dst.write_bytes(core_bin)
            mihomo_bin_dst.chmod(0o755)
            _copy_file(core_source_path, core_data / "usr/share/mihomo-meta/source.json", 0o644)
            core_license = repo / "openwrt/mihomo-meta/LICENSE"
            if core_license.is_file():
                _copy_file(core_license, core_data / "usr/share/mihomo-meta/LICENSE", 0o644)
            core_pkg = _assemble_ipk(
                core_data,
                {
                    "Package": "mihomo-meta",
                    "Version": core_ver,
                    "Depends": "libc, ca-bundle, ip-full, kmod-inet-diag, kmod-tun",
                    "Provides": "mihomo",
                    "Conflicts": "mihomo-alpha",
                    "Alternatives": "300:/usr/bin/mihomo:/usr/libexec/mihomo",
                    "License": str(core_source.get("license", "GPL-3.0-or-later")),
                    "Section": "net",
                    "Category": "Network",
                    "Architecture": core_arch,
                    "Maintainer": "OPL NetFleet",
                    "Description": "Mihomo proxy core (official prebuilt)",
                },
                _mihomo_scripts(),
                output_dir / f"mihomo-meta_{core_ver}_{core_arch}.ipk",
            )
            built_packages.append(core_pkg)
            dependency_artifacts.append({
                "package": "mihomo-meta",
                "name": core_pkg["name"],
                "sha256": core_pkg["sha256"],
                "size": core_pkg["size"],
                "version": core_source["version"],
                "release": "1",
                "package_arch": core_arch,
                "upstream": {
                    "version": core_source["version"],
                    "architecture": core_arch,
                    "filename": core_source["filename"],
                    "sha256": core_source["sha256"],
                },
            })

    # Write OPKG feed index: Packages, Packages.gz, Packages.sig, opl-netfleet-usign.pub
    stanzas = "\n".join(pkg["stanza"] for pkg in sorted(built_packages, key=lambda p: str(p["package"])))
    packages_path = output_dir / "Packages"
    packages_path.write_text(stanzas, encoding="utf-8")
    packages_path.chmod(0o644)

    gz_buf = io.BytesIO()
    with gzip.GzipFile(fileobj=gz_buf, mode="wb", mtime=0, compresslevel=9) as gz:
        gz.write(stanzas.encode("utf-8"))
    packages_gz_path = output_dir / "Packages.gz"
    packages_gz_path.write_bytes(gz_buf.getvalue())
    packages_gz_path.chmod(0o644)

    sig_path = output_dir / "Packages.sig"
    usign.sign_file(resolved_key, packages_path, sig_path)
    pub_path = output_dir / "opl-netfleet-usign.pub"
    usign_key_id = usign.write_usign_pubkey(resolved_key, pub_path)

    installer_dst = output_dir / "install-netfleet.sh"
    _copy_file(repo / "scripts/install-netfleet.sh", installer_dst, 0o755)

    def _file_ref(path: Path) -> dict[str, object]:
        data = path.read_bytes()
        return {"name": path.name, "sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}

    ipk_items = [
        {
            "package": pkg["package"],
            "name": pkg["name"],
            "version": pkg["version"],
            "sha256": pkg["sha256"],
            "size": pkg["size"],
        }
        for pkg in built_packages
        if pkg["package"] != "mihomo-meta"
    ]
    ipk_files = {
        str(pkg["package"]): str(pkg["name"])
        for pkg in built_packages
        if pkg["package"] != "mihomo-meta"
    }
    release_bundle_ref = {
        "archive": bundle_summary["archive"],
        "archive_sha256": bundle_summary["archive_sha256"],
        "archive_size": bundle_summary["archive_size"],
        "manifest": "release-manifest.json",
        "manifest_sha256": bundle_summary["manifest_sha256"],
        "manifest_sig": "release-manifest.json.sig",
        "manifest_sig_sha256": bundle_summary["manifest_sig_sha256"],
        "public_key": "opl-netfleet-bundle.pub",
    }
    if merge_manifest and existing_manifest is not None:
        manifest = dict(existing_manifest)
        manifest["delivery_model"] = "release-bundle"
        manifest["usign_key_id"] = usign_key_id
        manifest["usign_public_key"] = _file_ref(pub_path)
        manifest["opkg_index"] = {
            "packages": _file_ref(packages_path),
            "packages_gz": _file_ref(packages_gz_path),
            "packages_sig": _file_ref(sig_path),
        }
        manifest["release_bundle"] = release_bundle_ref
        manifest["ipk_artifacts"] = ipk_items
        manifest["ipk_artifact_files"] = ipk_files
        manifest["ipk_dependency_artifacts"] = dependency_artifacts
    else:
        manifest = {
            "schema": "opl-netfleet-package-manifest.v2",
            "delivery_model": "release-bundle",
            "package_format": "ipk",
            "package_arch": "all",
            "build_target_arch": core_arch,
            "package_version": version,
            "source_commit": source_commit,
            "source_tree": source_tree,
            "runtime_payload_sha256": bundle_summary["runtime_payload_sha256"],
            "usign_key_id": usign_key_id,
            "usign_public_key": _file_ref(pub_path),
            "opkg_index": {
                "packages": _file_ref(packages_path),
                "packages_gz": _file_ref(packages_gz_path),
                "packages_sig": _file_ref(sig_path),
            },
            "release_bundle": release_bundle_ref,
            "feed_bootstrap": _file_ref(installer_dst),
            "artifacts": ipk_items,
            "artifact_files": ipk_files,
            "dependency_artifacts": dependency_artifacts,
        }
    manifest_out.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    manifest_out.chmod(0o644)
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=ROOT)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--version")
    parser.add_argument("--min-shell-version")
    parser.add_argument("--channel", default="stable")
    parser.add_argument("--arch", default="aarch64_generic")
    parser.add_argument("--skip-core", action="store_true")
    parser.add_argument("--mihomo-asset", type=Path)
    parser.add_argument("--sign-key", type=Path)
    parser.add_argument("--merge-manifest", action="store_true")
    parser.add_argument("--source-commit")
    parser.add_argument("--source-tree")
    args = parser.parse_args()
    manifest = build_ipk_feed(
        args.repo, args.output,
        version=args.version, min_shell_version=args.min_shell_version,
        channel=args.channel, core_arch=args.arch,
        skip_core=args.skip_core, mihomo_asset=args.mihomo_asset,
        sign_key=args.sign_key,
        merge_manifest=args.merge_manifest,
        source_commit=args.source_commit,
        source_tree=args.source_tree,
    )
    print(json.dumps({
        "ok": True,
        "package_format": manifest["package_format"],
        "version": manifest["package_version"],
        "usign_key_id": manifest["usign_key_id"],
        "artifacts": manifest.get("ipk_artifact_files", manifest["artifact_files"]),
    }, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
