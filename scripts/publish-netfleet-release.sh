#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf '%s\n' 'Usage: scripts/publish-netfleet-release.sh --tag <tag> --candidate <dir> --qualification <receipt.json> [--compat-candidate <dir> --compat-qualification <receipt.json> --apk <apk>] [--repo <owner/name>] [--require-existing-tag <tag-object>]'
}

die() {
  printf 'publish-netfleet-release: %s\n' "$1" >&2
  exit 1
}

tag=''
candidate=''
qualification=''
repo=''
compat_candidate=''
compat_qualification=''
apk_tool=''
expected_tag_object=''
while (($#)); do
  case "$1" in
    --tag) (($# >= 2)) || die '--tag requires a value'; tag=$2; shift 2;;
    --candidate) (($# >= 2)) || die '--candidate requires a directory'; candidate=$2; shift 2;;
    --qualification) (($# >= 2)) || die '--qualification requires a receipt'; qualification=$2; shift 2;;
    --repo) (($# >= 2)) || die '--repo requires owner/name'; repo=$2; shift 2;;
    --compat-candidate) (($# >= 2)) || die '--compat-candidate requires a directory'; compat_candidate=$2; shift 2;;
    --compat-qualification) (($# >= 2)) || die '--compat-qualification requires a receipt'; compat_qualification=$2; shift 2;;
    --apk) (($# >= 2)) || die '--apk requires an executable'; apk_tool=$2; shift 2;;
    --require-existing-tag)
      (($# >= 2)) && [[ "$2" =~ ^[0-9a-f]{40}$ ]] || die '--require-existing-tag requires a Git tag object ID'
      expected_tag_object=$2
      shift 2
      ;;
    -h|--help) usage; exit 0;;
    *) die "unknown option: $1";;
  esac
done

[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'tag must use vMAJOR.MINOR.PATCH'
candidate=$(cd "$candidate" 2>/dev/null && pwd) || die 'candidate directory is unavailable'
qualification=$(cd "$(dirname "$qualification")" 2>/dev/null && pwd)/$(basename "$qualification") ||
  die 'qualification receipt is unavailable'
[[ -f "$qualification" ]] || die 'qualification receipt is unavailable'
[[ ! -e "$candidate/optional-packages.json" ]] ||
  die 'supply the default candidate plus --compat-candidate and --compat-qualification; precomposed optional publication is not admitted'
command -v gh >/dev/null 2>&1 || die 'gh is required'
command -v git >/dev/null 2>&1 || die 'git is required'
command -v curl >/dev/null 2>&1 || die 'curl is required'

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

publication=$candidate
publication_work=''
upload_work=''
readback=''
draft_created=0
cleanup() {
  if [[ "$draft_created" == 1 ]]; then
    gh release delete "$tag" --repo "$repo" --yes >/dev/null 2>&1 || true
  fi
  [[ -z "$publication_work" ]] || rm -rf -- "$publication_work"
  [[ -z "$upload_work" ]] || rm -rf -- "$upload_work"
  [[ -z "$readback" ]] || rm -rf -- "$readback"
}
trap cleanup EXIT
if [[ -n "$compat_candidate$compat_qualification$apk_tool" ]]; then
  [[ -n "$compat_candidate" && -f "$compat_qualification" && -x "$apk_tool" ]] ||
    die 'full publication requires --compat-candidate, --compat-qualification and --apk'
  publication_work=$(mktemp -d "${TMPDIR:-/tmp}/netfleet-publication.XXXXXX")
  publication="$publication_work/release"
  python3 "$repo_dir/scripts/https-compat/release.py" \
    --packages "$candidate" --base-qualification "$qualification" \
    --candidate "$compat_candidate" --qualification "$compat_qualification" \
    --apk "$apk_tool" --output "$publication" >/dev/null
fi

remote_main=$(git -C "$repo_dir" ls-remote --refs origin refs/heads/main | awk 'NR == 1 { print $1 }')
[[ -n "$remote_main" ]] || die 'cannot resolve canonical main'
# Fetch the observed commit, so later unrelated platform changes do not invalidate a qualified candidate.
git -C "$repo_dir" fetch --no-tags origin "$remote_main"
git -C "$repo_dir" merge-base --is-ancestor "$source_commit" "$remote_main" ||
  die 'candidate source has not been absorbed into canonical main'
if [[ -f "$publication/optional-packages.json" ]]; then
  while read -r optional_commit optional_tree; do
    [[ "$(git -C "$repo_dir" rev-parse "$optional_commit^{tree}")" == "$optional_tree" ]] ||
      die 'optional package source tree does not match Git'
    git -C "$repo_dir" merge-base --is-ancestor "$optional_commit" "$remote_main" ||
      die 'optional package source has not been absorbed into canonical main'
  done < <(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print("\n".join(r["source_commit"]+" "+r["source_tree"] for r in m["artifacts"]))' "$publication/optional-packages.json")
fi
release_state=$(gh release view "$tag" --repo "$repo" --json tagName 2>/dev/null || true)
[[ -z "$release_state" ]] || die "release already exists and is immutable: $tag"

remote_tag=$(git -C "$repo_dir" ls-remote --refs origin "refs/tags/$tag" | awk 'NR == 1 { print $1 }')
[[ -z "$expected_tag_object" || "$remote_tag" == "$expected_tag_object" ]] ||
  die 'required annotated release tag is missing or has changed'
if [[ -n "$remote_tag" ]]; then
  git -C "$repo_dir" fetch --quiet origin "refs/tags/$tag"
  if [[ -n "$expected_tag_object" ]]; then
    [[ "$(git -C "$repo_dir" rev-parse FETCH_HEAD)" == "$expected_tag_object" &&
       "$(git -C "$repo_dir" cat-file -t FETCH_HEAD)" == tag ]] ||
      die 'required annotated release tag is missing or has changed'
  fi
  [[ "$(git -C "$repo_dir" rev-parse 'FETCH_HEAD^{commit}')" == "$source_commit" ]] || die 'release tag points to another commit'
else
  if git -C "$repo_dir" rev-parse --verify "refs/tags/$tag" >/dev/null 2>&1; then
    [[ "$(git -C "$repo_dir" rev-list -n 1 "$tag")" == "$source_commit" ]] || die 'local tag points to another commit'
  else
    git -C "$repo_dir" tag -a "$tag" -m "NetFleet $tag" "$source_commit"
  fi
  git -C "$repo_dir" push origin "refs/tags/$tag"
fi

gh release create "$tag" --repo "$repo" --verify-tag --draft \
  --title "NetFleet $tag" \
  --notes "Versioned NetFleet OpenWrt packages qualified for installation and runtime behavior on ARM64 OpenWrt 25.12.5."
draft_created=1
release_id=$(gh release view "$tag" --repo "$repo" --json databaseId --jq .databaseId)
[[ "$release_id" =~ ^[0-9]+$ ]] || die 'cannot resolve draft release id'
upload_work=$(mktemp -d "${TMPDIR:-/tmp}/netfleet-release-upload.XXXXXX")
chmod 700 "$upload_work"
curl_auth="$upload_work/auth.cfg"
upload_resp="$upload_work/response.json"
(
  umask 077
  token=$(gh auth token)
  [[ -n "$token" ]] || exit 1
  printf 'header = "Authorization: Bearer %s"\n' "$token" > "$curl_auth"
) || die 'cannot resolve GitHub auth token'
readback_patterns=()
for asset in "$publication"/*; do
  [[ -f "$asset" ]] || continue
  asset_name=$(basename "$asset")
  readback_patterns+=(--pattern "$asset_name")
  asset_size=$(wc -c < "$asset" | tr -d '[:space:]')
  encoded_name=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$asset_name")
  uploaded=0
  for attempt in 1 2 3 4; do
    if (( attempt > 1 )); then
      while read -r stale_id; do
        [[ "$stale_id" =~ ^[0-9]+$ ]] || continue
        gh api -X DELETE "repos/$repo/releases/assets/$stale_id" >/dev/null 2>&1 || true
      done < <(gh api "repos/$repo/releases/$release_id/assets?per_page=100" | python3 -c '
import json, sys
target = sys.argv[1]
for item in json.load(sys.stdin):
    if isinstance(item, dict) and item.get("name") == target and item.get("id") is not None:
        print(item["id"])
' "$asset_name")
    fi
    rm -f -- "$upload_resp"
    curl_rc=0
    upload_stats=$(curl -sS --http1.1 \
      --config "$curl_auth" \
      --connect-timeout 20 \
      --speed-time 45 \
      --speed-limit 2048 \
      --max-time 900 \
      -X POST \
      -H 'Accept: application/vnd.github+json' \
      -H 'X-GitHub-Api-Version: 2022-11-28' \
      -H 'Content-Type: application/octet-stream' \
      -H 'Expect:' \
      --data-binary "@$asset" \
      -o "$upload_resp" \
      -w '%{http_code} %{size_upload} %{speed_upload} %{time_total}' \
      "https://uploads.github.com/repos/$repo/releases/$release_id/assets?name=$encoded_name") || curl_rc=$?
    read -r http_code sent_bytes speed_bps elapsed_s <<<"${upload_stats:-000 0 0 0}"
    if [[ "$curl_rc" == 0 && "$http_code" == 201 ]] && python3 - "$upload_resp" "$asset_name" "$asset_size" <<'PY'
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text())
if not (
    isinstance(data, dict)
    and data.get("state") == "uploaded"
    and data.get("name") == sys.argv[2]
    and int(data.get("size", -1)) == int(sys.argv[3])
):
    raise SystemExit(1)
PY
    then
      printf 'publish-netfleet-release: uploaded %s (%s B, %s B/s, %ss)\n' \
        "$asset_name" "$asset_size" "${speed_bps:-0}" "${elapsed_s:-0}" >&2
      uploaded=1
      break
    fi
    printf 'publish-netfleet-release: upload attempt %s failed for %s (curl_rc=%s http=%s sent=%s speed=%sB/s time=%ss)\n' \
      "$attempt" "$asset_name" "$curl_rc" "${http_code:-none}" "${sent_bytes:-0}" "${speed_bps:-0}" "${elapsed_s:-0}" >&2
    sleep 3
  done
  [[ "$uploaded" == 1 ]] || die "failed to upload release asset: $asset_name"
done
gh release edit "$tag" --repo "$repo" --draft=false
draft_created=0

readback=$(mktemp -d "${TMPDIR:-/tmp}/netfleet-release-readback.XXXXXX")
downloaded=0
for attempt in 1 2 3; do
  rm -rf -- "$readback"/*
  if GODEBUG=http2client=0 gh release download "$tag" --repo "$repo" --dir "$readback" "${readback_patterns[@]}"; then
    downloaded=1
    break
  fi
  sleep 3
done
[[ "$downloaded" == 1 ]] || die 'failed to download published release for readback'
"$repo_dir/scripts/verify-netfleet-release.py" \
  --directory "$readback" --expected-directory "$publication" \
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
