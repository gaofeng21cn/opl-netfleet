#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$root/ui"

bun install --frozen-lockfile
work=$(mktemp -d "${TMPDIR:-/tmp}/netfleet-ui-check.XXXXXX")
trap 'rm -rf "$work"' EXIT INT TERM

run_lane() {
	name=$1
	shift
	"$@" >"$work/$name.out" 2>"$work/$name.err"
}

run_lane typecheck bun run typecheck & p1=$!
run_lane test bun run test & p2=$!
run_lane build bun run build:desktop & p3=$!

status=0
wait "$p1" || status=1
wait "$p2" || status=1
wait "$p3" || status=1

for name in typecheck test build; do
	cat "$work/$name.out"
	cat "$work/$name.err" >&2
done
exit "$status"
