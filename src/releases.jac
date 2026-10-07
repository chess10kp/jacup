"""Release index schema, target detection, downloads, and SHA-256 verification.

Index shape:
{
  "versions": [
    {"version": "0.9.2", "artifacts": [
      {"os": "linux", "arch": "x86_64", "url": "https://...", "sha256": "<64 hex>"}
    ]}
  ]
}

Only https:// is accepted for normal operation; file:// exists solely for
deterministic local integration fixtures. A failing index is an error: there
is never a silent fallback to another host or branch.
"""

import json;
import os;
import sys;
import time;
import from src.errors { JacupError }
import from src.net { fetchBytes }
import from src.semver { parseVersion, sortVersionStrings }
import from src.target { TARGET_ARCH, TARGET_OS }
def checksumShellQuote(value: str) -> str {
    result: str = "'";
    for ch in value {
        if ch == "'" {
            result = result + "'\\''";
        } else {
            result = result + ch;
        }
    }
    return result + "'";
}

def urlScheme(url: str) -> str {
    marker: str = "://";
    at: int = url.find(marker);
    if at < 0 {
        return "";
    }
    return url[:at].lower();
}

def fileUrlPath(url: str) -> str {
    return url[7:] if url.startswith("file://") else "";
}

def validChecksum(text: str) -> bool {
    if len(text) != 64 {
        return False;
    }
    for ch in text {
        if not (ch >= "0" and ch <= "9") and not (ch >= "a" and ch <= "f") {
            return False;
        }
    }
    return True;
}

glob SUPPORTED_OS: list[str] = ["linux", "macos", "windows"];
glob SUPPORTED_ARCH: list[str] = ["x86_64", "aarch64"];
glob ALLOWED_SCHEMES: tuple[str, str] = ("https", "file");

obj Artifact {
    has target_os: str, arch: str, url: str, sha256: str;

    def target() -> str {
        return f"{self.target_os}-{self.arch}";
    }
}

obj Release {
    has version: str;
    has artifacts: list[Artifact];
}

obj ReleaseIndex {
    has releases: list[Release];
    has source: str;
}

obj Target {
    has target_os: str, arch: str;

    def name() -> str {
        return f"{self.target_os}-{self.arch}";
    }
}

def currentTarget() -> Target {
    return Target(target_os=detectTargetOs(), arch=detectTargetArch());
}

def detectTargetOs() -> str {
    systemName: str = "Linux";
    if sys.platform == "darwin" {
        systemName = "Darwin";
    } elif sys.platform.startswith("win") {
        systemName = "Windows";
    }
    if systemName == "Linux" { return "linux"; }
    if systemName == "Darwin" { return "macos"; }
    if systemName == "Windows" { return "windows"; }
    raise JacupError(f"unsupported operating system '{systemName}'; jacup supports: {', '.join(SUPPORTED_OS)}");
}

def detectTargetArch() -> str {
    machineName: str = TARGET_ARCH;
    if machineName in ("x86_64", "AMD64") { return "x86_64"; }
    if machineName in ("aarch64", "arm64") { return "aarch64"; }
    raise JacupError(f"unsupported CPU architecture '{machineName}'; jacup supports: {', '.join(SUPPORTED_ARCH)}");
}

def requireObject(value: any, ctx: str) -> dict[str, any] {
    if not isinstance(value, dict) {
        raise JacupError(f"malformed release index: {ctx} must be a JSON object");
    }
    return value;
}

def requireString(value: any, ctx: str) -> str {
    if not isinstance(value, str) or value == "" {
        raise JacupError(f"malformed release index: {ctx} must be a non-empty string");
    }
    return value;
}

def validateArtifactUrl(url: str, ctx: str) -> None {
    scheme: str = urlScheme(url);
    if scheme not in ALLOWED_SCHEMES {
        raise JacupError(
            f"malformed release index: {ctx} uses unsupported URL scheme "
            f"'{scheme if scheme else '(missing)'}'; only https:// (and file:// for local "
            f"fixtures) are accepted: {url}"
        );
    }
}

def isValidChecksum(text: str) -> bool {
    return validChecksum(text);
}

