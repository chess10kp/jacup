"""Module tests for jacup: versions, index decoding, config, selection, install."""

import hashlib;
import json;
import os;
import platform;
import shutil;
import tempfile;
import from src.config { JacupConfig, loadConfig, resolveIndexUrl, saveConfig }
import from src.errors { JacupError }
import from src.install { installVersion, installedVersions, loadMetadata, uninstallVersion }
import from src.paths { JacupHome, binaryName, writeTextAtomic }
import from src.releases {
    decodeIndex,
    fetchIndex,
    isValidChecksum,
    currentTarget,
    sha256File,
}
import from src.selection { installedPath, pinFilePath, resolveVersion, unpinProjectVersion }
import from src.semver { parseVersion, sortVersionStrings }

def findRepoRoot() -> str {
    current: str = os.getcwd();
    while True {
        if os.path.isfile(os.path.join(current, "jac.toml")) {
            return current;
        }
        parent: str = os.path.dirname(current);
        if parent == current {
            raise JacupError(f"no jac.toml found walking up from {os.getcwd()}");
        }
        current = parent;
    }
}

glob FIXTURE_DIR: str = os.path.join(findRepoRoot(), "tests", "fixtures");
glob BAD_VERSIONS: list[str] = [
    ">=1.0.0",
    "<2.0.0",
    "1.0.0 || 2.0.0",
    "1.x",
    "latest",
    "1.2",
    "1.2.3.4",
    "v1.2.3",
    "",
    "..",
    "../jac",
    "1.2.3/../../bin",
    "1.2.3 ",
    " 1.2.3",
    "1.2.3\n",
    "1.2.3-",
    "01.2.3",
];

def newTmpHome() -> tuple[JacupHome, str] {
    base: str = tempfile.mkdtemp(prefix="jacup-test-");
    home = JacupHome(data_dir=base, config_dir=base);
    return (home, base);
}

def cleanupTmp(base: str) -> None {
    shutil.rmtree(base, ignore_errors=True);
}

def fixturePath(name: str) -> str {
    return os.path.join(FIXTURE_DIR, name);
}

def sha256Text(text: str) -> str {
    digest = hashlib.sha256();
    digest.update(text.encode("utf-8"));
    return digest.hexdigest();
}

def buildIndex(tmp: str, entries: list[dict[str, any]]) -> str {
    path: str = os.path.join(tmp, "index.json");
    writeTextAtomic(path, json.dumps({"versions": entries}, indent=2) + "\n");
    return "file://" + path;
}

def fixtureEntry(version: str, fixture: str) -> dict[str, any] {
    artifactPath: str = fixturePath(fixture);
    return {
        "version": version,
        "artifacts": [
            {
                "os": "linux",
                "arch": "x86_64",
                "url": "file://" + artifactPath,
                "sha256": sha256File(artifactPath),
            }
        ],
    };
}

test "parse accepts exact versions" {
    v = parseVersion("0.9.2");
    assert v.major == 0 and v.minor == 9 and v.patch == 2 and v.isRelease(), "0.9.2 fields";
    assert v.format() == "0.9.2", "roundtrip release";
    pre = parseVersion("1.0.0-rc.1");
    assert pre.prerelease == "rc.1" and pre.format() == "1.0.0-rc.1", "prerelease roundtrip";
    assert parseVersion("10.20.30").major == 10, "multi-digit";
    assert parseVersion("1.0.0-0.3.7").prerelease == "0.3.7", "numeric prerelease ids";
}

test "parse rejects ranges, latest, and path-like values" {
    for bad in BAD_VERSIONS {
        raised: bool = False;
        try {
            _ = parseVersion(bad);
        } except JacupError as e {
            raised = True;
            assert "invalid version" in str(e), f"actionable message for '{bad}'";
        }
        assert raised, f"expected rejection of '{bad}'";
    }
}

