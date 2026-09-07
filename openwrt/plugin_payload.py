#!/usr/bin/env python3
"""Project public plugin assets using the runtime's installed-payload identity."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import stat


PAYLOAD_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
PLUGIN_ID = re.compile(r"[a-z][a-z0-9-]*")


def payload_revision(directory: Path) -> str:
    directory = Path(directory)
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError("plugin payload must be a regular directory")
    identities = hashlib.sha256()
    count = 0

    def visit(parent):
        nonlocal count
        # Match host.plugin_files(): sort each directory, then recurse in place.
        for path in sorted(parent.iterdir(), key=lambda item: item.name):
            if not PAYLOAD_NAME.fullmatch(path.name):
                raise ValueError(f"invalid plugin payload name: {path.name}")
            info = path.lstat()
            if stat.S_ISDIR(info.st_mode):
                visit(path)
            elif stat.S_ISREG(info.st_mode):
                count += 1
                if info.st_size > 1048576 or count > 512:
                    raise ValueError("plugin payload exceeds the runtime file limits")
                digest = hashlib.sha256(path.read_bytes()).hexdigest()
                relative = path.relative_to(directory).as_posix()
                identities.update(f"{digest}  {relative}\n".encode("ascii"))
            else:
                raise ValueError(f"plugin payload must not contain links or special files: {path}")

    visit(directory)
    if not count:
        raise ValueError("plugin payload is empty")
    return identities.hexdigest()


def project_resources(directory: Path, www_root: Path) -> Path | None:
    directory, www_root = Path(directory), Path(www_root)
    revision = payload_revision(directory)
    manifest = json.loads((directory / "manifest.json").read_text(encoding="utf-8"))
    identity = manifest.get("id")
    if not isinstance(identity, str) or not PLUGIN_ID.fullmatch(identity):
        raise ValueError("invalid plugin identity")
    resources = directory / "resources"
    if not resources.exists():
        return None
    if not resources.is_dir():
        raise ValueError("plugin resources must be a directory")
    destination = www_root / "luci-static/resources/netfleet/plugins" / identity / revision / "resources"
    shutil.copytree(resources, destination, dirs_exist_ok=True)
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    revision = commands.add_parser("revision", help="print the installed-payload revision")
    revision.add_argument("directory", type=Path)
    project = commands.add_parser("project", help="install public assets under the payload revision")
    project.add_argument("directory", type=Path)
    project.add_argument("www_root", type=Path)
    args = parser.parse_args()
    if args.command == "revision":
        print(payload_revision(args.directory))
    else:
        project_resources(args.directory, args.www_root)


if __name__ == "__main__":
    main()
