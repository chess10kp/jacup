"""Generate jacup's release index from upstream jaseci-labs/jac GitHub releases.

Enumerates stable upstream releases, resolves the per-target `jac` binary
assets (jac-<version>-<target>), and records each artifact's download URL and
SHA-256. The checksum comes from the upstream `.sha256` sidecar asset when
present; otherwise the artifact itself is downloaded and hashed.

Usage: gen_index.py [--repo OWNER/NAME] [--limit N] [--out PATH]
Prints "index unchanged" or "index updated: ..." on stdout.
"""

import argparse
import hashlib
import json
import os
import re
import urllib.request

UPSTREAM = "jaseci-labs/jac"
SUPPORTED_TARGETS = [
    "linux-x86_64",
    "linux-aarch64",
    "macos-aarch64",
    "macos-x86_64",
    "windows-x86_64",
]
TAG_RE = r"^v?\d+\.\d+\.\d+$"


def api_token():
    return os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or ""


def api_headers():
    headers = {"Accept": "application/vnd.github+json"}
    token = api_token()
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return headers


def fetch_json(url):
    req = urllib.request.Request(url, headers=api_headers())
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.loads(resp.read().decode("utf-8"))


def fetch_text(url):
    req = urllib.request.Request(url, headers=api_headers())
    with urllib.request.urlopen(req, timeout=60) as resp:
        return resp.read().decode("utf-8")


def stream_sha256(url):
    req = urllib.request.Request(url, headers=api_headers())
    digest = hashlib.sha256()
    with urllib.request.urlopen(req, timeout=600) as resp:
        while True:
            chunk = resp.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def parse_tag(tag):
    if not re.fullmatch(TAG_RE, tag):
        return None
    parts = tag.lstrip("v").split(".")
    return (int(parts[0]), int(parts[1]), int(parts[2]))


def stable_releases(repo, limit):
    out = []
    page = 1
    while len(out) < limit and page <= 3:
        releases = fetch_json(
            f"https://api.github.com/repos/{repo}/releases?per_page=50&page={page}"
        )
        if not releases:
            break
        for rel in releases:
            if rel.get("draft") or rel.get("prerelease"):
                continue
            if parse_tag(rel["tag_name"]) is None:
                continue
            out.append(rel)
            if len(out) >= limit:
                break
        page += 1
    out.sort(key=lambda rel: parse_tag(rel["tag_name"]), reverse=True)
    return out


def sidecar_sha256(assets, binary_asset):
    wanted = binary_asset["name"] + ".sha256"
    for asset in assets:
        if asset["name"] == wanted:
            text = fetch_text(asset["browser_download_url"]).strip()
            token = text.split()[0] if text else ""
            if re.fullmatch(r"[0-9a-f]{64}", token):
                return token
            return None
    return None


def build_index(repo, limit):
    versions = []
    for rel in stable_releases(repo, limit):
        tag = rel["tag_name"]
        version = tag.lstrip("v")
        assets = rel.get("assets") or []
        by_name = {a["name"]: a for a in assets}
        artifacts = []
        for target in SUPPORTED_TARGETS:
            name = f"jac-{version}-{target}"
            binary_asset = by_name.get(name)
            if binary_asset is None:
                continue
            sha = sidecar_sha256(assets, binary_asset)
            if sha is None:
                sha = stream_sha256(binary_asset["browser_download_url"])
            os_name, arch = target.split("-", 1)
            artifacts.append(
                {
                    "os": os_name,
                    "arch": arch,
                    "url": binary_asset["browser_download_url"],
                    "sha256": sha,
                }
            )
        if artifacts:
            versions.append({"version": version, "artifacts": artifacts})
    return {"versions": versions}


def main():
    parser = argparse.ArgumentParser(description="Generate the jacup release index")
    parser.add_argument("--repo", default=UPSTREAM, help="upstream OWNER/NAME")
    parser.add_argument("--limit", type=int, default=5, help="max releases in index")
    parser.add_argument("--out", default="index.json", help="output path")
    args = parser.parse_args()

    index = build_index(args.repo, args.limit)
    payload = json.dumps(index, indent=2) + "\n"

    if os.path.exists(args.out):
        with open(args.out, "r") as rf:
            existing = rf.read()
        if existing == payload:
            print("index unchanged")
            return
    with open(args.out, "w") as wf:
        wf.write(payload)
    total = sum(len(v["artifacts"]) for v in index["versions"])
    print(f"index updated: {len(index['versions'])} releases, {total} artifacts")


if __name__ == "__main__":
    main()
