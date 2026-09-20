"""End-to-end CLI proof against a temporary JACUP_HOME.

Runs the real command boundary (`jac run src/main.jac ...`) through the full
ghcup-style flow: install two fixture versions, pin the older one in a nested
project, exec through the pin, unpin to fall back to the global default,
propagate the fixture's exit status, reject corrupted artifacts and conflicting
reinstalls, and verify doctor plus the failure paths leave no state behind.
"""

import json;
import hashlib;
import os;
import shutil;
import subprocess;
import tempfile;
import from src.errors { JacupError }

glob REPO_ROOT_CACHE: str = "";

def findRoot(start: str) -> str {
    current: str = os.path.abspath(start);
    while True {
        if os.path.isfile(os.path.join(current, "jac.toml")) {
            return current;
        }
        parent: str = os.path.dirname(current);
        if parent == current {
            raise JacupError(f"no jac.toml found walking up from {start}");
        }
        current = parent;
    }
}

def repoRoot() -> str {
    if REPO_ROOT_CACHE == "" {
        REPO_ROOT_CACHE = findRoot(os.getcwd());
    }
    return REPO_ROOT_CACHE;
}

def fixturePath(name: str) -> str {
    return os.path.join(repoRoot(), "tests", "fixtures", name);
}

def sha256File(path: str) -> str {
    digest = hashlib.sha256();
    fh = open(path, "rb");
    try {
        while True {
            chunk: bytes = fh.read(1024 * 1024);
            if not chunk {
                break;
            }
            digest.update(chunk);
        }
    } finally {
        fh.close();
    }
    return digest.hexdigest();
}

def fixtureEntry(version: str, fixture: str) -> dict[str, any] {
    return {
        "version": version,
        "artifacts": [
            {
                "os": "linux",
                "arch": "x86_64",
                "url": "file://" + fixturePath(fixture),
                "sha256": sha256File(fixturePath(fixture)),
            }
        ],
    };
}

def writeIndex(dirPath: str, entries: list[dict[str, any]]) -> str {
    os.makedirs(dirPath, exist_ok=True);
    path: str = os.path.join(dirPath, "index.json");
    fh = open(path, "w");
    try {
        fh.write(json.dumps({"versions": entries}, indent=2) + "\n");
    } finally {
        fh.close();
    }
    return "file://" + path;
}

def runCli(jacBin: str, mainPath: str, args: list[str], env: dict[str, str], cwd: str) -> tuple[int, str, str] {
    proc = subprocess.run(
        [jacBin, "run", mainPath] + args,
        env=env,
        cwd=cwd,
        capture_output=True,
        text=True,
    );
    return (proc.returncode, proc.stdout, proc.stderr);
}

