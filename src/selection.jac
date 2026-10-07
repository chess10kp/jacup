"""Global and project-local version selection.

Resolution order: the nearest `.jac-version` walking up from the current
directory, then the global `default_version` from config.json. The `current`
pointer under the data root is informational only; resolution always uses the
config value so a stale pointer can never select a different version.
"""

import os;
import from os.path { abspath }
import from src.config { loadConfig, saveConfig, JacupConfig, validateAlias }
import from src.errors { JacupError }
import from src.install { metadataVersion }
import from src.path_core {
    binaryName,
    currentFile,
    isWindows,
    metadataPath,
    versionDir,
    versionsDir,
}
import from src.link { linkActiveJac }
import from src.semver { parseVersion }

glob PIN_FILE: str = ".jac-version";
def selectionShellQuote(value: str) -> str {
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
def writeSelectionText(path: str, content: str) -> None {
    tmp: str = path + ".tmp-native";
    fh = open(tmp, "w");
    try {
        fh.write(content);
    } finally {
        fh.close();
    }
    if os.system("mv " + selectionShellQuote(tmp) + " " + selectionShellQuote(path)) != 0 {
        raise JacupError(f"failed to replace {path}");
    }
}

obj Selection {
    has version: str, source: str;
}

def pinFilePath(directory: str) -> str {
    return os.path.join(directory, PIN_FILE);
}

def findPinFile(startDir: str) -> str | None {
    current: str = abspath(startDir);
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

def resolveVersion(home: dict[str, str], startDir: str) -> Selection {
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

def installedPath(home: dict[str, str], version: str) -> str {
    parseVersion(version);
    vdir: str = versionDir(home, version);
    if not os.path.isdir(vdir) {
        raise JacupError(
            f"Jac {version} is not installed (expected {vdir}). "
            f"Install it with 'jacup install {version}' or select another version"
        );
    }
    metaVersion: str = metadataVersion(home, version);
    if metaVersion != version {
        raise JacupError(
            f"incompatible metadata for {version}: {metadataPath(home, version)} declares version "
            f"{metaVersion}; repair by running 'jacup uninstall {version}' then "
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
    if not isWindows() and os.system("test -x " + selectionShellQuote(binPath)) != 0 {
        raise JacupError(f"Jac executable for {version} is not executable: {binPath}; fix with 'chmod +x {binPath}'");
    }
    return binPath;
}

def setDefaultVersion(home: dict[str, str], version: str) -> str | None {
    parseVersion(version);
    _ = installedPath(home, version);
    cfg = loadConfig(home);
    cfg.default_version = version;
    saveConfig(home, cfg);
    writeSelectionText(currentFile(home), version + "\n");
    return linkActiveJac(home, version);
}

def setAlias(home: dict[str, str], name: str, version: str) -> None {
    validateAlias(name);
    parseVersion(version);
    _ = installedPath(home, version);
    cfg = loadConfig(home);
    cfg.aliases[name] = version;
    saveConfig(home, cfg);
}

def removeAlias(home: dict[str, str], name: str) -> str {
    cfg = loadConfig(home);
    if name not in cfg.aliases {
        listing = ", ".join(sorted(cfg.aliases)) or "(none)";
        raise JacupError(f"no alias '{name}' is defined (defined aliases: {listing})");
    }
    version: str = cfg.aliases[name];
    cfg.aliases.pop(name);
    saveConfig(home, cfg);
    return version;
}

def resolveAliasOrVersion(home: dict[str, str], token: str) -> str {
    exact: str | None = None;
    try {
        parseVersion(token);
        exact = token;
    } except JacupError as e {
        exact = None;
    }
    if exact is not None {
        return exact;
    }
    cfg = loadConfig(home);
    if token in cfg.aliases {
        return cfg.aliases[token];
    }
    listing = ", ".join(sorted(cfg.aliases)) or "(none)";
    raise JacupError(
        f"'{token}' is neither an exact version nor a defined alias (aliases: {listing}); "
        "define one with 'jacup alias <name> <version>'"
    );
}

def pinProjectVersion(home: dict[str, str], version: str, directory: str) -> str {
    parseVersion(version);
    _ = installedPath(home, version);
    path: str = pinFilePath(abspath(directory));
    writeSelectionText(path, version + "\n");
    return path;
}

def unpinProjectVersion(directory: str) -> None {
    path: str = pinFilePath(abspath(directory));
    if not os.path.isfile(path) {
        raise JacupError(f"no {PIN_FILE} in {abspath(directory)}; nothing to unpin");
    }
    try {
        os.unlink(path);
    } except OSError as e {
        raise JacupError(f"failed to remove {path}: {str(e)}");
    }
}
