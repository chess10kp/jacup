"""Manager-owned directories and layout.

`JACUP_HOME` overrides both roots. Otherwise Unix uses XDG data/config dirs
and Windows uses the native per-user application-data/config locations.
Directories are created only when a command needs them.
"""

import os;
import platform;
import tempfile;
import from src.errors { JacupError }

obj JacupHome {
    has data_dir: str, config_dir: str;

    def versionsDir() -> str {
        return os.path.join(self.data_dir, "versions");
    }

    def downloadsDir() -> str {
        return os.path.join(self.data_dir, "downloads");
    }

    def versionDir(version: str) -> str {
        return os.path.join(self.versionsDir(), version);
    }

    def binaryPath(version: str) -> str {
        return os.path.join(self.versionDir(version), binaryName());
    }

    def metadataPath(version: str) -> str {
        return os.path.join(self.versionDir(version), "metadata.json");
    }

    def configFile() -> str {
        return os.path.join(self.config_dir, "config.json");
    }

    def currentFile() -> str {
        return os.path.join(self.data_dir, "current");
    }

    def ensureDataDirs() -> None {
        try {
            os.makedirs(self.versionsDir(), exist_ok=True);
            os.makedirs(self.downloadsDir(), exist_ok=True);
        } except OSError as e {
            raise JacupError(f"cannot create jacup data directories under {self.data_dir}: {str(e)}");
        }
    }

    def ensureConfigDir() -> None {
        try {
            os.makedirs(self.config_dir, exist_ok=True);
        } except OSError as e {
            raise JacupError(f"cannot create jacup config directory {self.config_dir}: {str(e)}");
        }
    }
}

def isWindows() -> bool {
    return platform.system() == "Windows";
}

def binaryName() -> str {
    return "jac.exe" if isWindows() else "jac";
}

def resolveHome() -> JacupHome {
    homeOverride = os.environ.get("JACUP_HOME");
    if homeOverride {
        rootDir: str = os.path.abspath(homeOverride);
        return JacupHome(data_dir=rootDir, config_dir=rootDir);
    }
    if isWindows() {
        return JacupHome(data_dir=windowsDataDir(), config_dir=windowsConfigDir());
    }
    dataBase = os.environ.get("XDG_DATA_HOME");
    if not dataBase {
        dataBase = os.path.join(os.path.expanduser("~"), ".local", "share");
    }
    configBase = os.environ.get("XDG_CONFIG_HOME");
    if not configBase {
        configBase = os.path.join(os.path.expanduser("~"), ".config");
    }
    return JacupHome(
        data_dir=os.path.join(dataBase, "jacup"),
        config_dir=os.path.join(configBase, "jacup"),
    );
}

def windowsDataDir() -> str {
    localAppData = os.environ.get("LOCALAPPDATA");
    if not localAppData {
        profile = os.environ.get("USERPROFILE");
        if not profile {
            raise JacupError("cannot locate the Windows application-data directory; set JACUP_HOME explicitly");
        }
        localAppData = os.path.join(profile, "AppData", "Local");
    }
    return os.path.join(localAppData, "jacup");
}

def windowsConfigDir() -> str {
    appData = os.environ.get("APPDATA");
    if not appData {
        profile = os.environ.get("USERPROFILE");
        if not profile {
            raise JacupError("cannot locate the Windows config directory; set JACUP_HOME explicitly");
        }
        appData = os.path.join(profile, "AppData", "Roaming");
    }
    return os.path.join(appData, "jacup");
}

def removeQuiet(path: str) -> None {
    try {
        os.unlink(path);
    } except OSError {
        return;
    }
}

def writeTextAtomic(path: str, content: str) -> None {
    parent: str = os.path.dirname(path);
    try {
        os.makedirs(parent, exist_ok=True);
        res = tempfile.mkstemp(prefix=".jacup-tmp-", dir=parent);
    } except OSError as e {
        raise JacupError(f"cannot prepare temporary file for {path}: {str(e)}");
    }
    fd: int = res[0];
    tmp: str = res[1];
    try {
        fh = os.fdopen(fd, "w");
        try {
            fh.write(content);
        } finally {
            fh.close();
        }
        os.replace(tmp, path);
    } except Exception as e {
        removeQuiet(tmp);
        raise JacupError(f"failed to write {path}: {str(e)}");
    }
}
