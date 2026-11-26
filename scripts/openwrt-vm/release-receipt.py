#!/usr/bin/env python3
"""Combine all release lanes for one sealed OpenWrt candidate."""

import argparse
import hashlib
import json
from pathlib import Path


RELEASE_LANES = {
    "native": {"native"},
    "setup": {"setup"},
    "migration": {"management", "runtime", "migration"},
    "package": {"package-management", "package-runtime", "package"},
}
BOOT_CHECKS = ("boot", "ssh", "var_symlink", "ubus")
HOST_PHASES = ("assets_ms", "image_ms", "boot_ms", "transfer_ms")


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_json(path):
    return json.loads(path.read_text())


def combine(receipt_paths, commit, tree, candidate_manifest, fixture_manifest):
    candidate = read_json(candidate_manifest)
    identity = {"source_commit": commit, "source_tree": tree}
    manifest_sha = sha256(candidate_manifest)
    fixture_sha = sha256(fixture_manifest)
    if any(candidate.get(key) != value for key, value in identity.items()):
        raise ValueError("release candidate belongs to a different Git source")

    evidence = {}
    guest_results = {}
    guest_times = {}
    lane_times = {}
    lane_starts = []
    lane_ends = []
    lane_platforms = {}
    common_runtime = None
    for path in receipt_paths:
        receipt = read_json(path)
        lane = receipt.get("release_lane")
        if lane not in RELEASE_LANES or lane in evidence:
            raise ValueError(f"unexpected or duplicate release lane: {lane}")
        source = receipt.get("test_source", identity)
        if (receipt.get("schema") != "opl-netfleet-openwrt-vm-release-lane.v1"
                or receipt.get("qualified") is not False
                or receipt.get("package_qualified", False) is not False
                or source != identity
                or any(receipt.get(key) != value for key, value in identity.items())
                or receipt.get("candidate_manifest_sha256") != manifest_sha
                or receipt.get("component_fixtures_sha256") != fixture_sha):
            raise ValueError(f"release lane identity mismatch: {lane}")

        lanes = receipt["lanes"]
        checks = receipt["checks"]
        platform = receipt["platform"]
        if set(lanes) != RELEASE_LANES[lane] or not all(checks.get(key) is True for key in BOOT_CHECKS):
            raise ValueError(f"incomplete release lane: {lane}")
        if (platform["runner_arch"] not in ("aarch64", "arm64")
                or platform["guest_arch"] != "aarch64" or platform["qemu_system"] != "aarch64"
                or platform["accelerator"] not in ("hvf", "kvm", "tcg") or not platform["qemu_version"]):
            raise ValueError(f"release lane platform mismatch: {lane}")
        runtime = {key: receipt[key] for key in
                   ("openwrt_version", "openwrt_image_sha256", "runtime_assets")}
        if common_runtime is None:
            common_runtime = runtime
        elif runtime != common_runtime:
            raise ValueError(f"release lane runtime inputs changed: {lane}")

        timings = receipt["qualification_metrics"]
        started_at = receipt["started_at_ms"]
        expected_times = {"total_ms", *HOST_PHASES, *(f"{name}_guest_ms" for name in lanes)}
        if (set(timings) != expected_times
                or type(started_at) is not int or started_at <= 0
                or any(type(value) is not int or value < 0 for value in timings.values())):
            raise ValueError(f"invalid release lane timings: {lane}")
        for name, result in lanes.items():
            if (result.get("ok") is not True
                    or any(result.get(key) != value for key, value in identity.items())
                    or not isinstance(result.get("checks"), dict) or not result["checks"]
                    or any(value is not True for value in result["checks"].values())):
                raise ValueError(f"invalid guest result: {name}")
            guest_results[name] = result
            guest_times[f"{name}_guest_ms"] = timings[f"{name}_guest_ms"]

        lane_times[lane] = {key: timings[key] for key in ("total_ms", *HOST_PHASES)}
        lane_starts.append(started_at)
        lane_ends.append(started_at + timings["total_ms"])
        lane_platforms[lane] = platform
        evidence[lane] = sha256(path)

    if set(evidence) != set(RELEASE_LANES):
        raise ValueError("release qualification requires one receipt for each of the four lanes")
    if guest_results["package"].get("manifest_sha256") != manifest_sha:
        raise ValueError("package guest qualification manifest mismatch")
    elapsed_ms = max(lane_ends) - min(lane_starts)

    runtime = guest_results["runtime"]
    platforms = list(lane_platforms.values())
    common_platform = {key: value for key, value in platforms[0].items()
                       if all(platform.get(key) == value for platform in platforms)}
    host_times = {key: sum(timings[key] for timings in lane_times.values()) for key in HOST_PHASES}
    checks = {
        **dict.fromkeys(BOOT_CHECKS, True),
        **guest_results["management"]["checks"],
        **runtime["checks"],
        **{f"{name}.{key}": passed for name, result in guest_results.items()
           for key, passed in result["checks"].items()},
    }
    return {
        "schema": "opl-netfleet-openwrt-vm-qualification.v2",
        "qualified": True,
        "package_qualified": True,
        **identity,
        **common_runtime,
        "checks": checks,
        "metrics": runtime.get("metrics", {}),
        "runtime": runtime.get("runtime", {}),
        "lanes": guest_results,
        "package": guest_results["package"],
        "platform": {**common_platform, "execution": "parallel", "release_lanes": lane_platforms},
        "qualification_metrics": {
            "total_ms": elapsed_ms,
            **host_times,
            **guest_times,
            "release_lanes": lane_times,
        },
        "component_fixtures_sha256": fixture_sha,
        "release_lane_receipts": evidence,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--tree", required=True)
    parser.add_argument("--candidate-manifest", required=True, type=Path)
    parser.add_argument("--fixture-manifest", required=True, type=Path)
    parser.add_argument("--lane-receipts", nargs=4, required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    result = combine(args.lane_receipts, args.commit, args.tree, args.candidate_manifest,
                     args.fixture_manifest)
    temporary = args.output.with_suffix(".tmp")
    temporary.write_text(json.dumps(result, sort_keys=True, separators=(",", ":")) + "\n")
    temporary.replace(args.output)

    elapsed_ms = result["qualification_metrics"]["total_ms"]
    print(f"OpenWrt base qualification passed (lane wall-clock span {elapsed_ms / 1000:.1f}s)")
    for lane, timings in result["qualification_metrics"]["release_lanes"].items():
        print(f"- {lane}: {timings['total_ms'] / 1000:.1f}s on {result['platform']['release_lanes'][lane]['accelerator']}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, KeyError, TypeError, ValueError) as error:
        raise SystemExit(f"OpenWrt release receipt: {error}") from error
