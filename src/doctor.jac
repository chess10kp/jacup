"""Health checks over the manager home, config, installations, and index."""

import os;
import sys;
import from src.config { loadConfig, resolveIndexUrl }
import from src.errors { JacupError }
import from src.install { loadMetadata, installedVersions }
import from src.paths { JacupHome, binaryName, isWindows }
import from src.releases { fetchIndex, sha256File }
import from src.selection { installedPath, resolveVersion }
import from src.semver { parseVersion }

obj CheckResult {
    has name: str, ok: bool, detail: str;
}

obj DirCheck {
    has label: str, path: str;
}

def record(results: list[CheckResult], name: str, ok: bool, detail: str) -> None {
    results.append(CheckResult(name=name, ok=ok, detail=detail));
}

def runDoctor(home: JacupHome, indexFlag: str | None) -> int {
    results: list[CheckResult] = [];

    checkDirectories(home, results);
    checkConfig(home, results);
    checkSelection(home, results);
    checkInstalled(home, results);
    checkIndex(home, indexFlag, results);

    failed: int = 0;
    for r in results {
        status: str = "ok  " if r.ok else "FAIL";
        print(f"[{status}] {r.name}: {r.detail}");
        if not r.ok {
            failed = failed + 1;
        }
    }
    if failed {
        sys.stderr.write(f"jacup: {failed} check(s) failed\n");
        return 2;
    }
    print("jacup: all checks passed");
    return 0;
}

def checkDirectories(home: JacupHome, results: list[CheckResult]) -> None {
    targets: list[DirCheck] = [
        DirCheck(label="data home", path=home.data_dir),
        DirCheck(label="config home", path=home.config_dir),
    ];
    for t in targets {
        if os.path.isdir(t.path) and os.access(t.path, os.R_OK | os.W_OK | os.X_OK) {
            record(results, f"{t.label} directory", True, f"{t.path} is readable and writable");
        } elif os.path.isdir(t.path) {
            record(
                results,
                f"{t.label} directory",
                False,
                f"{t.path} exists but is not accessible; check its permissions",
            );
        } else {
            try {
                os.makedirs(t.path, exist_ok=True);
                record(results, f"{t.label} directory", True, f"{t.path} created");
            } except OSError as e {
                record(
                    results,
                    f"{t.label} directory",
                    False,
                    f"{t.path} does not exist and cannot be created ({str(e)}); check JACUP_HOME and permissions",
                );
            }
        }
    }
}

def checkConfig(home: JacupHome, results: list[CheckResult]) -> None {
    path: str = home.configFile();
    if not os.path.exists(path) {
        record(results, "config file", True, f"{path} not present; defaults in effect");
        return;
    }
    try {
        _ = loadConfig(home);
        record(results, "config file", True, f"{path} parsed");
    } except JacupError as e {
        record(results, "config file", False, str(e));
    }
}

def checkSelection(home: JacupHome, results: list[CheckResult]) -> None {
    try {
        sel = resolveVersion(home, os.getcwd());
    } except JacupError as e {
        record(results, "version selection", True, str(e));
        return;
    }
    try {
        binPath: str = installedPath(home, sel.version);
        record(results, "version selection", True, f"{sel.version} ({sel.source}) -> {binPath}");
    } except JacupError as e {
        record(results, "version selection", False, str(e));
    }
    pointer: str = home.currentFile();
    if not os.path.isfile(pointer) {
        return;
    }
    try {
        rf = open(pointer, "r");
        try {
            content: str = rf.read().strip();
        } finally {
            rf.close();
        }
        cfg = loadConfig(home);
        dv = cfg.default_version;
        if dv is not None and content != dv {
            record(
                results,
                "current pointer",
                True,
                f"{pointer} names '{content}' but the default is '{dv}'; the pointer is informational "
                f"only, refresh it with 'jacup use {dv}'",
            );
        }
    } except OSError {
        return;
    }
}

def checkInstalled(home: JacupHome, results: list[CheckResult]) -> None {
    names = installedVersions(home);
    if not names {
        record(results, "installed versions", True, "no versions installed");
        return;
    }
    for name in names {
        vdir: str = home.versionDir(name);
        try {
            parseVersion(name);
        } except JacupError {
            record(
                results,
                f"installed version {name}",
                False,
                f"{vdir} is not a valid version directory; remove it manually or reinstall",
            );
            continue;
        }
        try {
            meta = loadMetadata(home, name);
        } except JacupError as e {
            record(results, f"installed version {name}", False, str(e));
            continue;
        }
        binPath: str = os.path.join(vdir, binaryName());
        if not os.path.isfile(binPath) {
            record(
                results,
                f"installed version {name}",
                False,
                f"missing executable {binPath}; repair with 'jacup uninstall {name}' and 'jacup install {name}'",
            );
            continue;
        }
        actual = sha256File(binPath);
        if actual != meta.sha256 {
            record(
                results,
                f"installed version {name}",
                False,
                f"checksum mismatch for {binPath}: metadata records {meta.sha256}, file hashes to {actual}; "
                f"repair with 'jacup uninstall {name}' and 'jacup install {name}'",
            );
            continue;
        }
        if not isWindows() and not os.access(binPath, os.X_OK) {
            record(
                results,
                f"installed version {name}",
                False,
                f"{binPath} is not executable; fix with 'chmod +x {binPath}'",
            );
            continue;
        }
        record(results, f"installed version {name}", True, f"{binPath} verified against metadata");
    }
}

def checkIndex(home: JacupHome, indexFlag: str | None, results: list[CheckResult]) -> None {
    url = indexFlag;
    note: str = "configured via --index-url";
    if url is None {
        try {
            url = resolveIndexUrl(None, home);
            note = "resolved from environment or config";
        } except JacupError {
            record(
                results,
                "release index",
                True,
                "no release index configured; 'install' and 'available' need --index-url, "
                "JACUP_INDEX_URL, or release_index_url in config.json",
            );
            return;
        }
    }
    try {
        index = fetchIndex(url);
        record(
            results,
            "release index",
            True,
            f"{url} ({note}) reachable with {len(index.releases)} version(s)",
        );
    } except JacupError as e {
        record(results, "release index", False, f"{str(e)}; verify the URL or pass a different --index-url");
    }
}
