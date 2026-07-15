#!/usr/bin/env python3
import json
import os
import re
import sys
import urllib.request


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: github_release_asset.py <owner/repo> <asset-regex>", file=sys.stderr)
        return 2

    repo = sys.argv[1]
    pattern = re.compile(sys.argv[2])
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "dotfiles-bootstrap",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"

    request = urllib.request.Request(
        f"https://api.github.com/repos/{repo}/releases/latest",
        headers=headers,
    )

    with urllib.request.urlopen(request, timeout=30) as response:
        payload = json.load(response)

    for asset in payload.get("assets", []):
        name = asset.get("name", "")
        if pattern.search(name):
            print(asset["browser_download_url"])
            return 0

    print(f"no asset matched pattern {pattern.pattern!r} for {repo}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
