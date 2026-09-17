#!/bin/sh
# 更新替换进程：独立于被替换的应用运行，只接受宿主已校验的参数。
# 任何一步失败都把旧应用放回原位并重新打开旧版本，不留下半替换状态。
# 用法：update-install.sh <appPid> <stagedApp> <targetApp> <previousApp> <receiptPath> <expectedTeamId>
set -eu
app_pid=$1
staged=$2
target=$3
previous=$4
receipt=$5
team=$6

# 回执先写同目录临时文件再重命名，避免下一次启动读到半个 JSON。
write_receipt() {
	/usr/bin/printf '{\n  "schema": "opl-netfleet-macos-update-receipt.v1",\n  "state": "%s",\n  "version": %s,\n  "detail": %s,\n  "at": %s\n}\n' \
		"$1" "$2" "$3" "$(/bin/date +%s)" >"$receipt.tmp" && /bin/mv -f "$receipt.tmp" "$receipt"
}

json_string() {
	if [ -z "$1" ]; then printf 'null'; else printf '"%s"' "$1"; fi
}

# 交换前失败：目标应用从未被移动，保持原样即可，绝不删除它。
abort() {
	write_receipt failed null "$(json_string "$1")" || true
	exit 1
}

# 交换后失败：把单槽备份放回原位并重新打开旧版本。
rollback() {
	/bin/rm -rf "$target" 2>/dev/null || true
	if [ -d "$previous" ]; then /bin/mv "$previous" "$target" 2>/dev/null || true; fi
	write_receipt failed null "$(json_string "$1")" || true
	[ -d "$target" ] && /usr/bin/open "$target" 2>/dev/null || true
	exit 1
}

# 等待应用真正退出；应用未退出就绝不替换正在运行的包。
wait_seconds=${NETFLEET_UPDATE_WAIT_SECONDS:-120}
attempt=0
while /bin/kill -0 "$app_pid" 2>/dev/null; do
	attempt=$((attempt + 1))
	[ "$attempt" -gt $((wait_seconds * 2)) ] && abort "应用未在等待时间内退出，已保留当前版本"
	/bin/sleep 0.5
done

[ -d "$staged" ] || abort "更新暂存目录缺失"
/usr/bin/codesign --verify --deep --strict "$staged" || abort "新应用签名校验失败"
/usr/bin/codesign -dv --verbose=4 "$staged" 2>&1 | /usr/bin/grep -q "TeamIdentifier=$team" || abort "新应用 Team ID 与当前应用不一致"

/bin/rm -rf "$previous"
if [ -d "$target" ]; then /bin/mv "$target" "$previous" || abort "无法保留当前版本"; fi
/usr/bin/ditto "$staged" "$target" || rollback "复制新应用失败"
/usr/bin/codesign --verify --deep --strict "$target" || rollback "替换后签名校验失败"
/usr/bin/xattr -dr com.apple.quarantine "$target" 2>/dev/null || true

version=$(/usr/bin/plutil -extract package_version raw -o - "$target/Contents/Resources/build.json" 2>/dev/null || echo "")
write_receipt installed "$(json_string "$version")" null
/usr/bin/open "$target" || true
/bin/rm -rf "$previous" "$staged" 2>/dev/null || true
exit 0
