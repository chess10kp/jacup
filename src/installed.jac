"""Native installed-version directory listing."""

import os;
import from src.path_core { versionsDir }

def installedVersions(home: dict[str, str]) -> list[str] {
    versionsRoot: str = versionsDir(home);
    if not os.path.isdir(versionsRoot) {
        return [];
    }
    names: list[str] = os.listdir(versionsRoot);
    names.sort();
    return names;
}