def decodeIndex(text: str, source: str) -> ReleaseIndex {
    try {
        data = json.loads(text);
    } except Exception as e {
        raise JacupError(f"malformed release index {source}: invalid JSON ({e})");
    }
    rootObj = requireObject(data, "root");
    versionsNode = rootObj.get("versions");
    if versionsNode is None {
        raise JacupError(f"malformed release index {source}: missing 'versions'");
    }
    if not isinstance(versionsNode, list) {
        raise JacupError(f"malformed release index {source}: 'versions' must be a JSON array");
    }
    seen: dict[str, any] = {};
    releases: list[Release] = [];
    position: int = 0;
    for item in versionsNode {
        ctx: str = f"{source}: versions[{position}]";
        rec = requireObject(item, ctx);
        versionText = requireString(rec.get("version"), f"{ctx}.version");
        try {
            parseVersion(versionText);
        } except JacupError {
            raise JacupError(
                f"malformed release index: {ctx}.version '{versionText}' is not an exact "
                "MAJOR.MINOR.PATCH[-PRERELEASE] version"
            );
        }
        if versionText in seen {
            raise JacupError(
                f"malformed release index: {ctx} duplicates version '{versionText}' "
                f"(first seen at versions[{seen[versionText]}])"
            );
        }
        seen[versionText] = position;
        artifactsNode = rec.get("artifacts");
        if artifactsNode is None {
            raise JacupError(f"malformed release index: {ctx} missing 'artifacts'");
        }
        if not isinstance(artifactsNode, list) {
            raise JacupError(f"malformed release index: {ctx}.artifacts must be a JSON array");
        }
        artifacts: list[Artifact] = [];
        targetSeen: dict[str, any] = {};
        j: int = 0;
        for artifactNode in artifactsNode {
            actx: str = f"{ctx}.artifacts[{j}]";
            a = requireObject(artifactNode, actx);
            targetOs = requireString(a.get("os"), f"{actx}.os");
            arch = requireString(a.get("arch"), f"{actx}.arch");
            url = requireString(a.get("url"), f"{actx}.url");
            validateArtifactUrl(url, actx);
            sha256 = requireString(a.get("sha256"), f"{actx}.sha256");
            if not isValidChecksum(sha256) {
                raise JacupError(
                    f"malformed release index: {actx}.sha256 must be 64 lowercase hex characters"
                );
            }
            key: str = f"{targetOs}-{arch}";
            if key in targetSeen {
                raise JacupError(
                    f"malformed release index: {ctx} has duplicate artifacts for target '{key}'"
                );
            }
            targetSeen[key] = j;
            artifacts.append(Artifact(target_os=targetOs, arch=arch, url=url, sha256=sha256));
            j = j + 1;
        }
        releases.append(Release(version=versionText, artifacts=artifacts));
        position = position + 1;
    }
    return ReleaseIndex(releases=releases, source=source);
}

def fetchIndexText(url: str) -> str {
    scheme: str = urlScheme(url);
    if scheme not in ALLOWED_SCHEMES {
        raise JacupError(
            f"unsupported URL scheme '{scheme if scheme else '(missing)'}' in '{url}'; "
            "only https:// (and file:// for local fixtures) are accepted"
        );
    }
    try {
        data: bytes;
        if scheme == "file" {
            fh = open(fileUrlPath(url), "rb");
            try {
                data = fh.read();
            } finally {
                fh.close();
            }
        } else {
            data = fetchBytes(url);
        }
        return data.decode("utf-8");
    } except JacupError {
        raise;
    } except Exception as e {
        raise JacupError(f"failed to fetch release index {url}: {e}");
    }
}

def fetchIndex(url: str) -> ReleaseIndex {
    return decodeIndex(fetchIndexText(url), url);
}

def findRelease(index: ReleaseIndex, version: str) -> Release | None {
    for release in index.releases {
        if release.version == version {
            return release;
        }
    }
    return None;
}

def selectArtifact(release: Release, target: Target) -> Artifact {
    for artifact in release.artifacts {
        if artifact.target_os == target.target_os and artifact.arch == target.arch {
            return artifact;
        }
    }
    available: list[str] = [];
    for artifact in release.artifacts {
        available.append(artifact.target());
    }
    available.sort();
    suffix: str = f" (available: {', '.join(available)})" if available else " (no artifacts published)";
    raise JacupError(
        f"release {release.version} has no artifact for target '{target.name()}'{suffix}"
    );
}

def availableVersionStrings(index: ReleaseIndex) -> list[str] {
    names: list[str] = [];
    for release in index.releases {
        names.append(release.version);
    }
    return sortVersionStrings(names);
}

def latestVersionString(index: ReleaseIndex, target: Target) -> str | None {
    # Newest release with an artifact for `target`: highest stable, falling
    # back to the highest prerelease when the index has no stable builds.
    usable: list[str] = [];
    for release in index.releases {
        for artifact in release.artifacts {
            if artifact.target_os == target.target_os and artifact.arch == target.arch {
                usable.append(release.version);
                break;
            }
        }
    }
    if not usable {
        return None;
    }
    ranked: list[str] = sortVersionStrings(usable);
    stables: list[str] = [];
    for v in ranked {
        if parseVersion(v).isRelease() {
            stables.append(v);
        }
    }
    return stables[-1] if stables else ranked[-1];
}

def sha256File(path: str) -> str {
    outputPath: str = os.path.join(
        "/tmp",
        f"jacup-sha-{os.getpid()}-{int(time.time() * 1000000)}"
    );
    tool: str = "sha256sum" if TARGET_OS == "linux" else "shasum -a 256";
    command: str = tool + " " + checksumShellQuote(path) + " > " + checksumShellQuote(outputPath);
    if os.system(command) != 0 {
        raise JacupError(f"cannot read {path} to compute its checksum");
    }
    fh = open(outputPath, "r");
    try {
        raw: str = fh.read().strip();
    } finally {
        fh.close();
    }
    os.unlink(outputPath);
    parts: list[str] = raw.split();
    if not parts {
        raise JacupError(f"checksum command returned no digest for {path}");
    }
    return parts[0];
}

def downloadTo(url: str, destPath: str) -> None {
    scheme: str = urlScheme(url);
    if scheme not in ALLOWED_SCHEMES {
        raise JacupError(
            f"unsupported URL scheme '{scheme if scheme else '(missing)'}' in '{url}'; "
            "only https:// (and file:// for local fixtures) are accepted"
        );
    }
    try {
        data: bytes;
        if scheme == "file" {
            fh = open(fileUrlPath(url), "rb");
            try {
                data = fh.read();
            } finally {
                fh.close();
            }
        } else {
            data = fetchBytes(url);
        }
        out = open(destPath, "wb");
        try {
            out.write(data);
        } finally {
            out.close();
        }
    } except JacupError {
        raise;
    } except Exception as e {
        raise JacupError(f"failed to download {url}: {e}");
    }
}
