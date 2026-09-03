#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

./scripts/check-fast.sh
python3 tests/run_deploy_matrix.py "$@"
