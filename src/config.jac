"""Global manager state: config.json with default_version, release_index_url, and aliases."""

import json;
import os;
import from src.errors { JacupError }
import from src.path_core { configFile }
def configShellQuote(value: str) -> str {
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
 
def writeConfigText(path: str, content: str) -> None {
    tmp: str = path + ".tmp-native";
    fh = open(tmp, "w");
    try {
        fh.write(content);
    } finally {
        fh.close();
    }
    if os.system("mv " + configShellQuote(tmp) + " " + configShellQuote(path)) != 0 {
        raise JacupError(f"failed to replace {path}");
    }
}
import from src.semver { parseVersion }

glob RESERVED_ALIASES: list[str] = ["latest"];

obj JacupConfig {
    has default_version: str | None = None;
    has release_index_url: str | None = None;
    has aliases: dict[str, str] = {};
}

def isLetter(ch: str) -> bool {
    return (ch >= "A" and ch <= "Z") or (ch >= "a" and ch <= "z");
}

def isAliasChar(ch: str) -> bool {
    return isLetter(ch) or (ch >= "0" and ch <= "9") or ch == "." or ch == "_" or ch == "-";
}

def validateAlias(name: str) -> None {
    valid: bool = len(name) >= 1 and len(name) <= 64;
    if valid {
        valid = isLetter(name[0]);
    }
    if valid {
        for ch in name[1:] {
            if not isAliasChar(ch) {
                valid = False;
                break;
            }
        }
    }
    if not valid {
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
    } except JacupError {
        versionLike = False;
    }
    if versionLike {
        raise JacupError(
            f"invalid alias '{name}': aliases must not look like exact versions so "
            "'jacup switch <version|alias>' stays unambiguous"
        );
    }
}

def configString(raw: str, path: str, field: str) -> str | None {
    marker: str = "\"" + field + "\":";
    at: int = raw.find(marker);
    if at < 0 {
        # Absent optional keys keep their defaults; only a present-but-invalid
        # value is malformed. Written by 'jacup use' before aliases existed.
        return None;
    }
    valueStart: int = at + len(marker);
    while valueStart < len(raw) {
        ch: str = raw[valueStart];
        if ch != " " and ch != "\n" and ch != "\r" and ch != "\t" {
            break;
        }
        valueStart = valueStart + 1;
    }
    if raw.startswith("null", valueStart) {
        return None;
    }
    if valueStart >= len(raw) or raw[valueStart] != "\"" {
        raise JacupError(f"malformed config file {path}: '{field}' must be a string or null");
    }
    valueStart = valueStart + 1;
    valueEnd: int = raw.find("\"", valueStart);
    if valueEnd < 0 {
        raise JacupError(f"malformed config file {path}: unterminated '{field}'");
    }
    value: str = raw[valueStart:valueEnd];
    if value == "" {
        raise JacupError(f"malformed config file {path}: '{field}' must be a non-empty string or null");
    }
    return value;
}

def configAliases(raw: str, path: str) -> dict[str, str] {
    marker: str = "\"aliases\":";
    at: int = raw.find(marker);
    if at < 0 {
        # Absent 'aliases' means no aliases; required since configs written
        # before aliases shipped must keep loading.
        return {};
    }
    start: int = at + len(marker);
    while start < len(raw) and (raw[start] == " " or raw[start] == "\n" or raw[start] == "\r" or raw[start] == "\t") {
        start = start + 1;
    }
    if start >= len(raw) or raw[start] != "{" {
        raise JacupError(f"malformed config file {path}: 'aliases' must be an object");
    }
    end: int = raw.find("}", start + 1);
    if end < 0 {
        raise JacupError(f"malformed config file {path}: unterminated 'aliases'");
    }
    aliases: dict[str, str] = {};
    body: str = raw[start + 1:end].strip();
    if body == "" {
        return aliases;
    }
    for item in body.split(",") {
        colon: int = item.find(":");
        if colon < 0 {
            raise JacupError(f"malformed config file {path}: invalid alias entry");
        }
        name: str = item[:colon].strip();
        value: str = item[colon + 1:].strip();
        if len(name) < 2 or name[0] != "\"" or name[-1] != "\"" or len(value) < 2 or value[0] != "\"" or value[-1] != "\"" {
            raise JacupError(f"malformed config file {path}: alias entries must map strings to strings");
        }
        aliasName: str = name[1:len(name) - 1];
        aliasVersion: str = value[1:len(value) - 1];
        aliases[aliasName] = aliasVersion;
    }
    return aliases;
}

def validConfigJson(raw: str, path: str) -> None {
    try {
        json.loads(raw);
    } except Exception as e {
        raise JacupError(
            f"malformed config file {path}: {e}; fix the JSON or remove the file and run "
            "'jacup use <version>' to recreate it"
        );
    }
}

def loadConfig(home: dict[str, str]) -> JacupConfig {
    path: str = configFile(home);
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
    } except Exception as e {
        raise JacupError(
            f"malformed config file {path}: {e}; fix the JSON or remove the file and run "
            "'jacup use <version>' to recreate it"
        );
    }
    validConfigJson(raw, path);
    cfg = JacupConfig();
    dv: str | None = configString(raw, path, "default_version");
    if dv is not None {
        cfg.default_version = dv;
    }
    riu: str | None = configString(raw, path, "release_index_url");
    if riu is not None {
        cfg.release_index_url = riu;
    }
    aliases = configAliases(raw, path);
    for key in aliases {
        valueText: str = aliases[key];
        try {
            parseVersion(valueText);
        } except JacupError {
            raise JacupError(
                f"malformed config file {path}: alias '{key}' maps to '{valueText}', "
                "which is not an exact version"
            );
        }
        validateAlias(key);
    }
    cfg.aliases = aliases;
    return cfg;
}

def configJsonValue(value: str | None) -> str {
    return "null" if value is None else json.dumps(value);
}

def saveConfig(home: dict[str, str], cfg: JacupConfig) -> None {
    configDir: str = home["config_dir"];
    if not os.path.isdir(configDir) {
        os.makedirs(configDir);
    }
    parts: list[str] = [];
    for name in sorted(cfg.aliases) {
        parts.append(json.dumps(name) + ":" + json.dumps(cfg.aliases[name]));
    }
    payload: str = (
        "{\"default_version\":" + configJsonValue(cfg.default_version)
        + ",\"release_index_url\":" + configJsonValue(cfg.release_index_url)
        + ",\"aliases\":{" + ",".join(parts) + "}}\n"
    );
    writeConfigText(configFile(home), payload);
}

def resolveIndexUrl(flagUrl: str | None, home: dict[str, str]) -> str {
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
        f"variable, or set 'release_index_url' in {configFile(home)}"
    );
}
