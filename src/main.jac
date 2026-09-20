"""jacup command-line boundary: parsing, dispatch, and exit statuses.

Exit codes: 0 on success; 2 for CLI, configuration, and selection errors;
`exec` propagates the launched Jac process exit status unchanged.
"""

import os;
import sys;
import from src.config { loadConfig, resolveIndexUrl }
import from src.doctor { runDoctor }
import from src.errors { JacupError }
import from src.exec { execJac }
import from src.install { installVersion, installedVersions, uninstallVersion }
import from src.paths { JacupHome, resolveHome }
import from src.releases { availableVersionStrings, currentTarget, fetchIndex, findRelease }
import from src.selection {
    pinProjectVersion,
    resolveVersion,
    setDefaultVersion,
    unpinProjectVersion,
    installedPath,
}
import from src.semver { parseVersion, sortVersionStrings }

glob VERSION: str = "0.1.0";

glob USAGE: str = """jacup 0.1.0 - standalone Jac version manager

usage: jacup <command> [args]

commands:
  install <version> [--index-url <url>]   download and install an exact version
  uninstall <version>                     remove an installed version
  list                                    list installed versions
  available [--index-url <url>]           list versions from the release index
  use <version>                           set the global default version
  pin <version>                           pin the version for the current project
  unpin                                   remove .jac-version from the current directory
  current                                 show the resolved version and binary path
  path                                    print only the resolved binary path
  exec -- <jac-args>                      run the selected jac binary with exact args
  doctor [--index-url <url>]              check installation health

versions are exact: MAJOR.MINOR.PATCH[-PRERELEASE] (e.g. 0.9.2, 1.0.0-rc.1).
release index precedence: --index-url, then JACUP_INDEX_URL, then config.json.
""";

obj ParsedArgs {
    has positional: list[str];
    has index_url: str | None;
}

def parseIndexFlag(tokens: list[str]) -> ParsedArgs {
    positional: list[str] = [];
    indexUrl: str | None = None;
    i: int = 0;
    while i < len(tokens) {
        t: str = tokens[i];
        if t == "--index-url" {
            if indexUrl is not None {
                raise JacupError("--index-url given more than once");
            }
            if i + 1 >= len(tokens) {
                raise JacupError("--index-url requires a URL argument");
            }
            indexUrl = tokens[i + 1];
            i = i + 2;
        } elif t.startswith("--index-url=") {
            if indexUrl is not None {
                raise JacupError("--index-url given more than once");
            }
            indexUrl = t[len("--index-url="):];
            i = i + 1;
        } else {
            positional.append(t);
            i = i + 1;
        }
    }
    return ParsedArgs(positional=positional, index_url=indexUrl);
}

def requireVersionToken(tokens: list[str], cmd: str) -> str {
    if len(tokens) != 1 {
        raise JacupError(f"'{cmd}' requires exactly one <version> argument; see 'jacup --help'");
    }
    return tokens[0];
}

def requireNoPositional(tokens: list[str], cmd: str) -> None {
    if tokens {
        raise JacupError(f"'{cmd}' takes no positional arguments (got '{tokens[0]}'); see 'jacup --help'");
    }
}

