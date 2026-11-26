#!/usr/bin/env python3
"""Publish the three sealed macOS assets and advance the independent Sparkle feed."""

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
from tempfile import TemporaryDirectory
from urllib.request import urlopen
import xml.etree.ElementTree as ET


DMG = "OPL-NetFleet-macos-arm64.dmg"
APPCAST = "appcast.xml"
VERSION_ASSETS = (DMG, DMG + ".sha256", APPCAST)
STABLE = "macos-stable"
PREVIOUS = "appcast.previous.xml"
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
MAX_APPCAST_BYTES = 262144


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


def verify_public_appcast(repo, xml):
    url = f"https://github.com/{repo}/releases/download/{STABLE}/{APPCAST}"
    try:
        with urlopen(url, timeout=20) as response:
            public_xml = response.read(MAX_APPCAST_BYTES + 1)
    except OSError as error:
        raise ReleaseError("Cannot read the public Sparkle feed URL") from error
    if public_xml != xml:
        raise ReleaseError("Public Sparkle feed URL serves a different appcast")


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
    verify_public_appcast(repo, xml)
    if PREVIOUS in assets:
        remove_previous(repo, assets[PREVIOUS])


def publish(repo, tag, source, directory):
    paths = {name: directory / name for name in VERSION_ASSETS}
    bundle = paths[DMG].read_bytes()
    xml = paths[APPCAST].read_bytes()
    candidate, length = appcast_version(xml, repo)
    if candidate[0] != stable_version(tag[1:], "1")[0] or length != len(bundle):
        raise ReleaseError("Sealed appcast does not match the selected release DMG")
    if paths[DMG + ".sha256"].read_text().split() != [hashlib.sha256(bundle).hexdigest(), DMG]:
        raise ReleaseError("Sealed DMG does not match its checksum")
    identities = {name: (digest(data), len(data)) for name, data in (
        (DMG, bundle), (APPCAST, xml), (DMG + ".sha256", paths[DMG + ".sha256"].read_bytes()),
    )}

    tag_commit = gh("api", f"repos/{repo}/commits/{tag}", "--jq", ".sha")
    if tag_commit.returncode or tag_commit.stdout.strip() != source.encode():
        raise ReleaseError("Release tag no longer matches the sealed macOS build")
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
    promote(repo, source, paths[APPCAST], candidate, xml)
    print(f"Verified macOS release assets and public Sparkle feed for {tag}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--source")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--preflight", type=Path, metavar="INFO_PLIST")
    group.add_argument("--artifacts", type=Path, metavar="DIRECTORY")
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
            if set(VERSION_ASSETS) & release_assets(args.repo, args.tag).keys():
                raise ReleaseError("Versioned macOS assets already exist. Retry the failed publish job with its sealed artifacts.")
            check_stable(args.repo, candidate)
        else:
            if not args.source or not re.fullmatch(r"[a-f0-9]{40}", args.source):
                raise ReleaseError("Sealed macOS build needs a release source commit")
            publish(args.repo, args.tag, args.source, args.artifacts)
    except (OSError, TypeError, ValueError, ReleaseError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
