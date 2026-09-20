"""Global manager state: config.json with default_version and release_index_url."""

import json;
import os;
import from src.errors { JacupError }
import from src.paths { JacupHome, writeTextAtomic }

obj JacupConfig {
    has default_version: str | None = None;
    has release_index_url: str | None = None;
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
    return cfg;
}

def saveConfig(home: JacupHome, cfg: JacupConfig) -> None {
    home.ensureConfigDir();
    payload = json.dumps(
        {
            "default_version": cfg.default_version,
            "release_index_url": cfg.release_index_url,
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
