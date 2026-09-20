"""Atomic installation and removal of released Jac versions.

Install pipeline: download to a unique temporary directory, verify SHA-256,
set the executable bit on Unix, write metadata.json, then rename the finished
directory into versions/<version>. An existing version is never replaced in
place: it is accepted only when its metadata and checksum match.
"""

import json;
import os;
import shutil;
import tempfile;
import from datetime { datetime }
import from src.config { loadConfig }
import from src.errors { JacupError }
import from src.paths { JacupHome, binaryName, isWindows, removeQuiet, writeTextAtomic }
import from src.releases {
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

obj InstallMetadata {
    has version: str, target: str, url: str, sha256: str, installed_at: str;
}

def nowIso() -> str {
    return datetime.now().astimezone().isoformat();
}

def loadMetadata(home: JacupHome, version: str) -> InstallMetadata {
    path: str = home.metadataPath(version);
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
        data = json.loads(raw);
    } except Exception as e {
        raise JacupError(
            f"malformed metadata file {path}: {str(e)}; repair by running "
            f"'jacup uninstall {version}' then 'jacup install {version}'"
        );
    }
    if not isinstance(data, dict) {
        raise JacupError(
            f"malformed metadata file {path}: expected a JSON object; repair by running "
            f"'jacup uninstall {version}' then 'jacup install {version}'"
        );
    }
    fields: list[str] = ["version", "target", "url", "sha256", "installed_at"];
    values: dict[str, any] = {};
    for field in fields {
        v = data.get(field);
        if not isinstance(v, str) or v == "" {
            raise JacupError(
                f"malformed metadata file {path}: '{field}' must be a non-empty string; repair "
                f"by running 'jacup uninstall {version}' then 'jacup install {version}'"
            );
        }
        values[field] = v;
    }
    try {
        parseVersion(values["version"]);
    } except JacupError {
        raise JacupError(f"malformed metadata file {path}: version '{values['version']}' is not an exact version");
    }
    if not isValidChecksum(values["sha256"]) {
        raise JacupError(f"malformed metadata file {path}: 'sha256' must be 64 lowercase hex characters");
    }
    return InstallMetadata(
        version=values["version"],
        target=values["target"],
        url=values["url"],
        sha256=values["sha256"],
        installed_at=values["installed_at"],
    );
}

def installedVersions(home: JacupHome) -> list[str] {
    versionsRoot: str = home.versionsDir();
    if not os.path.isdir(versionsRoot) {
        return [];
    }
    try {
        names: list[str] = sorted(os.listdir(versionsRoot));
    } except OSError as e {
        raise JacupError(f"cannot list installed versions in {versionsRoot}: {str(e)}");
    }
    out: list[str] = [];
    for name in names {
        if os.path.isdir(os.path.join(versionsRoot, name)) {
            out.append(name);
        }
    }
    return out;
}

def installVersion(home: JacupHome, version: str, indexUrl: str) -> str {
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
    vdir: str = home.versionDir(version);
    if os.path.exists(vdir) {
        return confirmExisting(home, version, vdir, artifact, target);
    }
    return downloadAndStage(home, version, vdir, artifact, target);
}

def confirmExisting(home: JacupHome, version: str, vdir: str, artifact: any, target: Target) -> str {
    meta = loadMetadata(home, version);
    binPath: str = home.binaryPath(version);
    matches: bool = (
        meta.version == version
        and meta.target == target.name()
        and meta.url == artifact.url
        and meta.sha256 == artifact.sha256
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

def downloadAndStage(home: JacupHome, version: str, vdir: str, artifact: any, target: Target) -> str {
    home.ensureDataDirs();
    try {
        work: str = tempfile.mkdtemp(prefix="install-", dir=home.downloadsDir());
    } except OSError as e {
        raise JacupError(f"cannot create a temporary download directory in {home.downloadsDir()}: {str(e)}");
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
        if not isWindows() {
            os.chmod(stagedBin, 0o755);
        }
        meta = InstallMetadata(
            version=version,
            target=target.name(),
            url=artifact.url,
            sha256=artifact.sha256,
            installed_at=nowIso(),
        );
        writeTextAtomic(os.path.join(staging, "metadata.json"), serializeMetadata(meta));
        try {
            os.replace(staging, vdir);
        } except OSError as e {
            raise JacupError(
                f"could not finalize installation of {version} into {vdir}: {str(e)}; if a version "
                f"directory already exists, run 'jacup uninstall {version}' first"
            );
        }
        print(f"jacup: installed Jac {version} at {vdir}");
        return vdir;
    } finally {
        if os.path.isdir(work) {
            shutil.rmtree(work, ignore_errors=True);
        }
    }
}

def serializeMetadata(meta: InstallMetadata) -> str {
    return json.dumps(
        {
            "version": meta.version,
            "target": meta.target,
            "url": meta.url,
            "sha256": meta.sha256,
            "installed_at": meta.installed_at,
        },
        indent=2,
        sort_keys=True,
    ) + "\n";
}

def uninstallVersion(home: JacupHome, version: str) -> None {
    parseVersion(version);
    vdir: str = home.versionDir(version);
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
        shutil.rmtree(vdir);
    } except OSError as e {
        raise JacupError(f"failed to remove {vdir}: {str(e)}");
    }
    pointer: str = home.currentFile();
    if os.path.isfile(pointer) {
        try {
            rf = open(pointer, "r");
            try {
                content: str = rf.read().strip();
            } finally {
                rf.close();
            }
            if content == version {
                removeQuiet(pointer);
            }
        } except OSError {
            return;
        }
    }
    print(f"jacup: uninstalled Jac {version}");
}