test "version ordering follows semver" {
    got: list[str] = sortVersionStrings([
        "1.0.0",
        "1.0.0-rc.1",
        "0.9.9",
        "1.0.0-alpha",
        "1.0.0-alpha.1",
        "0.10.0",
        "1.0.0-beta",
    ]);
    want: list[str] = [
        "0.9.9",
        "0.10.0",
        "1.0.0-alpha",
        "1.0.0-alpha.1",
        "1.0.0-beta",
        "1.0.0-rc.1",
        "1.0.0",
    ];
    assert got == want, f"ordering: {got}";
}

test "current target is a supported combo" {
    t = currentTarget();
    combos: list[str] = [];
    for osName in ["linux", "macos", "windows"] {
        for arch in ["x86_64", "aarch64"] {
            combos.append(f"{osName}-{arch}");
        }
    }
    assert t.name() in combos, f"target {t.name()} must be a supported combo";
    system: str = platform.system();
    if system == "Linux" {
        assert t.name() == "linux-x86_64" or t.name() == "linux-aarch64", "linux host target";
    }
}

test "index decode accepts a valid index" {
    text: str = json.dumps({"versions": [fixtureEntry("0.9.2", "fakejac-0.9.0.sh")]});
    index = decodeIndex(text, "test://index");
    assert len(index.releases) == 1, "one release";
    assert index.releases[0].version == "0.9.2", "version decoded";
    artifact = index.releases[0].artifacts[0];
    assert artifact.target_os == "linux" and artifact.arch == "x86_64", "target decoded";
    assert artifact.sha256 == sha256File(fixturePath("fakejac-0.9.0.sh")), "checksum decoded";
}

test "index decode rejects malformed indexes" {
    fixtureSha: str = sha256File(fixturePath("fakejac-0.9.0.sh"));
    cases: list[tuple[str, str]] = [
        ("not json", "{nope"),
        ("root array", json.dumps([1])),
        ("missing versions", json.dumps({"releases": []})),
        ("versions not array", json.dumps({"versions": 5})),
        ("entry not object", json.dumps({"versions": [7]})),
        ("missing version", json.dumps({"versions": [{"artifacts": []}]})),
        ("bad version", json.dumps({"versions": [{"version": "1.2", "artifacts": []}]})),
        (
            "duplicate versions",
            json.dumps({
                "versions": [
                    {"version": "1.0.0", "artifacts": []},
                    {"version": "1.0.0", "artifacts": []},
                ]
            }),
        ),
        ("missing artifacts", json.dumps({"versions": [{"version": "1.0.0"}]})),
        ("artifacts not array", json.dumps({"versions": [{"version": "1.0.0", "artifacts": 3}]})),
        (
            "artifact not object",
            json.dumps({"versions": [{"version": "1.0.0", "artifacts": [9]}]}),
        ),
        (
            "missing os",
            json.dumps({"versions": [{"version": "1.0.0", "artifacts": [{"arch": "x86_64", "url": "https://h/j", "sha256": fixtureSha}]}]}),
        ),
        (
            "unsupported scheme",
            json.dumps({"versions": [{"version": "1.0.0", "artifacts": [{"os": "linux", "arch": "x86_64", "url": "http://host/jac", "sha256": fixtureSha}]}]}),
        ),
        (
            "uppercase checksum",
            json.dumps({"versions": [{"version": "1.0.0", "artifacts": [{"os": "linux", "arch": "x86_64", "url": "https://host/jac", "sha256": fixtureSha.upper()}]}]}),
        ),
        (
            "short checksum",
            json.dumps({"versions": [{"version": "1.0.0", "artifacts": [{"os": "linux", "arch": "x86_64", "url": "https://host/jac", "sha256": "abcd"}]}]}),
        ),
        (
            "duplicate target",
            json.dumps({
                "versions": [{
                    "version": "1.0.0",
                    "artifacts": [
                        {"os": "linux", "arch": "x86_64", "url": "https://host/a", "sha256": fixtureSha},
                        {"os": "linux", "arch": "x86_64", "url": "https://host/b", "sha256": fixtureSha},
                    ],
                }]
            }),
        ),
    ];
    ci: int = 0;
    while ci < len(cases) {
        label: str = cases[ci][0];
        text: str = cases[ci][1];
        raised: bool = False;
        message: str = "";
        try {
            _ = decodeIndex(text, "test://index");
        } except JacupError as e {
            raised = True;
            message = str(e);
        }
        assert raised, f"expected '{label}' to be rejected";
        assert "malformed release index" in message, f"'{label}' error must be actionable: {message}";
        ci = ci + 1;
    }
}

