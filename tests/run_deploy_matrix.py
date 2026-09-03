#!/usr/bin/env python3
"""Run independent fake-device deployment tests concurrently.

Each test owns a TemporaryDirectory, so process-level parallelism changes only
the scheduler, not the test contract or the fixture state it verifies.
"""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import time


ROOT = Path(__file__).parents[1]
MODULE = "tests.test_deploy_openwrt.DeployOpenWrtTests"


def module_path() -> str:

	return str(ROOT / "tests" / "test_deploy_openwrt.py")


def discover_names() -> list[str]:
    spec = importlib.util.spec_from_file_location("netfleet_test_deploy_openwrt", module_path())
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load deployment test module")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return sorted(name for name in dir(module.DeployOpenWrtTests) if name.startswith("test_"))


def run_one(name: str) -> tuple[str, float, int, str]:
    started = time.monotonic()
    result = subprocess.run(
        [sys.executable, "-m", "unittest", f"{MODULE}.{name}"],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    return name, time.monotonic() - started, result.returncode, result.stdout + result.stderr


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--workers",
        type=int,
        default=min(8, os.cpu_count() or 1),
        help="maximum independent deployment tests to run at once (default: up to 8)",
    )
    parser.add_argument(
        "--test",
        dest="tests",
        action="append",
        help="run only this DeployOpenWrtTests method; repeat for a smoke subset",
    )
    parser.add_argument("--list", action="store_true", help="list test methods and exit")
    args = parser.parse_args()
    names = discover_names()
    if args.list:
        print("\n".join(names))
        return 0
    if args.workers < 1:
        parser.error("--workers must be at least 1")
    selected = names if not args.tests else args.tests
    unknown = sorted(set(selected) - set(names))
    if unknown:
        parser.error(f"unknown deployment test: {', '.join(unknown)}")

    started = time.monotonic()
    results: list[tuple[str, float, int, str]] = []
    with ThreadPoolExecutor(max_workers=min(args.workers, len(selected))) as pool:
        futures = [pool.submit(run_one, name) for name in selected]
        for future in as_completed(futures):
            result = future.result()
            results.append(result)
            name, elapsed, returncode, _output = result
            print(f"[{len(results)}/{len(selected)}] {name} {elapsed:.2f}s", flush=True)

    failures = [result for result in results if result[2] != 0]
    if failures:
        print("\n失败的部署测试：", file=sys.stderr)
        for name, _elapsed, _returncode, output in sorted(failures):
            print(f"\n--- {name} ---\n{output}", file=sys.stderr)
        return 1

    print(
        f"部署矩阵通过：{len(results)} 个测试，串行成本约为各测试总和，"
        f"并行耗时 {time.monotonic() - started:.2f}s。"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
