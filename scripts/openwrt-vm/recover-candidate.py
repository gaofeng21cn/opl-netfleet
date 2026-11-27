#!/usr/bin/env python3
"""Verify the original signed candidate from an annotated OpenWrt tag run."""

import argparse
import json
import os
import re
from urllib.error import HTTPError
from urllib.request import Request, urlopen


def api(path):
    request = Request(f"{os.environ['GITHUB_API_URL']}/{path}", headers={
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {os.environ['GH_TOKEN']}",
        "X-GitHub-Api-Version": "2022-11-28",
    })
    with urlopen(request, timeout=20) as response:
        return json.load(response)


def verify_candidate(repo, tag, source, run_id, artifact_id, digest, request=api):
    if (not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag)
            or not re.fullmatch(r"[0-9a-f]{40}", source)
            or not all(re.fullmatch(r"[1-9][0-9]*", value) for value in (run_id, artifact_id))
            or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest)):
        raise ValueError("expected a product tag, exact source, numeric run/artifact IDs and SHA-256")

    base = f"repos/{repo}"
    try:
        request(f"{base}/releases/tags/{tag}")
    except HTTPError as error:
        if error.code != 404:
            raise
    else:
        raise ValueError(f"release already exists and is immutable: {tag}")

    run_path = f"{base}/actions/runs/{run_id}"
    run = request(run_path)
    if (str(run.get("id")) != run_id
            or run.get("path") != ".github/workflows/release.yml" or run.get("event") != "push"
            or run.get("head_branch") != tag or run.get("head_sha") != source
            or run.get("repository", {}).get("full_name") != repo
            or run.get("head_repository", {}).get("full_name") != repo):
        raise ValueError("candidate run must be the repository's original release workflow for this exact tag")

    jobs = request(f"{run_path}/jobs?filter=all&per_page=100")["jobs"]
    if not any(job.get("name") == "candidate / build" and job.get("status") == "completed"
               and job.get("conclusion") == "success" for job in jobs):
        raise ValueError("original candidate build has no successful job")

    artifact = request(f"{base}/actions/artifacts/{artifact_id}")
    upstream = artifact.get("workflow_run", {})
    repository_id = run["repository"]["id"]
    candidate_name = re.fullmatch(rf"netfleet-openwrt-candidate-{source}(?:-([1-9][0-9]*))?",
                                  artifact.get("name", ""))
    if (str(artifact.get("id")) != artifact_id or artifact.get("expired") is not False
            or not candidate_name or artifact.get("digest") != digest
            or str(upstream.get("id")) != run_id or upstream.get("head_branch") != tag
            or upstream.get("head_sha") != source or upstream.get("head_repository_id") != repository_id
            or upstream.get("repository_id") != repository_id):
        raise ValueError("artifact must be the original unexpired candidate and match its expected digest")
    attempt = candidate_name.group(1)
    if not attempt:
        return ""
    tools_name = f"netfleet-openwrt-publish-tools-{source}-{attempt}"
    tools = request(f"{run_path}/artifacts?name={tools_name}")["artifacts"]
    if (len(tools) != 1 or tools[0].get("expired") is not False
            or tools[0].get("name") != tools_name
            or not re.fullmatch(r"sha256:[0-9a-f]{64}", tools[0].get("digest", ""))):
        raise ValueError("candidate build's publication tools are missing or expired")
    return tools_name


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--source", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--artifact-id", required=True)
    parser.add_argument("--digest", required=True)
    args = parser.parse_args()
    tools_name = verify_candidate(os.environ["GITHUB_REPOSITORY"], args.tag, args.source,
                                  args.run_id, args.artifact_id, args.digest)
    if "GITHUB_OUTPUT" in os.environ:
        with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
            stream.write(f"publish_tools_name={tools_name}\n")
    print(f"Verified {args.tag} candidate artifact {args.artifact_id} from run {args.run_id} ({args.digest})")


if __name__ == "__main__":
    try:
        main()
    except (KeyError, OSError, ValueError) as error:
        raise SystemExit(f"OpenWrt release recovery: {error}") from error