test "fetchIndex reads file urls and reports network failures" {
    pair = newTmpHome();
    home = pair[0];
    base = pair[1];
    try {
        url: str = buildIndex(base, [fixtureEntry("0.9.0", "fakejac-0.9.0.sh")]);
        index = fetchIndex(url);
        assert index.releases[0].version == "0.9.0", "file:// fetch decodes";
        raised: bool = False;
        try {
            _ = fetchIndex("file:///nonexistent/jacup-nope/index.json");
        } except JacupError as e {
            raised = True;
            assert "failed to fetch" in str(e), f"fetch error actionable: {str(e)}";
        }
        assert raised, "missing index must fail";
    } finally {
        cleanupTmp(base);
    }
}

test "sha256File matches hashlib" {
    pair = newTmpHome();
    home = pair[0];
    base = pair[1];
    try {
        payload: str = "jacup checksum test payload\n";
        path: str = os.path.join(base, "blob.bin");
        writeTextAtomic(path, payload);
        assert sha256File(path) == sha256Text(payload), "streamed digest equals hashlib digest";
        assert isValidChecksum(sha256File(path)), "digest is 64 lowercase hex";
        assert not isValidChecksum("AB" * 32), "uppercase rejected";
        assert not isValidChecksum("zz"), "garbage rejected";
    } finally {
        cleanupTmp(base);
    }
}

test "writeTextAtomic replaces content and cleans temp files" {
    pair = newTmpHome();
    home = pair[0];
    base = pair[1];
    try {
        path: str = os.path.join(base, "state.json");
        writeTextAtomic(path, "one\n");
        writeTextAtomic(path, "two\n");
        rf = open(path, "r");
        content: str = rf.read();
        rf.close();
        assert content == "two\n", "content replaced";
        leftovers: list[str] = [];
        for name in os.listdir(base) {
            if name.startswith(".jacup-tmp-") {
                leftovers.append(name);
            }
        }
        assert not leftovers, f"no temp leftovers: {leftovers}";
    } finally {
        cleanupTmp(base);
    }
}

test "config roundtrips and rejects malformed json" {
    pair = newTmpHome();
    home = pair[0];
    base = pair[1];
    try {
        cfg = loadConfig(home);
        assert cfg.default_version is None and cfg.release_index_url is None, "defaults when absent";
        cfg.default_version = "0.9.2";
        cfg.release_index_url = "https://example.test/index.json";
        saveConfig(home, cfg);
        again = loadConfig(home);
        assert again.default_version == "0.9.2", "default persisted";
        assert again.release_index_url == "https://example.test/index.json", "index url persisted";
        path: str = home.configFile();
        writeTextAtomic(path, "{definitely not json");
        raised: bool = False;
        try {
            _ = loadConfig(home);
        } except JacupError as e {
            raised = True;
            assert path in str(e), f"error names the file: {str(e)}";
        }
        assert raised, "malformed config must fail";
    } finally {
        cleanupTmp(base);
    }
}

test "index url precedence flag env config" {
    pair = newTmpHome();
    home = pair[0];
    base = pair[1];
    saved = os.environ.get("JACUP_INDEX_URL");
    try {
        try {
            _ = resolveIndexUrl(None, home);
            assert False, "unconfigured index must fail";
        } except JacupError as e {
            assert "no release index configured" in str(e), f"remediation present: {str(e)}";
        }
        cfg = JacupConfig();
        cfg.release_index_url = "https://config.example/index.json";
        saveConfig(home, cfg);
        assert resolveIndexUrl(None, home) == "https://config.example/index.json", "config used";
        os.environ["JACUP_INDEX_URL"] = "https://env.example/index.json";
        assert resolveIndexUrl(None, home) == "https://env.example/index.json", "env overrides config";
        assert resolveIndexUrl("https://flag.example/index.json", home) == "https://flag.example/index.json", "flag overrides all";
    } finally {
        if saved is None {
            os.environ.pop("JACUP_INDEX_URL", None);
        } else {
            os.environ["JACUP_INDEX_URL"] = saved;
        }
        cleanupTmp(base);
    }
}