test "install pin exec unpin flow via the real cli" {
    jacBin = shutil.which("jac");
    assert jacBin, "jac executable must be on PATH";
    mainPath: str = os.path.join(repoRoot(), "src", "main.jac");
    assert os.path.isfile(mainPath), f"entry point missing: {mainPath}";

    home: str = tempfile.mkdtemp(prefix="jacup-it-home-");
    proj: str = tempfile.mkdtemp(prefix="jacup-it-proj-");
    work: str = tempfile.mkdtemp(prefix="jacup-it-idx-");
    nested: str = os.path.join(proj, "nested", "deep");
    os.makedirs(nested);

    env = os.environ.copy();
    env["JACUP_HOME"] = home;
    env.pop("JACUP_INDEX_URL", None);

    indexUrl: str = writeIndex(
        os.path.join(work, "idx"),
        [fixtureEntry("0.9.0", "fakejac-0.9.0.sh"), fixtureEntry("0.9.1", "fakejac-0.9.1.sh")],
    );
    corruptUrl: str = writeIndex(os.path.join(work, "corrupt"), [{
        "version": "0.9.2",
        "artifacts": [{
            "os": "linux",
            "arch": "x86_64",
            "url": "file://" + fixturePath("fakejac-0.9.0.sh"),
            "sha256": "0" * 64,
        }],
    }]);
    malformedUrl: str = writeIndex(os.path.join(work, "malformed"), [
        {"version": "1.0.0", "artifacts": []},
        {"version": "1.0.0", "artifacts": []},
    ]);

    try {
        # available lists sorted versions with target availability.
        r = runCli(jacBin, mainPath, ["available", "--index-url", indexUrl], env, nested);
        assert r[0] == 0, f"available rc={r[0]} err={r[2]}";
        assert "0.9.0" in r[1] and "0.9.1" in r[1], f"available versions listed: {r[1]}";
        assert "linux-x86_64: yes" in r[1], f"target availability shown: {r[1]}";

        # install two fixture versions.
        r = runCli(jacBin, mainPath, ["install", "0.9.1", "--index-url", indexUrl], env, nested);
        assert r[0] == 0, f"install 0.9.1 rc={r[0]} err={r[2]}";
        assert "installed Jac 0.9.1" in r[1], f"install output: {r[1]}";
        r = runCli(jacBin, mainPath, ["install", "0.9.0", "--index-url", indexUrl], env, nested);
        assert r[0] == 0, f"install 0.9.0 rc={r[0]} err={r[2]}";

        r = runCli(jacBin, mainPath, ["list"], env, nested);
        assert r[0] == 0 and "0.9.0" in r[1] and "0.9.1" in r[1], f"list shows both: {r[1]}";

        # global default.
        r = runCli(jacBin, mainPath, ["use", "0.9.1"], env, nested);
        assert r[0] == 0, f"use rc={r[0]} err={r[2]}";
        r = runCli(jacBin, mainPath, ["list"], env, nested);
        assert "0.9.1 (default)" in r[1], f"default marked: {r[1]}";
        r = runCli(jacBin, mainPath, ["current"], env, nested);
        assert r[0] == 0 and "0.9.1" in r[1] and "global default" in r[1], f"current: {r[1]}";
        r = runCli(jacBin, mainPath, ["path"], env, nested);
        assert r[0] == 0 and r[1].strip().endswith(os.path.join("versions", "0.9.1", "jac")), f"path: {r[1]}";

        # pin the older version in the project; exec from a nested directory.
        pinPath: str = os.path.join(proj, ".jac-version");
        fh = open(pinPath, "w");
        try {
            fh.write("0.9.0\n");
        } finally {
            fh.close();
        }
        r = runCli(jacBin, mainPath, ["exec", "--", "--version"], env, nested);
        assert r[0] == 0, f"exec rc={r[0]} err={r[2]}";
        assert "fake-jac 0.9.0" in r[1], f"pinned fixture selected: {r[1]}";
        assert "arg: --version" in r[1], f"arguments preserved: {r[1]}";

        # unpin: falls back to the global default version.
        os.unlink(pinPath);
        r = runCli(jacBin, mainPath, ["exec", "--", "--version"], env, nested);
        assert r[0] == 0 and "fake-jac 0.9.1" in r[1], f"global version after unpin: {r[1]} out={r[0]}{r[2]}";

        # the fixture's deliberate nonzero status propagates unchanged.
        execEnv = env.copy();
        execEnv["FAKEJAC_EXIT"] = "3";
        r = runCli(jacBin, mainPath, ["exec", "--", "check", "stuff"], execEnv, nested);
        assert r[0] == 3, f"fixture exit status must propagate, got rc={r[0]}";
        assert "arg: check" in r[1] and "arg: stuff" in r[1], f"args preserved: {r[1]}";

        # a corrupted artifact is rejected with no installed version left behind.
        r = runCli(jacBin, mainPath, ["install", "0.9.2", "--index-url", corruptUrl], env, nested);
        assert r[0] == 2, f"corrupt install rc={r[0]}";
        assert "checksum mismatch" in r[2], f"checksum diagnostic: {r[2]}";
        assert not os.path.isdir(os.path.join(home, "versions", "0.9.2")), "no 0.9.2 directory";
        r = runCli(jacBin, mainPath, ["list"], env, nested);
        assert "0.9.2" not in r[1], f"list hides rejected version: {r[1]}";
        downloads: str = os.path.join(home, "downloads");
        leftovers: list[str] = [];
        if os.path.isdir(downloads) {
            for name in os.listdir(downloads) {
                leftovers.append(name);
            }
        }
        assert not leftovers, f"download staging cleaned: {leftovers}";

        # an existing installed version with different metadata is not overwritten.
        metaPath: str = os.path.join(home, "versions", "0.9.0", "metadata.json");
        fh = open(metaPath, "r");
        try {
            originalMeta: str = fh.read();
        } finally {
            fh.close();
        }
        tampered = json.loads(originalMeta);
        tampered["sha256"] = "2" * 64;
        fh = open(metaPath, "w");
        try {
            fh.write(json.dumps(tampered, indent=2, sort_keys=True) + "\n");
        } finally {
            fh.close();
        }
        r = runCli(jacBin, mainPath, ["install", "0.9.0", "--index-url", indexUrl], env, nested);
        assert r[0] == 2, f"conflicting install rc={r[0]}";
        assert "already installed" in r[2] and "uninstall" in r[2], f"conflict diagnostic: {r[2]}";
        fh = open(metaPath, "r");
        try {
            preservedMeta: str = fh.read();
        } finally {
            fh.close();
        }
        assert preservedMeta == json.dumps(tampered, indent=2, sort_keys=True) + "\n", "conflicted directory untouched";

        # restore the untampered metadata so the installation is valid again.
        fh = open(metaPath, "w");
        try {
            fh.write(originalMeta);
        } finally {
            fh.close();
        }

        # doctor passes on the valid install (no index configured: informational).
        r = runCli(jacBin, mainPath, ["doctor"], env, nested);
        assert r[0] == 0, f"doctor rc={r[0]} out={r[1]} err={r[2]}";
        assert "all checks passed" in r[1], f"doctor output: {r[1]}";

        # doctor fails with a missing-path diagnostic after the executable vanishes.
        os.unlink(os.path.join(home, "versions", "0.9.1", "jac"));
        r = runCli(jacBin, mainPath, ["doctor"], env, nested);
        assert r[0] == 2, f"doctor must fail rc={r[0]}";
        assert "FAIL" in r[1], f"doctor reports failures: {r[1]}";
        r = runCli(jacBin, mainPath, ["current"], env, nested);
        assert r[0] == 2, f"current with missing binary rc={r[0]}";

        # failure paths: malformed pin, path-like version, malformed index.
        r = runCli(jacBin, mainPath, ["pin", "../../etc"], env, nested);
        assert r[0] == 2, f"path-like pin rc={r[0]}";
        assert not os.path.exists(os.path.join(nested, ".jac-version")), "path-like pin created nothing";
        junk: str = os.path.join(nested, ".jac-version");
        fh = open(junk, "w");
        try {
            fh.write("garbage-version\n");
        } finally {
            fh.close();
        }
        r = runCli(jacBin, mainPath, ["current"], env, nested);
        assert r[0] == 2 and junk in r[2], f"malformed pin diagnostic names path: rc={r[0]} err={r[2]}";
        os.unlink(junk);
        r = runCli(jacBin, mainPath, ["available", "--index-url", malformedUrl], env, nested);
        assert r[0] == 2, f"malformed index rc={r[0]}";
        assert "duplicates version" in r[2], f"malformed index diagnostic: {r[2]}";

        # config and surviving installations were never mutated by failures.
        cfgPath: str = os.path.join(home, "config.json");
        fh = open(cfgPath, "r");
        try {
            cfg = json.loads(fh.read());
        } finally {
            fh.close();
        }
        assert cfg["default_version"] == "0.9.1", f"config default intact: {cfg}";
        installed: list[str] = sorted(os.listdir(os.path.join(home, "versions")));
        assert installed == ["0.9.0", "0.9.1"], f"installed set intact: {installed}";
    } finally {
        shutil.rmtree(home, ignore_errors=True);
        shutil.rmtree(proj, ignore_errors=True);
        shutil.rmtree(work, ignore_errors=True);
    }
}
