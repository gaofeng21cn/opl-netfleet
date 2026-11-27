import gzip
import hashlib
import http.server
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading
import unittest


ROOT = Path(__file__).resolve().parents[1]


def load_script(name: str, rel: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / rel)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


USIGN = load_script("netfleet_usign", "scripts/netfleet_usign.py")
BUNDLE = load_script("netfleet_bundle_build", "scripts/netfleet-bundle-build.py")
IPK = load_script("netfleet_ipk_build", "scripts/netfleet-ipk-build.py")


class IpkBundleTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="netfleet-ipk-bundle-test-")
        self.root = Path(self.tmp.name)
        self.key = self.root / "signing-ed25519.pem"
        USIGN.generate_private_key(self.key)

    def tearDown(self):
        self.tmp.cleanup()

    def test_usign_sign_and_verify_detects_tampering(self):
        pub = self.root / "test.pub"
        msg = self.root / "payload.txt"
        sig = self.root / "payload.txt.sig"
        msg.write_bytes(b"hello openwrt usign\n")
        keyid = USIGN.write_usign_pubkey(self.key, pub)
        self.assertRegex(keyid, r"^[0-9a-f]{16}$")
        USIGN.sign_file(self.key, msg, sig)
        self.assertTrue(USIGN.verify_file(pub, msg, sig))
        msg.write_bytes(b"tampered openwrt usign\n")
        self.assertFalse(USIGN.verify_file(pub, msg, sig))

    def test_bundle_is_deterministic_pure_source_and_signed(self):
        out1 = self.root / "bundle1"
        out2 = self.root / "bundle2"
        commit = "a" * 40
        tree = "b" * 40
        s1 = BUNDLE.build_bundle(
            ROOT, out1, version="0.9.32", source_commit=commit, source_tree=tree, sign_key=self.key
        )
        s2 = BUNDLE.build_bundle(
            ROOT, out2, version="0.9.32", source_commit=commit, source_tree=tree, sign_key=self.key
        )
        self.assertEqual(s1["archive_sha256"], s2["archive_sha256"])
        self.assertEqual(s1["manifest_sha256"], s2["manifest_sha256"])
        manifest = json.loads((out1 / "release-manifest.json").read_text())
        self.assertEqual(manifest["schema"], "opl-netfleet-release-bundle.v1")
        self.assertEqual(manifest["source_commit"], commit)
        self.assertTrue(USIGN.verify_file(out1 / "opl-netfleet-bundle.pub", out1 / "release-manifest.json", out1 / "release-manifest.json.sig"))
        self.assertIn("runtime/plugins/components/lib/control.uc", manifest["files"])
        self.assertNotIn("runtime/plugins/https-compat/manifest.json", manifest["files"])
        with tarfile.open(out1 / s1["archive"], "r:gz") as tf:
            members = tf.getmembers()
            self.assertFalse(any(m.issym() or m.islnk() for m in members))
            names = {m.name for m in members}
            self.assertIn("share/build.json", names)
            self.assertIn("runtime/main.uc", names)

    def test_ipk_feed_build_and_archive_layout(self):
        feed = self.root / "feed"
        manifest = IPK.build_ipk_feed(
            ROOT, feed, version="0.9.32", skip_core=True, sign_key=self.key
        )
        self.assertEqual(manifest["package_format"], "ipk")
        self.assertEqual(manifest["package_arch"], "all")
        self.assertTrue((feed / "Packages").is_file())
        self.assertTrue((feed / "Packages.gz").is_file())
        self.assertTrue((feed / "Packages.sig").is_file())
        self.assertTrue(USIGN.verify_file(feed / "opl-netfleet-usign.pub", feed / "Packages", feed / "Packages.sig"))

        shell_ipk = feed / manifest["artifact_files"]["opl-netfleet"]
        luci_ipk = feed / manifest["artifact_files"]["luci-app-netfleet"]
        self.assertTrue(shell_ipk.is_file())
        self.assertTrue(luci_ipk.is_file())

        with tarfile.open(shell_ipk, "r:gz") as outer:
            self.assertEqual(outer.getnames(), ["./debian-binary", "./data.tar.gz", "./control.tar.gz"])
            self.assertEqual(outer.extractfile("./debian-binary").read(), b"2.0\n")
            ctl_bytes = outer.extractfile("./control.tar.gz").read()
            with tarfile.open(fileobj=io.BytesIO(ctl_bytes), mode="r:gz") as ctl:
                control_txt = ctl.extractfile("./control").read().decode("utf-8")
                self.assertIn("Package: opl-netfleet\n", control_txt)
                self.assertIn("Architecture: all\n", control_txt)
                self.assertIn("Provides: netfleet-plugin-api-v1\n", control_txt)
                self.assertIn("./postinst", ctl.getnames())
            data_bytes = outer.extractfile("./data.tar.gz").read()
            with tarfile.open(fileobj=io.BytesIO(data_bytes), mode="r:gz") as data:
                names = set(data.getnames())
                self.assertIn("./usr/share/opl-netfleet/releases/0.9.32/release-manifest.json", names)
                self.assertIn("./usr/share/opl-netfleet/shell.json", names)
                self.assertIn("./usr/share/opl-netfleet/keys/release-bundle.pub", names)

        with tarfile.open(luci_ipk, "r:gz") as outer:
            data_bytes = outer.extractfile("./data.tar.gz").read()
            with tarfile.open(fileobj=io.BytesIO(data_bytes), mode="r:gz") as data:
                bundle_link = data.getmember("./www/luci-static/resources/netfleet/bundle")
                self.assertTrue(bundle_link.issym())
                self.assertEqual(bundle_link.linkname, "/usr/share/opl-netfleet/current/www")

    def test_install_script_opkg_flow_and_signature_guard(self):
        feed = self.root / "feed"
        manifest = IPK.build_ipk_feed(ROOT, feed, version="0.9.32", skip_core=True, sign_key=self.key)

        fake_bin = self.root / "bin"
        fake_etc = self.root / "etc"
        fake_log = self.root / "opkg.log"
        fake_bin.mkdir()
        (fake_etc / "opkg/keys").mkdir(parents=True)
        (fake_etc / "opl-netfleet").mkdir(parents=True)
        for utility in ("awk", "cat", "chmod", "cp", "curl", "dirname", "grep", "gzip", "id", "mkdir", "mktemp", "mv", "openssl", "printf", "readlink", "rm", "tr"):
            resolved = shutil.which(utility)
            if resolved:
                (fake_bin / utility).symlink_to(resolved)

        (fake_bin / "uci").write_text("#!/bin/sh\nexit 0\n")
        (fake_bin / "jsonfilter").write_text("#!/bin/sh\nexit 0\n")
        (fake_bin / "usign").write_text(
            f"""#!/bin/sh
mode=$1; shift
case "$mode" in
  -F)
    pub=
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "-p" ]; then pub=$2; shift 2; else shift; fi
    done
    "{sys.executable}" -c 'import hashlib,sys, pathlib; raw=__import__("base64").b64decode(pathlib.Path(sys.argv[1]).read_text().splitlines()[1]); print(raw[2:10].hex())' "$pub"
    ;;
  -V)
    pub=; sig=; msg=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -p) pub=$2; shift 2 ;;
        -x) sig=$2; shift 2 ;;
        -m) msg=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    exec "{sys.executable}" "{ROOT / 'scripts/netfleet_usign.py'}" verify --pub "$pub" --sig "$sig" --in "$msg"
    ;;
  *) exit 1 ;;
esac
"""
        )
        (fake_bin / "opkg").write_text(
            f"""#!/bin/sh
echo "opkg $*" >> "{fake_log}"
if [ "$1" = "list-installed" ]; then
  exit 1
fi
exit 0
"""
        )
        for script_path in (fake_bin / "uci", fake_bin / "jsonfilter", fake_bin / "usign", fake_bin / "opkg"):
            script_path.chmod(0o755)

        class QuietHandler(http.server.SimpleHTTPRequestHandler):
            def __init__(self, *args, **kwargs):
                super().__init__(*args, directory=str(feed), **kwargs)

            def log_message(self, format, *args):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), QuietHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            port = server.server_address[1]
            env = {
                "PATH": str(fake_bin),
                "HOME": os.environ["HOME"],
                "NETFLEET_INSTALL_TESTING": "1",
                "NETFLEET_ALLOW_INSECURE_FEED": "1",
                "NETFLEET_FEED_BASE": f"http://127.0.0.1:{port}",
                "NETFLEET_OPKG_KEYS_DIR": str(fake_etc / "opkg/keys"),
                "NETFLEET_OPKG_CUSTOMFEEDS_FILE": str(fake_etc / "opkg/customfeeds.conf"),
                "NETFLEET_RELEASE_FEED_FILE": str(fake_etc / "opl-netfleet/release-feed.json"),
            }
            res = subprocess.run(["/bin/sh", str(ROOT / "scripts/install-netfleet.sh")], env=env, capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, msg=res.stderr)
            self.assertTrue((fake_etc / "opkg/keys" / manifest["usign_key_id"]).is_file())
            self.assertIn(f"src/gz opl_netfleet http://127.0.0.1:{port}", (fake_etc / "opkg/customfeeds.conf").read_text())
            feed_meta = json.loads((fake_etc / "opl-netfleet/release-feed.json").read_text())
            self.assertEqual(feed_meta["url"], f"http://127.0.0.1:{port}")
            ops = fake_log.read_text().splitlines()
            self.assertIn("opkg update", ops)
            self.assertTrue(any(line.startswith("opkg install ") and "opl-netfleet" in line and "mihomo-meta" in line for line in ops))

            # Tampered signature must fail before rewriting customfeeds.
            (fake_etc / "opkg/customfeeds.conf").write_text("src/gz keep http://keep.invalid\n")
            (feed / "Packages.sig").write_text("untrusted comment: bad\n" + "A" * 100 + "\n")
            bad_res = subprocess.run(["/bin/sh", str(ROOT / "scripts/install-netfleet.sh")], env=env, capture_output=True, text=True)
            self.assertNotEqual(bad_res.returncode, 0)
            self.assertEqual((fake_etc / "opkg/customfeeds.conf").read_text(), "src/gz keep http://keep.invalid\n")
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)


if __name__ == "__main__":
    unittest.main()
