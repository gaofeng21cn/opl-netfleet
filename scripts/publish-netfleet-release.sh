#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf '%s\n' 'Usage: scripts/publish-netfleet-release.sh --tag <tag> --candidate <dir> --qualification <receipt.json> [--repo <owner/name>]'
}

die() {
  printf 'publish-netfleet-release: %s\n' "$1" >&2
  exit 1
}

tag=''
candidate=''
qualification=''
repo=''
while (($#)); do
  case "$1" in
    --tag) (($# >= 2)) || die '--tag requires a value'; tag=$2; shift 2;;
    --candidate) (($# >= 2)) || die '--candidate requires a directory'; candidate=$2; shift 2;;
    --qualification) (($# >= 2)) || die '--qualification requires a receipt'; qualification=$2; shift 2;;
    --repo) (($# >= 2)) || die '--repo requires owner/name'; repo=$2; shift 2;;
    -h|--help) usage; exit 0;;
    *) die "unknown option: $1";;
  esac
done

[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'tag must use vMAJOR.MINOR.PATCH'
candidate=$(cd "$candidate" 2>/dev/null && pwd) || die 'candidate directory is unavailable'
qualification=$(cd "$(dirname "$qualification")" 2>/dev/null && pwd)/$(basename "$qualification") ||
  die 'qualification receipt is unavailable'
[[ -f "$qualification" ]] || die 'qualification receipt is unavailable'
command -v gh >/dev/null 2>&1 || die 'gh is required'
command -v git >/dev/null 2>&1 || die 'git is required'

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ -z "$repo" ]]; then
  repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) || die 'cannot resolve GitHub repository'
fi
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die 'invalid GitHub repository'

identity=$(python3 - "$candidate/manifest.json" <<'PY'
import json, sys
from pathlib import Path
m = json.loads(Path(sys.argv[1]).read_text())
values = []
for key in ("source_commit", "source_tree", "package_version"):
    value = m.get(key)
    if not isinstance(value, str) or not value or any(c.isspace() for c in value):
        raise SystemExit(f"candidate manifest is missing {key}")
    values.append(value)
print(" ".join(values))
PY
) || die 'candidate manifest identity is unreadable'
read -r source_commit source_tree package_version extra <<<"$identity"
[[ -n "$source_commit" && -n "$source_tree" && -n "$package_version" && -z "${extra:-}" ]] ||
  die 'candidate manifest identity is unreadable'
[[ "$tag" == "v$package_version" ]] || die 'tag does not match package version'

"$repo_dir/scripts/verify-netfleet-release.py" \
  --directory "$candidate" --source-commit "$source_commit" --source-tree "$source_tree" >/dev/null
manifest_sha=$(shasum -a 256 "$candidate/manifest.json" | awk '{print $1}')
python3 - "$qualification" "$source_commit" "$source_tree" "$manifest_sha" <<'PY'
import json, sys
from pathlib import Path
r = json.loads(Path(sys.argv[1]).read_text())
package = r.get("package")
if not (
    r.get("schema") == "opl-netfleet-openwrt-vm-qualification.v2"
    and r.get("qualified") is True
    and r.get("package_qualified") is True
    and r.get("source_commit") == sys.argv[2]
    and r.get("source_tree") == sys.argv[3]
    and isinstance(package, dict)
    and package.get("manifest_sha256") == sys.argv[4]
):
    raise SystemExit("package VM qualification does not bind the candidate bytes")
PY

remote_main=$(git -C "$repo_dir" ls-remote --refs origin refs/heads/main | awk 'NR == 1 { print $1 }')
[[ "$remote_main" == "$source_commit" ]] || die 'candidate source is not current canonical main'
release_state=$(gh release view "$tag" --repo "$repo" --json tagName 2>/dev/null || true)
[[ -z "$release_state" ]] || die "release already exists and is immutable: $tag"

remote_tag=$(git -C "$repo_dir" ls-remote --refs origin "refs/tags/$tag" | awk 'NR == 1 { print $1 }')
if [[ -n "$remote_tag" ]]; then
  [[ "$remote_tag" == "$source_commit" ]] || die 'release tag points to another commit'
else
  if git -C "$repo_dir" rev-parse --verify "refs/tags/$tag" >/dev/null 2>&1; then
    [[ "$(git -C "$repo_dir" rev-list -n 1 "$tag")" == "$source_commit" ]] || die 'local tag points to another commit'
  else
    git -C "$repo_dir" tag "$tag" "$source_commit"
  fi
  git -C "$repo_dir" push origin "refs/tags/$tag"
fi

gh release create "$tag" --repo "$repo" --verify-tag \
  --title "NetFleet $tag" \
  --notes "版本化 NetFleet OpenWrt 软件包，已通过 ARM64 OpenWrt 25.12.5 软件包与运行验收。" \
  "$candidate"/*

readback=$(mktemp -d "${TMPDIR:-/tmp}/netfleet-release-readback.XXXXXX")
trap 'rm -rf -- "$readback"' EXIT
gh release download "$tag" --repo "$repo" --dir "$readback"
"$repo_dir/scripts/verify-netfleet-release.py" \
  --directory "$readback" --expected-directory "$candidate" \
  --source-commit "$source_commit" --source-tree "$source_tree" >/dev/null
release_url=$(gh release view "$tag" --repo "$repo" --json isDraft,isPrerelease,url \
  --jq 'select(.isDraft == false and .isPrerelease == false) | .url')
[[ -n "$release_url" ]] || die 'public release readback is not final'
python3 - "$tag" "$source_commit" "$source_tree" "$manifest_sha" "$release_url" <<'PY'
import json, sys
print(json.dumps({
    "ok": True,
    "tag": sys.argv[1],
    "source_commit": sys.argv[2],
    "source_tree": sys.argv[3],
    "manifest_sha256": sys.argv[4],
    "url": sys.argv[5],
}, sort_keys=True))
PY