def dispatch(home: JacupHome, cmd: str, tokens: list[str]) -> int {
    if cmd == "install" {
        parsed = parseIndexFlag(tokens);
        version: str = requireVersionToken(parsed.positional, cmd);
        parseVersion(version);
        indexUrl: str = resolveIndexUrl(parsed.index_url, home);
        _ = installVersion(home, version, indexUrl);
        return 0;
    }
    if cmd == "uninstall" {
        version = requireVersionToken(tokens, cmd);
        parseVersion(version);
        uninstallVersion(home, version);
        return 0;
    }
    if cmd == "list" {
        requireNoPositional(tokens, cmd);
        return cmdList(home);
    }
    if cmd == "available" {
        parsed = parseIndexFlag(tokens);
        requireNoPositional(parsed.positional, cmd);
        return cmdAvailable(home, parsed.index_url);
    }
    if cmd == "use" {
        version = requireVersionToken(tokens, cmd);
        parseVersion(version);
        setDefaultVersion(home, version);
        print(f"jacup: default Jac version set to {version}");
        return 0;
    }
    if cmd == "pin" {
        version = requireVersionToken(tokens, cmd);
        parseVersion(version);
        pinPath: str = pinProjectVersion(home, version, os.getcwd());
        print(f"jacup: pinned {version} in {pinPath}");
        return 0;
    }
    if cmd == "unpin" {
        requireNoPositional(tokens, cmd);
        unpinProjectVersion(os.getcwd());
        print(f"jacup: removed {os.path.join(os.path.abspath(os.getcwd()), '.jac-version')}");
        return 0;
    }
    if cmd == "current" {
        requireNoPositional(tokens, cmd);
        return cmdCurrent(home);
    }
    if cmd == "path" {
        requireNoPositional(tokens, cmd);
        sel = resolveVersion(home, os.getcwd());
        print(installedPath(home, sel.version));
        return 0;
    }
    if cmd == "exec" {
        if not tokens or tokens[0] != "--" {
            raise JacupError("'exec' requires '--' before jac arguments; usage: jacup exec -- <jac-args>");
        }
        return execJac(home, tokens[1:]);
    }
    if cmd == "doctor" {
        parsed = parseIndexFlag(tokens);
        requireNoPositional(parsed.positional, cmd);
        return runDoctor(home, parsed.index_url);
    }
    raise JacupError(f"unknown command '{cmd}'; see 'jacup --help'");
}

def cmdList(home: JacupHome) -> int {
    names = installedVersions(home);
    if not names {
        print("no versions installed");
        return 0;
    }
    cfg = loadConfig(home);
    for v in sortVersionStrings(names) {
        suffix: str = " (default)" if cfg.default_version == v else "";
        print(v + suffix);
    }
    return 0;
}

def cmdAvailable(home: JacupHome, indexFlag: str | None) -> int {
    indexUrl: str = resolveIndexUrl(indexFlag, home);
    index = fetchIndex(indexUrl);
    target = currentTarget();
    print(f"release index: {indexUrl}");
    print(f"target: {target.name()}");
    if not index.releases {
        print("no versions in index");
        return 0;
    }
    for v in availableVersionStrings(index) {
        release = findRelease(index, v);
        hasArtifact: bool = False;
        if release is not None {
            for artifact in release.artifacts {
                if artifact.target_os == target.target_os and artifact.arch == target.arch {
                    hasArtifact = True;
                }
            }
        }
        mark: str = "yes" if hasArtifact else "no";
        print(f"{v}  {target.name()}: {mark}");
    }
    return 0;
}

def cmdCurrent(home: JacupHome) -> int {
    sel = resolveVersion(home, os.getcwd());
    binPath: str = installedPath(home, sel.version);
    print(f"version: {sel.version} ({sel.source})");
    print(f"binary: {binPath}");
    return 0;
}

def main(argv: list[str]) -> int {
    if not argv {
        sys.stderr.write("jacup: error: no command given\n");
        sys.stderr.write(USAGE);
        return 2;
    }
    cmd: str = argv[0];
    rest: list[str] = argv[1:];
    if cmd in ("-h", "--help", "help") {
        print(USAGE);
        return 0;
    }
    if cmd in ("-V", "--version") {
        print(f"jacup {VERSION}");
        return 0;
    }
    if cmd.startswith("-") {
        sys.stderr.write(f"jacup: error: unknown option '{cmd}'; see 'jacup --help'\n");
        return 2;
    }
    home: JacupHome = resolveHome();
    try {
        return dispatch(home, cmd, rest);
    } except JacupError as e {
        sys.stderr.write(f"jacup: error: {str(e)}\n");
        return 2;
    } except KeyboardInterrupt {
        raise;
    } except Exception as e {
        sys.stderr.write(f"jacup: error: unexpected failure: {type(e).__name__}: {str(e)}\n");
        return 2;
    }
}

with entry:__main__ {
    sys.exit(main(sys.argv[1:]));
}
