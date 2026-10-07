"""Atomic installation and removal of released Jac versions.

Install pipeline: download to a unique temporary directory, verify SHA-256,
set the executable bit on Unix, write metadata.json, then rename the finished
directory into versions/<version>. An existing version is never replaced in
place: it is accepted only when its metadata and checksum match.
"""

import json;
import os;
import time;
import from datetime { datetime, timezone }
import from src.config { loadConfig }
import from src.installed { installedVersions }
import from src.errors { JacupError }
import from src.path_core {
    binaryName,
    binaryPath,
    currentFile,
    downloadsDir,
    isWindows,
    metadataPath,
    uniqueStamp,
    versionDir,
}
import from src.releases {
    Artifact,
    ReleaseIndex,
    currentTarget,
    fetchIndex,
    findRelease,
    isValidChecksum,
    selectArtifact,
    sha256File,
    downloadTo,
    availableVersionStrings,
    Target,
}
import from src.semver { parseVersion }

glob INSTALL_TMP_COUNTER: int = 0;

def makeInstallDir(baseDir: str) -> str {
    i: int = 0;
    while i < 1000 {
        candidate: str = os.path.join(
            baseDir,
            f"install-{os.getpid()}-{uniqueStamp()}-{INSTALL_TMP_COUNTER + i}"
        );
        try {
            os.makedirs(candidate);
            return candidate;
        } except OSError {
            i += 1;
        }
    }
    raise OSError(f"could not create a temporary download directory under {baseDir}");
}
def writeInstallText(path: str, content: str) -> None {
    tmp: str = path + ".tmp-native";
    fh = open(tmp, "w");
    try {
        fh.write(content);
    } finally {
        fh.close();
    }
    if os.system("mv " + installShellQuote(tmp) + " " + installShellQuote(path)) != 0 {
        raise JacupError(f"failed to replace {path}");
    }
}
def installShellQuote(value: str) -> str {
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

def removeTree(path: str) -> None {
    if os.system("rm -rf " + installShellQuote(path)) != 0 {
        raise OSError(f"failed to remove {path}");
    }
}

def nowIso() -> str {
    return datetime.now(timezone.utc).isoformat();
}

def metadataField(raw: str, path: str, field: str) -> str {
    marker: str = "\"" + field + "\":";
    at: int = raw.find(marker);
    if at < 0 {
        raise JacupError(f"malformed metadata file {path}: missing '{field}'");
    }
    valueStart: int = at + len(marker);
    while valueStart < len(raw) {
        ch: str = raw[valueStart];
        if ch != " " and ch != "\n" and ch != "\r" and ch != "\t" {
            break;
        }
        valueStart = valueStart + 1;
    }
    if valueStart >= len(raw) or raw[valueStart] != "\"" {
        raise JacupError(f"malformed metadata file {path}: '{field}' must be a string");
    }
    valueStart = valueStart + 1;
    valueEnd: int = raw.find("\"", valueStart);
    if valueEnd < 0 {
        raise JacupError(f"malformed metadata file {path}: unterminated '{field}'");
    }
    value: str = raw[valueStart:valueEnd];
    if value == "" {
        raise JacupError(f"malformed metadata file {path}: '{field}' must be a non-empty string");
    }
    return value;
}

def loadMetadata(home: dict[str, str], version: str) -> list[str] {
    path: str = metadataPath(home, version);
    if not os.path.isfile(path) {
        raise JacupError(
            f"missing metadata file {path}; reinstall this version with "
            f"'jacup uninstall {version}' and 'jacup install {version}'"
        );
    }
    try {
        rf = open(path, "r");
        try {
            raw: str = rf.read();
        } finally {
            rf.close();
        }
    } except Exception as e {
        raise JacupError(
            f"malformed metadata file {path}: {str(e)}; repair by running "
            f"'jacup uninstall {version}' and 'jacup install {version}'"
        );
    }
    values: list[str] = [];
    for field in ["version", "target", "url", "sha256", "installed_at"] {
        values.append(metadataField(raw, path, field));
    }
    try {
        parseVersion(values[0]);
    } except JacupError {
        raise JacupError(f"malformed metadata file {path}: version '{values[0]}' is not an exact version");
    }
    if not isValidChecksum(values[3]) {
        raise JacupError(f"malformed metadata file {path}: 'sha256' must be 64 lowercase hex characters");
    }
    return values;
}

def metadataVersion(home: dict[str, str], version: str) -> str {
    meta: list[str] = loadMetadata(home, version);
    return meta[0];
}


def installVersion(home: dict[str, str], version: str, indexUrl: str) -> str {
    parseVersion(version);
    target = currentTarget();
    index: ReleaseIndex = fetchIndex(indexUrl);
    release = findRelease(index, version);
    if release is None {
        available = ", ".join(availableVersionStrings(index)) or "(none)";
        raise JacupError(
            f"version {version} not found in release index {indexUrl}; available versions: {available}"
        );
    }
    artifact = selectArtifact(release, target);
    vdir: str = versionDir(home, version);
    if os.path.exists(vdir) {
        return confirmExisting(home, version, vdir, artifact, target);
    }
    return downloadAndStage(home, version, vdir, artifact, target);
}

def confirmExisting(home: dict[str, str], version: str, vdir: str, artifact: Artifact, target: Target) -> str {
    meta = loadMetadata(home, version);
    binPath: str = binaryPath(home, version);
    matches: bool = (
        meta[0] == version
        and meta[1] == target.name()
        and meta[2] == artifact.url
        and meta[3] == artifact.sha256
    );
    if matches and os.path.isfile(binPath) and sha256File(binPath) == artifact.sha256 {
        print(f"jacup: {version} already installed at {vdir}");
        return vdir;
    }
    raise JacupError(
        f"version {version} is already installed at {vdir} with different metadata or content; "
        f"run 'jacup uninstall {version}' first if you want to replace it"
    );
}

def downloadAndStage(home: dict[str, str], version: str, vdir: str, artifact: Artifact, target: Target) -> str {
    versionsPath: str = os.path.join(home["data_dir"], "versions");
    downloadsPath: str = downloadsDir(home);
    if not os.path.isdir(versionsPath) {
        os.makedirs(versionsPath);
    }
    if not os.path.isdir(downloadsPath) {
        os.makedirs(downloadsPath);
    }
    try {
        work: str = makeInstallDir(downloadsDir(home));
    } except OSError as e {
        raise JacupError(f"cannot create a temporary download directory in {downloadsDir(home)}: {str(e)}");
    }
    staging: str = os.path.join(work, version);
    os.makedirs(staging);
    try {
        stagedBin: str = os.path.join(staging, binaryName());
        print(f"jacup: downloading {artifact.url}");
        downloadTo(artifact.url, stagedBin);
        if not os.path.isfile(stagedBin) {
            raise JacupError(f"downloaded artifact is not a regular file: {artifact.url}");
        }
        if os.path.getsize(stagedBin) == 0 {
            raise JacupError(f"downloaded artifact is empty: {artifact.url}");
        }
        actual: str = sha256File(stagedBin);
        if actual != artifact.sha256 {
            raise JacupError(
                f"checksum mismatch for {artifact.url}: expected {artifact.sha256}, got {actual}; "
                "the download was discarded and nothing was installed"
            );
        }
        if not isWindows() and os.system("chmod 755 " + installShellQuote(stagedBin)) != 0 {
            raise JacupError(f"cannot make downloaded artifact executable: {stagedBin}");
        }
        meta: list[str] = [
            version,
            target.name(),
            artifact.url,
            artifact.sha256,
            nowIso(),
        ];
        writeInstallText(os.path.join(staging, "metadata.json"), serializeMetadata(meta));
        if os.system("mv " + installShellQuote(staging) + " " + installShellQuote(vdir)) != 0 {
            raise JacupError(
                f"could not finalize installation of {version} into {vdir}; if a version "
                f"directory already exists, run 'jacup uninstall {version}' first"
            );
        }
        print(f"jacup: installed Jac {version} at {vdir}");
        return vdir;
    } finally {
        if os.path.isdir(work) {
            removeTree(work);
        }
    }
}

def serializeMetadata(meta: list[str]) -> str {
    return (
        "{\"version\":" + json.dumps(meta[0])
        + ",\"target\":" + json.dumps(meta[1])
        + ",\"url\":" + json.dumps(meta[2])
        + ",\"sha256\":" + json.dumps(meta[3])
        + ",\"installed_at\":" + json.dumps(meta[4])
        + "}\n"
    );
}

def uninstallVersion(home: dict[str, str], version: str) -> None {
    parseVersion(version);
    vdir: str = versionDir(home, version);
    installed = installedVersions(home);
    if version not in installed {
        listing = ", ".join(sorted(installed)) or "(none)";
        raise JacupError(f"version {version} is not installed (installed versions: {listing})");
    }
    cfg = loadConfig(home);
    if cfg.default_version == version {
        raise JacupError(
            f"refusing to uninstall {version}: it is the global default version; select another "
            "installed version first with 'jacup use <version>'"
        );
    }
    try {
        removeTree(vdir);
    } except OSError as e {
        raise JacupError(f"failed to remove {vdir}: {str(e)}");
    }
    pointer: str = currentFile(home);
    if os.path.isfile(pointer) {
        try {
            rf = open(pointer, "r");
            try {
                content: str = rf.read().strip();
            } finally {
                rf.close();
            }
            if content == version {
                if os.path.exists(pointer) {
                    os.unlink(pointer);
                }
            }
        } except OSError {
            return;
        }
    }
    print(f"jacup: uninstalled Jac {version}");
}
