#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd -- "$script_dir/.." && pwd)

if [[ -x "$repo_dir/.venv/bin/python" ]]; then
	exec "$repo_dir/.venv/bin/python" "$script_dir/deploy_openwrt.py" "$@"
fi
if command -v uv >/dev/null 2>&1 && [[ -f "$repo_dir/uv.lock" ]] && [[ "${OPL_NETFLEET_DISABLE_UV:-0}" != "1" ]]; then
	exec uv run --frozen --project "$repo_dir" python "$script_dir/deploy_openwrt.py" "$@"
fi
exec python3 "$script_dir/deploy_openwrt.py" "$@"