test "pin resolution walks parents and validates content" {
    pair = newTmpHome();
    home = pair[0];
    base = pair[1];
    try {
        project: str = os.path.join(base, "project");
        nested: str = os.path.join(project, "src", "deep");
        os.makedirs(nested);
        raised: bool = False;
        try {
            _ = resolveVersion(home, nested);
        } except JacupError as e {
            raised = True;
            assert "no Jac version selected" in str(e), f"no-selection error actionable: {str(e)}";
        }
        assert raised, "no selection must fail";
        cfg = JacupConfig();
        cfg.default_version = "1.2.3";
        saveConfig(home, cfg);
        sel = resolveVersion(home, nested);
        assert sel.version == "1.2.3" and sel.source == "global default", "global default used";
        writeTextAtomic(pinFilePath(project), "0.9.0\n");
        sel = resolveVersion(home, nested);
        assert sel.version == "0.9.0", "nearest pin wins";
        assert "project" in sel.source and pinFilePath(project) in sel.source, "pin source names path";
        sel = resolveVersion(home, project);
        assert sel.version == "0.9.0", "pin found in its own directory";
        writeTextAtomic(pinFilePath(nested), "0.8.0\n");
        sel = resolveVersion(home, nested);
        assert sel.version == "0.8.0", "nearer pin beats parent pin";
        writeTextAtomic(pinFilePath(nested), "not-a-version\n");
        raised = False;
        try {
            _ = resolveVersion(home, nested);
        } except JacupError as e {
            raised = True;
            assert pinFilePath(nested) in str(e), f"malformed pin names path: {str(e)}";
        }
        assert raised, "malformed pin must fail";
        os.unlink(pinFilePath(nested));
        unpinProjectVersion(project);
        assert not os.path.exists(pinFilePath(project)), "unpin removes the file";
        raised = False;
        try {
            unpinProjectVersion(project);
        } except JacupError as e {
            raised = True;
            assert "nothing to unpin" in str(e), f"unpin absent error: {str(e)}";
        }
        assert raised, "unpin without pin must fail";
    } finally {
        cleanupTmp(base);
    }
}

