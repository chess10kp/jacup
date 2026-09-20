"""Global and project-local version selection.

Resolution order: the nearest `.jac-version` walking up from the current
directory, then the global `default_version` from config.json. The `current`
pointer under the data root is informational only; resolution always uses the
config value so a stale pointer can never select a different version.
"""

import os;
import from src.config { loadConfig, saveConfig, JacupConfig }
import from src.errors { JacupError }
import from src.install { loadMetadata }
import from src.paths { JacupHome, binaryName, isWindows, writeTextAtomic }
import from src.semver { parseVersion }

glob PIN_FILE: str = ".jac-version";

obj Selection {
    has version: str, source: str;
}

def pinFilePath(directory: str) -> str {
    return os.path.join(directory, PIN_FILE);
}

def findPinFile(startDir: str) -> str | None {
    current: str = os.path.abspath(startDir);
    while True {
        candidate: str = os.path.join(current, PIN_FILE);
        if os.path.isfile(candidate) {
            return candidate;
        }
        parent: str = os.path.dirname(current);
        if parent == current {
            return None;
        }
        current = parent;
    }
}

def readPinFile(path: str) -> str {
    try {
        rf = open(path, "r");
        try {
            raw: str = rf.read();
        } finally {
            rf.close();
        }
    } except Exception as e {
        raise JacupError(f"cannot read pin file {path}: {str(e)}; fix or remove the file ('jacup unpin' removes it from its directory)");
    }
    content: str = raw;
    if content.endswith("\n") {
        content = content[:-1];
    }
    shown: str = content.replace("\n", "\\n");
    try {
        parseVersion(content);
    } except JacupError {
        raise JacupError(
            f"malformed pin file {path}: '{shown}' is not an exact version; the file must contain "
            "exactly one MAJOR.MINOR.PATCH[-PRERELEASE] string"
        );
    }
    return content;
}

def resolveVersion(home: JacupHome, startDir: str) -> Selection {
    pin = findPinFile(startDir);
    if pin is not None {
        version: str = readPinFile(pin);
        return Selection(version=version, source=f"project pin {pin}");
    }
    cfg: JacupConfig = loadConfig(home);
    dv = cfg.default_version;
    if dv is not None {
        return Selection(version=dv, source="global default");
    }
    raise JacupError(
        "no Jac version selected; run 'jacup use <version>' to set a global default or "
        "'jacup pin <version>' inside your project"
    );
}

def installedPath(home: JacupHome, version: str) -> str {
    parseVersion(version);
    vdir: str = home.versionDir(version);
    if not os.path.isdir(vdir) {
        installed: list[str] = [];
        versionsRoot: str = home.versionsDir();
        if os.path.isdir(versionsRoot) {
            try {
                installed = sorted(os.listdir(versionsRoot));
            } except OSError {
                installed = [];
            }
        }
        listing = ", ".join(installed) or "(none)";
        raise JacupError(
            f"Jac {version} is not installed (expected {vdir}); installed versions: {listing}. "
            f"Install it with 'jacup install {version}' or select another version"
        );
    }
    meta = loadMetadata(home, version);
    if meta.version != version {
        raise JacupError(
            f"incompatible metadata for {version}: {home.metadataPath(version)} declares version "
            f"{meta.version}; repair by running 'jacup uninstall {version}' then "
            f"'jacup install {version}'"
        );
    }
    binPath: str = os.path.join(vdir, binaryName());
    if not os.path.isfile(binPath) {
        raise JacupError(
            f"Jac executable missing for {version}: {binPath}; repair by running "
            f"'jacup uninstall {version}' then 'jacup install {version}'"
        );
    }
    if not isWindows() and not os.access(binPath, os.X_OK) {
        raise JacupError(f"Jac executable for {version} is not executable: {binPath}; fix with 'chmod +x {binPath}'");
    }
    return binPath;
}

def setDefaultVersion(home: JacupHome, version: str) -> None {
    parseVersion(version);
    _ = installedPath(home, version);
    cfg = loadConfig(home);
    cfg.default_version = version;
    saveConfig(home, cfg);
    writeTextAtomic(home.currentFile(), version + "\n");
}

def pinProjectVersion(home: JacupHome, version: str, directory: str) -> str {
    parseVersion(version);
    _ = installedPath(home, version);
    path: str = pinFilePath(os.path.abspath(directory));
    writeTextAtomic(path, version + "\n");
    return path;
}

def unpinProjectVersion(directory: str) -> None {
    path: str = pinFilePath(os.path.abspath(directory));
    if not os.path.isfile(path) {
        raise JacupError(f"no {PIN_FILE} in {os.path.abspath(directory)}; nothing to unpin");
    }
    try {
        os.unlink(path);
    } except OSError as e {
        raise JacupError(f"failed to remove {path}: {str(e)}");
    }
}
