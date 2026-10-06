"""Global manager state: config.json with default_version, release_index_url, and aliases."""

import json;
import os;
import re;
import from src.errors { JacupError }
import from src.paths { JacupHome, writeTextAtomic }
import from src.semver { parseVersion }

glob ALIAS_PATTERN: str = r"^[A-Za-z][A-Za-z0-9._-]{0,63}$";
glob RESERVED_ALIASES: list[str] = ["latest"];

obj JacupConfig {
    has default_version: str | None = None;
    has release_index_url: str | None = None;
    has aliases: dict[str, str] = {};
}

def validateAlias(name: str) -> None {
    if not re.fullmatch(ALIAS_PATTERN, name) {
        raise JacupError(
            f"invalid alias '{name}': use 1-64 characters (letters, digits, '.', '_', '-') "
            "starting with a letter"
        );
    }
    if name in RESERVED_ALIASES {
        raise JacupError(f"'{name}' is reserved and cannot be used as an alias");
    }
    versionLike: bool = False;
    try {
        parseVersion(name);
        versionLike = True;
    } except JacupError as e {
        versionLike = False;
    }
    if versionLike {
        raise JacupError(
            f"invalid alias '{name}': aliases must not look like exact versions so "
            "'jacup switch <version|alias>' stays unambiguous"
        );
    }
}

def loadConfig(home: JacupHome) -> JacupConfig {
    path: str = home.configFile();
    if not os.path.exists(path) {
        return JacupConfig();
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
            f"malformed config file {path}: {str(e)}; fix the JSON or remove the file and run "
            "'jacup use <version>' to recreate it"
        );
    }
    if not isinstance(data, dict) {
        raise JacupError(f"malformed config file {path}: expected a JSON object");
    }
    cfg = JacupConfig();
    dv = data.get("default_version");
    if dv is not None {
        if not isinstance(dv, str) or dv == "" {
            raise JacupError(f"malformed config file {path}: 'default_version' must be a non-empty string or null");
        }
        cfg.default_version = dv;
    }
    riu = data.get("release_index_url");
    if riu is not None {
        if not isinstance(riu, str) or riu == "" {
            raise JacupError(f"malformed config file {path}: 'release_index_url' must be a non-empty string or null");
        }
        cfg.release_index_url = riu;
    }
    aliasMap = data.get("aliases");
    if aliasMap is not None {
        if not isinstance(aliasMap, dict) {
            raise JacupError(f"malformed config file {path}: 'aliases' must be a JSON object");
        }
        for key in aliasMap {
            value = aliasMap[key];
            if not isinstance(value, str) or value == "" {
                raise JacupError(
                    f"malformed config file {path}: alias '{key}' must map to a non-empty string"
                );
            }
            try {
                parseVersion(value);
            } except JacupError as e {
                raise JacupError(
                    f"malformed config file {path}: alias '{key}' maps to '{value}', "
                    "which is not an exact version"
                );
            }
            validateAlias(key);
        }
        cfg.aliases = aliasMap;
    }
    return cfg;
}

def saveConfig(home: JacupHome, cfg: JacupConfig) -> None {
    home.ensureConfigDir();
    payload = json.dumps(
        {
            "default_version": cfg.default_version,
            "release_index_url": cfg.release_index_url,
            "aliases": cfg.aliases,
        },
        indent=2,
        sort_keys=True,
    ) + "\n";
    writeTextAtomic(home.configFile(), payload);
}

def resolveIndexUrl(flagUrl: str | None, home: JacupHome) -> str {
    if flagUrl {
        return flagUrl;
    }
    fromEnv = os.environ.get("JACUP_INDEX_URL");
    if fromEnv {
        return fromEnv;
    }
    cfg = loadConfig(home);
    if cfg.release_index_url {
        return cfg.release_index_url;
    }
    raise JacupError(
        "no release index configured; pass --index-url <url>, set the JACUP_INDEX_URL environment "
        f"variable, or set 'release_index_url' in {home.configFile()}"
    );
}
