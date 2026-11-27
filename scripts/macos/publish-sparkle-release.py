#!/usr/bin/env python3
"""Publish the three sealed macOS assets and advance the independent Sparkle feed."""

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
from tempfile import TemporaryDirectory
from urllib.request import urlopen
import xml.etree.ElementTree as ET
from zipfile import BadZipFile, ZipFile


DMG = "OPL-NetFleet-macos-arm64.dmg"
APPCAST = "appcast.xml"
VERSION_ASSETS = (DMG, DMG + ".sha256", APPCAST)
STABLE = "macos-stable"
PREVIOUS = "appcast.previous.xml"
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
MAX_APPCAST_BYTES = 262144
CANDIDATE_WORKFLOW = ".github/workflows/macos-sparkle-release.yml"


class ReleaseError(RuntimeError):
    pass


def gh(*args, timeout=45):
    try:
        return subprocess.run(["gh", *args], capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        raise ReleaseError(f"GitHub command timed out ({args[0]})") from error


def stable_version(short_version, build):
    if not re.fullmatch(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", short_version or ""):
        raise ReleaseError("Invalid macOS product version")
    if not re.fullmatch(r"[1-9]\d*", build or ""):
        raise ReleaseError("Invalid macOS build number")
    return tuple(map(int, short_version.split("."))), int(build)


def appcast_version(data, repo):
    try:
        items = ET.fromstring(data).findall("./channel/item")
    except ET.ParseError as error:
        raise ReleaseError("Invalid Sparkle appcast XML") from error
    if len(items) != 1:
        raise ReleaseError("Expected one Sparkle appcast item")
    item = items[0]
    short_version = item.findtext(f"{SPARKLE}shortVersionString")
    version = stable_version(short_version, item.findtext(f"{SPARKLE}version"))
    enclosure = item.find("enclosure")
    expected_url = f"https://github.com/{repo}/releases/download/v{short_version}/{DMG}"
    if (
        enclosure is None
        or enclosure.get("url") != expected_url
        or not re.fullmatch(r"[1-9]\d*", enclosure.get("length", ""))
        or not re.fullmatch(r"[A-Za-z0-9+/]{86}==", enclosure.get(f"{SPARKLE}edSignature", ""))
    ):
        raise ReleaseError("Invalid Sparkle DMG enclosure")
    return version, int(enclosure.attrib["length"])


def release_assets(repo, tag, *, optional=False):
    response = gh("api", "--include", f"repos/{repo}/releases/tags/{tag}")
    status = re.match(rb"HTTP/\S+ (\d{3})(?:\s|$)", response.stdout)
    if optional and status and status[1] == b"404":
        return None
    if response.returncode or not status or status[1] != b"200":
        raise ReleaseError(f"Cannot read GitHub Release {tag}")
    parts = response.stdout.replace(b"\r\n", b"\n").split(b"\n\n", 1)
    try:
        data = json.loads(parts[1])
        if data["tag_name"] != tag or data["draft"] or data["prerelease"]:
            raise ValueError("Release is not a public stable release")
        assets = {item["name"]: item for item in data["assets"]}
        if len(assets) != len(data["assets"]):
            raise ValueError("Duplicate release asset name")
        return assets
    except (IndexError, KeyError, TypeError, ValueError) as error:
        raise ReleaseError(f"Invalid GitHub Release metadata for {tag}") from error


def digest(data):
    return "sha256:" + hashlib.sha256(data).hexdigest()


def stream_identity(source, expected_size=None):
    sha256 = hashlib.sha256()
    size = 0
    while chunk := source.read(1024 * 1024):
        size += len(chunk)
        if expected_size is not None and size > expected_size:
            raise ReleaseError("Downloaded asset exceeded its expected size")
        sha256.update(chunk)
    return "sha256:" + sha256.hexdigest(), size


def same_asset(asset, identity):
    return asset.get("state") == "uploaded" and (asset.get("digest"), asset.get("size")) == identity


def download_appcast(repo, asset):
    asset_id = asset.get("id")
    if type(asset_id) is not int or type(asset.get("size")) is not int or asset["size"] > MAX_APPCAST_BYTES:
        raise ReleaseError("Invalid Sparkle appcast asset metadata")
    response = gh("api", "--header", "Accept: application/octet-stream", f"repos/{repo}/releases/assets/{asset_id}")
    if response.returncode or not same_asset(asset, (digest(response.stdout), len(response.stdout))):
        raise ReleaseError("Cannot verify current Sparkle appcast bytes")
    return response.stdout


def verify_public_asset(repo, tag, name, identity):
    url = f"https://github.com/{repo}/releases/download/{tag}/{name}"
    try:
        with urlopen(url, timeout=20) as response:
            actual = stream_identity(response, identity[1])
    except OSError as error:
        raise ReleaseError(f"Cannot read public release asset {tag}/{name}") from error
    if actual != identity:
        raise ReleaseError(f"Public release asset {tag}/{name} differs from the sealed asset")


def check_stable(repo, candidate, candidate_xml=None):
    assets = release_assets(repo, STABLE, optional=True)
    if assets is None:
        return None, None
    current = assets.get(APPCAST) or assets.get(PREVIOUS)
    if current is None:
        raise ReleaseError("Cannot establish the current macOS stable build")
    current_xml = download_appcast(repo, current)
    (version, build), _ = appcast_version(current_xml, repo)
    if current_xml != candidate_xml and (candidate[0] < version or candidate[1] <= build):
        raise ReleaseError("Candidate would roll back the macOS stable channel")
    return assets, current_xml


def upload_asset(repo, tag, path, identity):
    try:
        gh("release", "upload", tag, str(path), "--repo", repo, timeout=240)
    except ReleaseError:
        # The server may have committed the upload before the connection failed.
        pass
    asset = release_assets(repo, tag).get(path.name)
    if asset is None or not same_asset(asset, identity):
        raise ReleaseError(f"Could not verify upload of {tag}/{path.name}")


def rename_stable_asset(repo, asset, name):
    try:
        gh("api", "--method", "PATCH", f"repos/{repo}/releases/assets/{asset['id']}", "--raw-field", f"name={name}")
    except ReleaseError:
        pass
    result = release_assets(repo, STABLE).get(name)
    if result is None or result["id"] != asset["id"] or not same_asset(result, (asset["digest"], asset["size"])):
        raise ReleaseError(f"Could not verify stable appcast rename to {name}")


def remove_previous(repo, asset):
    try:
        gh("api", "--method", "DELETE", f"repos/{repo}/releases/assets/{asset['id']}")
    except ReleaseError:
        pass
    if PREVIOUS in release_assets(repo, STABLE):
        raise ReleaseError("Could not remove the previous stable appcast")


def promote(repo, source, appcast, candidate, xml):
    identity = digest(xml), len(xml)
    assets, current_xml = check_stable(repo, candidate, xml)
    if assets is None:
        try:
            gh(
                "release", "create", STABLE, str(appcast), "--target", source, "--title", "macOS Stable Feed",
                "--notes", "Floating Sparkle appcast channel for signed macOS releases.",
                "--latest=false", "--repo", repo,
            )
        except ReleaseError:
            pass
    elif current_xml != xml or APPCAST not in assets:
        # Keep a verified copy of the old feed while GitHub swaps the asset names.
        # An interrupted swap can still establish the previous public build.
        with TemporaryDirectory(prefix="netfleet-stable-appcast-") as directory:
            staged = Path(directory) / f"appcast-{candidate[1]}.xml"
            staged.write_bytes(xml)
            if staged.name not in assets:
                upload_asset(repo, STABLE, staged, identity)
            assets, _ = check_stable(repo, candidate, xml)
            incoming = assets.get(staged.name)
            if incoming is None or not same_asset(incoming, identity):
                raise ReleaseError("Staged stable appcast differs from the sealed appcast")
            if APPCAST in assets:
                if PREVIOUS in assets:
                    remove_previous(repo, assets[PREVIOUS])
                rename_stable_asset(repo, assets[APPCAST], PREVIOUS)
            try:
                rename_stable_asset(repo, incoming, APPCAST)
            except ReleaseError:
                remaining = release_assets(repo, STABLE)
                if APPCAST not in remaining and PREVIOUS in remaining:
                    rename_stable_asset(repo, remaining[PREVIOUS], APPCAST)
                raise

    assets = release_assets(repo, STABLE)
    if APPCAST not in assets or download_appcast(repo, assets[APPCAST]) != xml:
        raise ReleaseError("Stable appcast readback differs from the sealed appcast")
    verify_public_asset(repo, STABLE, APPCAST, identity)
    if PREVIOUS in assets:
        remove_previous(repo, assets[PREVIOUS])


def verify_qualification(receipt, bundle_hash, candidate):
    build = receipt.get("build")
    if receipt.get("vm_qualified") is not True or not isinstance(build, dict):
        raise ReleaseError("An isolated macOS VM qualification receipt is required")
    if receipt.get("dmg_sha256") != bundle_hash:
        raise ReleaseError("VM qualification does not match the sealed DMG bytes")
    if (
        build.get("channel") != "distribution"
        or build.get("working_tree_dirty") is not False
        or stable_version(build.get("package_version"), build.get("package_release")) != candidate
    ):
        raise ReleaseError("Qualified app metadata does not match the sealed distribution candidate")
    identity = [build.get("source_commit"), build.get("source_tree")]
    if not all(isinstance(value, str) and re.fullmatch(r"[a-f0-9]{40}", value) for value in identity):
        raise ReleaseError("Qualified app source commit and tree are required")
    return identity


def read_workflow_qualification(path, tag):
    receipt = json.loads(path.read_text())
    if (
        not isinstance(receipt, dict)
        or receipt.keys() != {"vm_qualified", "dmg_sha256", "build"}
        or not isinstance(receipt["build"], dict)
        or receipt["build"].keys() != {
            "channel", "working_tree_dirty", "package_version", "package_release", "source_commit", "source_tree",
        }
        or not isinstance(receipt["dmg_sha256"], str)
        or not re.fullmatch(r"[a-f0-9]{64}", receipt["dmg_sha256"])
    ):
        raise ReleaseError("Expected a minimal macOS VM qualification receipt")
    candidate = stable_version(tag[1:], receipt["build"]["package_release"])
    verify_qualification(receipt, receipt["dmg_sha256"], candidate)
    return receipt


def github_json(endpoint):
    response = gh("api", endpoint)
    if response.returncode:
        raise ReleaseError("Cannot read GitHub Actions candidate metadata")
    data = json.loads(response.stdout)
    if not isinstance(data, dict):
        raise ReleaseError("Invalid GitHub Actions candidate metadata")
    return data


def candidate_artifact(repo, tag, run_id):
    if not re.fullmatch(r"[1-9][0-9]*", run_id):
        raise ReleaseError("Candidate run ID must be a positive integer")
    prefix = f"repos/{repo}/actions"
    workflow = github_json(f"{prefix}/workflows/{Path(CANDIDATE_WORKFLOW).name}")
    run = github_json(f"{prefix}/runs/{run_id}")
    if (
        run.get("id") != int(run_id)
        or run.get("workflow_id") != workflow.get("id")
        or workflow.get("path") != CANDIDATE_WORKFLOW
        or run.get("path") != CANDIDATE_WORKFLOW
        or not re.fullmatch(r"[a-f0-9]{40}", run.get("head_sha") or "")
        or run.get("status") != "completed"
        or run.get("conclusion") != "success"
        or run.get("repository", {}).get("full_name") != repo
        or run.get("head_repository", {}).get("full_name") != repo
    ):
        raise ReleaseError("Expected a successful NetFleet macOS candidate run")
    if run.get("event") == "workflow_dispatch":
        if run.get("head_branch") != "main":
            raise ReleaseError("Manually dispatched macOS candidate must run from main")
    elif run.get("event") == "push":
        if run.get("head_branch") != tag:
            raise ReleaseError("Automatically dispatched macOS candidate must run from the product tag")
        tagged_source = github_json(f"repos/{repo}/commits/{tag}").get("sha")
        if tagged_source != run.get("head_sha"):
            raise ReleaseError("Product tag does not match the automatic macOS candidate source")
    else:
        raise ReleaseError("Expected a tag-triggered or manually dispatched macOS candidate run")
    name = f"netfleet-macos-{tag}"
    listing = github_json(f"{prefix}/runs/{run_id}/artifacts?name={name}")
    artifacts = listing.get("artifacts", [])
    if listing.get("total_count") != 1 or len(artifacts) != 1:
        raise ReleaseError("Expected exactly one macOS release artifact in the candidate run")
    asset = artifacts[0]
    owner = asset.get("workflow_run", {})
    if (
        asset.get("name") != name
        or asset.get("expired") is not False
        or type(asset.get("id")) is not int
        or asset["id"] <= 0
        or type(asset.get("size_in_bytes")) is not int
        or asset["size_in_bytes"] <= 0
        or not re.fullmatch(r"sha256:[a-f0-9]{64}", asset.get("digest") or "")
        or owner.get("id") != run["id"]
        or owner.get("head_sha") != run.get("head_sha")
        or owner.get("repository_id") != run["repository"].get("id")
        or owner.get("head_repository_id") != run["head_repository"].get("id")
    ):
        raise ReleaseError("GitHub Actions artifact does not match the trusted candidate run")
    return {key: asset[key] for key in ("id", "digest", "size_in_bytes")}


def download_candidate(repo, asset, directory):
    archive = directory / "candidate.zip"
    endpoint = f"repos/{repo}/actions/artifacts/{asset['id']}/zip"
    try:
        with archive.open("wb") as output:
            result = subprocess.run(["gh", "api", endpoint], stdout=output, timeout=240)
    except subprocess.TimeoutExpired as error:
        raise ReleaseError("Candidate artifact download timed out") from error
    with archive.open("rb") as source:
        actual = stream_identity(source, asset["size_in_bytes"])
    if result.returncode or actual != (asset["digest"], asset["size_in_bytes"]):
        raise ReleaseError("Downloaded candidate archive does not match the GitHub Actions digest")
    with ZipFile(archive) as zipped:
        if sorted(zipped.namelist()) != sorted(VERSION_ASSETS):
            raise ReleaseError("Candidate archive must contain exactly the three macOS release assets")
        for name in VERSION_ASSETS:
            with zipped.open(name) as source, (directory / name).open("xb") as output:
                shutil.copyfileobj(source, output)


def publish(repo, tag, directory, qualification):
    paths = {name: directory / name for name in VERSION_ASSETS}
    bundle = paths[DMG].read_bytes()
    xml = paths[APPCAST].read_bytes()
    candidate, length = appcast_version(xml, repo)
    if candidate[0] != stable_version(tag[1:], "1")[0] or length != len(bundle):
        raise ReleaseError("Sealed appcast does not match the selected release DMG")
    bundle_hash = hashlib.sha256(bundle).hexdigest()
    if paths[DMG + ".sha256"].read_text().split() != [bundle_hash, DMG]:
        raise ReleaseError("Sealed DMG does not match its checksum")
    source = verify_qualification(qualification, bundle_hash, candidate)
    identities = {name: (digest(data), len(data)) for name, data in (
        (DMG, bundle), (APPCAST, xml), (DMG + ".sha256", paths[DMG + ".sha256"].read_bytes()),
    )}

    tag_identity = gh("api", f"repos/{repo}/commits/{tag}", "--jq", "[.sha, .commit.tree.sha] | .[]")
    if tag_identity.returncode or tag_identity.stdout.decode().split() != source:
        raise ReleaseError("Release tag no longer matches the qualified macOS source commit and tree")
    assets = release_assets(repo, tag)
    check_stable(repo, candidate, xml)
    for name in VERSION_ASSETS:
        if name in assets and not same_asset(assets[name], identities[name]):
            raise ReleaseError(f"Refusing to replace existing asset {tag}/{name}")
    for name in VERSION_ASSETS:
        if name not in assets:
            upload_asset(repo, tag, paths[name], identities[name])
    final = release_assets(repo, tag)
    if any(name not in final or not same_asset(final[name], identities[name]) for name in VERSION_ASSETS):
        raise ReleaseError("Published macOS asset readback differs from the sealed artifacts")
    for name, identity in identities.items():
        verify_public_asset(repo, tag, name, identity)
    promote(repo, source[0], paths[APPCAST], candidate, xml)
    print(f"Verified macOS release assets and public Sparkle feed for {tag}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--qualification", type=Path, metavar="VM_RECEIPT")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--preflight", type=Path, metavar="INFO_PLIST")
    group.add_argument("--artifacts", type=Path, metavar="DIRECTORY")
    group.add_argument("--admit-candidate-run", metavar="RUN_ID")
    group.add_argument("--publish-candidate-run", metavar="RUN_ID")
    parser.add_argument("--candidate-identity", metavar="JSON")
    args = parser.parse_args()
    try:
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repo) or not args.tag.startswith("v"):
            raise ReleaseError("Invalid GitHub release target")
        target_version, _ = stable_version(args.tag[1:], "1")
        if args.preflight:
            metadata = plistlib.loads(args.preflight.read_bytes())
            candidate = stable_version(metadata.get("CFBundleShortVersionString"), metadata.get("CFBundleVersion"))
            if candidate[0] != target_version:
                raise ReleaseError("Application product version does not match the release tag")
            published = release_assets(args.repo, args.tag, optional=True)
            if published is not None and set(VERSION_ASSETS) & published.keys():
                raise ReleaseError("Versioned macOS assets already exist. Retry publication with the same qualified artifacts.")
            check_stable(args.repo, candidate)
        elif args.admit_candidate_run or args.publish_candidate_run:
            if args.qualification is None:
                raise ReleaseError("GitHub Actions candidate requires a macOS VM --qualification receipt")
            qualification = read_workflow_qualification(args.qualification, args.tag)
            run_id = args.admit_candidate_run or args.publish_candidate_run
            asset = candidate_artifact(args.repo, args.tag, run_id)
            if args.admit_candidate_run:
                print(json.dumps(asset, separators=(",", ":")))
            else:
                if not args.candidate_identity or asset != json.loads(args.candidate_identity):
                    raise ReleaseError("Candidate artifact changed since workflow admission")
                with TemporaryDirectory(prefix="netfleet-macos-publish-") as directory:
                    directory = Path(directory)
                    download_candidate(args.repo, asset, directory)
                    publish(args.repo, args.tag, directory, qualification)
        else:
            if args.qualification is None:
                raise ReleaseError("--artifacts requires a macOS VM --qualification receipt")
            qualification = json.loads(args.qualification.read_text())
            if not isinstance(qualification, dict):
                raise ReleaseError("Invalid macOS VM qualification receipt")
            publish(args.repo, args.tag, args.artifacts, qualification)
    except (OSError, TypeError, ValueError, BadZipFile, ReleaseError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
