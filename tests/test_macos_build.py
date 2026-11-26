"""Exercise macOS source provenance and release behavior without publication."""
import hashlib
import importlib.util
from io import BytesIO
import json
import plistlib
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(ROOT / "scripts/macos"))
spec = importlib.util.spec_from_file_location("macos_builder", ROOT / "scripts/macos/build-app.py")
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)
spec = importlib.util.spec_from_file_location("macos_release", ROOT / "scripts/macos/publish-sparkle-release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class MacOSBuildIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        self.git("init", "-q")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "user.name", "Test")
        info = self.repo / "desktop/app/Info.plist"
        info.parent.mkdir(parents=True)
        info.write_bytes(plistlib.dumps({"CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "4"}))
        (self.repo / ".gitignore").write_text(".build/\n")
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.repo), *args], text=True).strip()

    def test_delivery_records_commit_tree_and_platform_version(self):
        identity = builder.build_identity(self.repo, True)
        self.assertEqual(identity["source_commit"], self.git("rev-parse", "HEAD"))
        self.assertEqual(identity["source_tree"], self.git("rev-parse", "HEAD^{tree}"))
        self.assertEqual((identity["package_version"], identity["package_release"]), ("1.2.3", "4"))
        self.assertEqual(identity["channel"], "local")
        self.assertFalse(identity["working_tree_dirty"])
        (self.repo / ".build").mkdir()
        (self.repo / ".build/output").write_text("generated")
        builder.verify_source_unchanged(self.repo, identity)

    def test_dirty_source_is_development_only(self):
        for path in ("untracked", "desktop/app/Info.plist"):
            with self.subTest(path=path):
                target = self.repo / path
                old = target.read_bytes() if target.exists() else None
                target.write_bytes((old or b"") + b"\n")
                with self.assertRaisesRegex(RuntimeError, "clean source"):
                    builder.build_identity(self.repo, True)
                identity = builder.build_identity(self.repo)
                self.assertTrue(identity["working_tree_dirty"])
                self.assertEqual(identity["channel"], "development")
                target.write_bytes(old) if old is not None else target.unlink()

    def test_distribution_requires_clean_source(self):
        with self.assertRaisesRegex(RuntimeError, "require-clean-source"):
            builder.build_identity(self.repo, signing_identity="Developer ID Application: Fixture")
        identity = builder.build_identity(self.repo, True, "Developer ID Application: Fixture")
        self.assertEqual(identity["channel"], "distribution")
        (self.repo / "untracked").write_text("change")
        with self.assertRaisesRegex(RuntimeError, "clean source"):
            builder.build_identity(self.repo, True, "Developer ID Application: Fixture")

    def test_source_changes_during_build_are_rejected(self):
        identity = builder.build_identity(self.repo, True)
        (self.repo / "source").write_text("change")
        with self.assertRaisesRegex(RuntimeError, "Source identity changed"):
            builder.verify_source_unchanged(self.repo, identity)
        self.git("add", ".")
        self.git("commit", "-qm", "new source")
        with self.assertRaisesRegex(RuntimeError, "Source identity changed"):
            builder.verify_source_unchanged(self.repo, identity)

    def test_sparkle_plist_validation_enforces_feed_ed25519_key_and_manual_install(self):
        checked_in = plistlib.loads((ROOT / "desktop/app/Info.plist").read_bytes())
        builder.validate_sparkle_plist(checked_in)
        with self.assertRaisesRegex(RuntimeError, "SUFeedURL"):
            builder.validate_sparkle_plist({**checked_in, "SUFeedURL": "http://example.invalid/appcast.xml"})
        with self.assertRaisesRegex(RuntimeError, "SUPublicEDKey"):
            builder.validate_sparkle_plist({**checked_in, "SUPublicEDKey": "AAAA"})
        with self.assertRaisesRegex(RuntimeError, "SUAutomaticallyUpdate"):
            builder.validate_sparkle_plist({**checked_in, "SUAutomaticallyUpdate": True})
        with self.assertRaisesRegex(RuntimeError, "CFBundleVersion"):
            builder.validate_sparkle_plist({**checked_in, "CFBundleVersion": "0"})

    def test_product_versions_stay_synchronized_across_platforms(self):
        product_version = json.loads((ROOT / "product-version.json").read_text())["version"]
        makefile_text = (ROOT / "openwrt/Makefile").read_text()
        match = re.search(r"(?m)^PKG_VERSION:=(.+)$", makefile_text)
        self.assertIsNotNone(match, "PKG_VERSION missing from openwrt/Makefile")
        info = plistlib.loads((ROOT / "desktop/app/Info.plist").read_bytes())
        self.assertEqual(match.group(1), product_version)
        self.assertEqual(info["CFBundleShortVersionString"], product_version)
        self.assertEqual(info["SUFeedURL"], "https://github.com/gaofeng21cn/opl-netfleet/releases/download/macos-stable/appcast.xml")


class MacOSReleaseTests(unittest.TestCase):
    repo = "example/project"
    source = "a" * 40
    tree = "b" * 40

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.directory = Path(temp.name)
        self.tag = "v1.10.0"
        self.bundle = b"Sealed DMG"
        self.xml = self.appcast("1.10.0", 23)
        self.qualification = {
            "vm_qualified": True,
            "dmg_sha256": hashlib.sha256(self.bundle).hexdigest(),
            "build": {
                "source_commit": self.source,
                "source_tree": self.tree,
                "channel": "distribution",
                "working_tree_dirty": False,
                "package_version": "1.10.0",
                "package_release": "23",
            },
        }
        (self.directory / release.DMG).write_bytes(self.bundle)
        (self.directory / release.APPCAST).write_bytes(self.xml)
        (self.directory / (release.DMG + ".sha256")).write_text(
            f"{hashlib.sha256(self.bundle).hexdigest()}  {release.DMG}\n"
        )
        self.releases = {self.tag: {}, release.STABLE: {}}
        self.mutations = []
        self.next_id = 1
        self.fail_publish_rename = False
        self.stable_error = None
        self.lost_upload_response = None
        transport = patch.object(release, "gh", side_effect=self.gh)
        transport.start()
        self.addCleanup(transport.stop)
        public_download = patch.object(release, "urlopen", side_effect=self.public_download)
        public_download.start()
        self.addCleanup(public_download.stop)
        self.put_asset(self.tag, "openwrt.apk", b"OpenWrt")
        self.old_appcast = self.appcast("1.9.0", 22)
        self.put_asset(release.STABLE, release.APPCAST, self.old_appcast)

    def public_download(self, url, **_):
        self.assertEqual(url, f"https://github.com/{self.repo}/releases/download/{release.STABLE}/{release.APPCAST}")
        return BytesIO(self.releases[release.STABLE][release.APPCAST][1])

    def appcast(self, version, build):
        namespace = release.SPARKLE[1:-1]
        url = f"https://github.com/{self.repo}/releases/download/v{version}/{release.DMG}"
        signature = "A" * 86 + "=="
        return (
            f'<rss xmlns:sparkle="{namespace}"><channel><item>'
            f"<sparkle:version>{build}</sparkle:version>"
            f"<sparkle:shortVersionString>{version}</sparkle:shortVersionString>"
            f'<enclosure url="{url}" length="{len(self.bundle)}" sparkle:edSignature="{signature}"/>'
            "</item></channel></rss>"
        ).encode()

    def put_asset(self, tag, name, data):
        self.releases[tag][name] = (self.next_id, data)
        self.next_id += 1

    def gh(self, *args, **_):
        def result(code=0, response=b""):
            return subprocess.CompletedProcess(args, code, stdout=response, stderr=b"")

        if args[:2] == ("release", "upload"):
            tag, filename = args[2:4]
            path = Path(filename)
            if path.name in self.releases[tag]:
                return result(1)
            self.mutations.append(("upload", tag, path.name))
            self.put_asset(tag, path.name, path.read_bytes())
            return result(1 if path.name == self.lost_upload_response else 0)
        if args[:2] == ("release", "create"):
            tag, filename = args[2:4]
            self.mutations.append(("create", tag))
            self.releases[tag] = {}
            path = Path(filename)
            self.put_asset(tag, path.name, path.read_bytes())
            return result()
        if args[1] == "--include":
            tag = args[2].rsplit("/", 1)[1]
            if tag == release.STABLE and self.stable_error:
                return result(1, f"HTTP/2.0 {self.stable_error}\n\r\n".encode())
            if tag not in self.releases:
                return result(1, b"HTTP/2.0 404 Not Found\n\r\n")
            assets = [
                {"id": ident, "name": name, "size": len(data), "digest": release.digest(data), "state": "uploaded"}
                for name, (ident, data) in self.releases[tag].items()
            ]
            return result(response=b"HTTP/2.0 200 OK\n\r\n" + json.dumps({
                "tag_name": tag, "draft": False, "prerelease": False, "assets": assets,
            }).encode())
        if args[1] == "--header":
            asset_id = int(args[3].rsplit("/", 1)[1])
            for assets in self.releases.values():
                for ident, data in assets.values():
                    if ident == asset_id:
                        return result(response=data)
            return result(1)
        if args[1] == "--method":
            method, endpoint = args[2:4]
            asset_id = int(endpoint.rsplit("/", 1)[1])
            stable = self.releases[release.STABLE]
            name = next(name for name, (ident, _) in stable.items() if ident == asset_id)
            if method == "DELETE":
                del stable[name]
            elif method == "PATCH":
                target = args[5].split("=", 1)[1]
                if target in stable or self.fail_publish_rename and name.startswith("appcast-") and target == release.APPCAST:
                    return result(1)
                stable[target] = stable.pop(name)
            else:
                raise AssertionError(args)
            self.mutations.append((method, name))
            return result()
        if args[1].endswith(f"/commits/{self.tag}"):
            return result(response=f"{self.source}\n{self.tree}\n".encode())
        raise AssertionError(args)

    def publish(self):
        release.publish(self.repo, self.tag, self.directory, self.qualification)

    def test_candidate_preflight_allows_a_release_that_has_not_been_created(self):
        info = self.directory / "Info.plist"
        info.write_bytes(plistlib.dumps({"CFBundleShortVersionString": "1.10.0", "CFBundleVersion": "23"}))
        del self.releases[self.tag]
        with patch.object(sys, "argv", ["publish", "--repo", self.repo, "--tag", self.tag, "--preflight", str(info)]):
            release.main()
        self.assertEqual(self.mutations, [])

    def test_publication_requires_qualification_for_exact_dmg_and_source(self):
        qualification = self.qualification
        for changes, expected in [
            ({"vm_qualified": False}, "qualification receipt is required"),
            ({"dmg_sha256": "0" * 64}, "does not match the sealed DMG bytes"),
            ({"build": {**qualification["build"], "package_release": "24"}}, "metadata does not match"),
            ({"build": {**qualification["build"], "source_tree": "c" * 40}}, "source commit and tree"),
        ]:
            with self.subTest(changes=changes):
                self.qualification = {**qualification, **changes}
                with self.assertRaisesRegex(release.ReleaseError, expected):
                    self.publish()
                self.assertEqual(self.mutations, [])

    def test_partial_publish_retains_versioned_assets_and_reconciles_unknown_upload(self):
        self.put_asset(self.tag, release.DMG, self.bundle)
        before = self.releases[self.tag].copy()
        self.lost_upload_response = release.DMG + ".sha256"
        self.publish()
        for name, asset in before.items():
            self.assertEqual(self.releases[self.tag][name], asset)
        self.assertEqual(self.releases[release.STABLE][release.APPCAST][1], self.xml)
        self.assertEqual(set(self.releases[release.STABLE]), {release.APPCAST})
        self.mutations.clear()
        self.publish()
        self.assertEqual(self.mutations, [])

    def test_conflicting_asset_or_stable_rollback_stops_before_writes(self):
        self.put_asset(self.tag, release.DMG, b"Earlier published bytes")
        with self.assertRaisesRegex(release.ReleaseError, "Refusing to replace"):
            self.publish()
        del self.releases[self.tag][release.DMG]
        for short, build in [("1.11.0", 22), ("1.9.0", 23), ("1.9.0", 24)]:
            with self.subTest(short=short, build=build):
                self.put_asset(release.STABLE, release.APPCAST, self.appcast(short, build))
                with self.assertRaisesRegex(release.ReleaseError, "roll back"):
                    self.publish()
        self.assertEqual(self.mutations, [])

    def test_stable_transport_failure_differs_from_first_publication(self):
        self.stable_error = 503
        with self.assertRaisesRegex(release.ReleaseError, "Cannot read GitHub Release macos-stable"):
            self.publish()
        self.assertEqual(self.mutations, [])
        self.stable_error = None
        del self.releases[release.STABLE]
        self.publish()
        self.assertIn(("create", release.STABLE), self.mutations)
        self.assertEqual(self.releases[release.STABLE][release.APPCAST][1], self.xml)

    def test_failed_stable_swap_restores_previous_appcast_and_allows_retry(self):
        self.fail_publish_rename = True
        with self.assertRaisesRegex(release.ReleaseError, "stable appcast rename"):
            self.publish()
        self.assertEqual(self.releases[release.STABLE][release.APPCAST][1], self.old_appcast)
        self.fail_publish_rename = False
        self.publish()
        self.assertEqual(self.releases[release.STABLE][release.APPCAST][1], self.xml)


if __name__ == "__main__":
    unittest.main()