test "install verifies checksums and stays atomic" {
    pair = newTmpHome();
    home = pair[0];
    base = pair[1];
    try {
        corrupt: str = buildIndex(base + "-corrupt", [{
            "version": "0.9.2",
            "artifacts": [{
                "os": "linux",
                "arch": "x86_64",
                "url": "file://" + fixturePath("fakejac-0.9.0.sh"),
                "sha256": "0" * 64,
            }],
        }]);
        raised: bool = False;
        try {
            _ = installVersion(home, "0.9.2", corrupt);
        } except JacupError as e {
            raised = True;
            assert "checksum mismatch" in str(e), f"checksum error actionable: {str(e)}";
        }
        assert raised, "corrupted artifact must be rejected";
        assert not os.path.isdir(home.versionDir("0.9.2")), "no version directory on checksum failure";
        downloads: list[str] = [];
        if os.path.isdir(home.downloadsDir()) {
            for name in os.listdir(home.downloadsDir()) {
                downloads.append(name);
            }
        }
        assert not downloads, f"temporary downloads cleaned: {downloads}";

        index: str = buildIndex(base + "-idx", [
            fixtureEntry("0.9.0", "fakejac-0.9.0.sh"),
            fixtureEntry("0.9.1", "fakejac-0.9.1.sh"),
        ]);
        _ = installVersion(home, "0.9.0", index);
        binPath: str = home.binaryPath("0.9.0");
        assert os.path.isfile(binPath), "binary installed";
        assert os.access(binPath, os.X_OK), "binary is executable";
        meta = loadMetadata(home, "0.9.0");
        assert meta.version == "0.9.0", "metadata version";
        assert meta.sha256 == sha256File(binPath), "metadata checksum matches file";
        assert meta.target == currentTarget().name(), "metadata target";
        assert meta.url.startswith("file://"), "metadata url recorded";
        assert meta.installed_at != "", "metadata timestamp recorded";
        assert installedVersions(home) == ["0.9.0"], "one version listed";

        idempotentPath: str = installVersion(home, "0.9.0", index);
        assert idempotentPath == home.versionDir("0.9.0"), "reinstall of identical version is accepted";

        metaPath: str = home.metadataPath("0.9.0");
        writeTextAtomic(metaPath, json.dumps({
            "version": "0.9.0",
            "target": "linux-x86_64",
            "url": "file://elsewhere",
            "sha256": "1" * 64,
            "installed_at": "tampered",
        }) + "\n");
        raised = False;
        try {
            _ = installVersion(home, "0.9.0", index);
        } except JacupError as e {
            raised = True;
            assert "already installed" in str(e) and "uninstall" in str(e), f"conflict actionable: {str(e)}";
        }
        assert raised, "conflicting reinstall must fail";
        rf = open(metaPath, "r");
        preserved: str = rf.read();
        rf.close();
        assert "tampered" in preserved, "existing version directory untouched on conflict";
    } finally {
        cleanupTmp(base);
        cleanupTmp(base + "-corrupt");
        cleanupTmp(base + "-idx");
    }
}

test "uninstall guards the default and removes exact versions" {
    pair = newTmpHome();
    home = pair[0];
    base = pair[1];
    try {
        index: str = buildIndex(base + "-idx", [
            fixtureEntry("0.9.0", "fakejac-0.9.0.sh"),
            fixtureEntry("0.9.1", "fakejac-0.9.1.sh"),
        ]);
        _ = installVersion(home, "0.9.0", index);
        _ = installVersion(home, "0.9.1", index);
        cfg = JacupConfig();
        cfg.default_version = "0.9.1";
        saveConfig(home, cfg);
        raised: bool = False;
        try {
            uninstallVersion(home, "0.9.1");
            assert False, "uninstalling the default must fail";
        } except JacupError as e {
            raised = True;
            assert "refusing" in str(e) and "use" in str(e), f"guard actionable: {str(e)}";
        }
        assert raised, "default guard tripped";
        assert os.path.isdir(home.versionDir("0.9.1")), "default version still installed";
        uninstallVersion(home, "0.9.0");
        assert not os.path.isdir(home.versionDir("0.9.0")), "non-default removed";
        raised = False;
        try {
            uninstallVersion(home, "9.9.9");
        } except JacupError as e {
            raised = True;
            assert "not installed" in str(e), f"missing version error: {str(e)}";
        }
        assert raised, "uninstall of unknown version must fail";
        cfg.default_version = None;
        saveConfig(home, cfg);
        uninstallVersion(home, "0.9.1");
        assert installedVersions(home) == [], "all versions removed";
    } finally {
        cleanupTmp(base);
        cleanupTmp(base + "-idx");
    }
}

test "missing versions produce actionable selection errors" {
    pair = newTmpHome();
    home = pair[0];
    base = pair[1];
    try {
        raised: bool = False;
        try {
            _ = resolveVersion(home, base).version;
        } except JacupError {
            raised = True;
        }
        assert raised, "unresolved selection raises";
        cfg = JacupConfig();
        cfg.default_version = "5.5.5";
        saveConfig(home, cfg);
        sel = resolveVersion(home, base);
        assert sel.version == "5.5.5", "default resolves without existence check";
        raised = False;
        try {
            _ = installedPath(home, sel.version);
            assert False, "missing default must fail";
        } except JacupError as e {
            raised = True;
            assert "not installed" in str(e) and "install" in str(e), f"remediation present: {str(e)}";
        }
        assert raised, "selection with missing install must fail";
    } finally {
        cleanupTmp(base);
    }
}
