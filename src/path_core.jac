"""Native path and build-target helpers."""

import os;
import from src.target { TARGET_OS }

def isWindows() -> bool {
    return TARGET_OS == "windows";
}

def binaryName() -> str {
    return "jac.exe" if isWindows() else "jac";
}

def versionsDir(home: dict[str, str]) -> str {
    return os.path.join(home["data_dir"], "versions");
}

def downloadsDir(home: dict[str, str]) -> str {
    return os.path.join(home["data_dir"], "downloads");
}

def versionDir(home: dict[str, str], version: str) -> str {
    return os.path.join(versionsDir(home), version);
}

def binaryPath(home: dict[str, str], version: str) -> str {
    return os.path.join(versionDir(home, version), binaryName());
}

def metadataPath(home: dict[str, str], version: str) -> str {
    return os.path.join(versionDir(home, version), "metadata.json");
}

def configFile(home: dict[str, str]) -> str {
    return os.path.join(home["config_dir"], "config.json");
}

def currentFile(home: dict[str, str]) -> str {
    return os.path.join(home["data_dir"], "current");
}

def binDir(home: dict[str, str]) -> str {
    return os.path.join(home["data_dir"], "bin");
}

def activeJacPath(home: dict[str, str]) -> str {
    return os.path.join(binDir(home), binaryName());
}
