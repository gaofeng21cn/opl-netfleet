#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$root/ui"

bun install --frozen-lockfile
bun run typecheck
bun run test
bun run build
