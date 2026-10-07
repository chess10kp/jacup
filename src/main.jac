"""jacup command-line boundary: parsing, dispatch, and exit statuses.

Exit codes: 0 on success; 2 for CLI, configuration, and selection errors;
`exec` propagates the launched Jac process exit status unchanged.
"""

import os;
import from os.path { abspath }
import sys;
import from src.config { loadConfig, resolveIndexUrl }
import from src.completions { bashCompletions, zshCompletions }
import from src.doctor { runDoctor }
import from src.errors { JacupError }
import from src.exec { execJac }
import from src.install { installVersion, uninstallVersion }
import from src.installed { installedVersions }
import from src.path_core { binDir }
import from src.target { TARGET_OS }
import from src.releases { availableVersionStrings, currentTarget, fetchIndex, findRelease, latestVersionString }
import from src.selection {
    pinProjectVersion,
    resolveAliasOrVersion,
    resolveVersion,
    setDefaultVersion,
    setAlias,
    removeAlias,
    unpinProjectVersion,
    installedPath,
}
import from src.semver { parseVersion, sortVersionStrings }
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

def resolveHome() -> dict[str, str] {
    homeOverride = os.environ.get("JACUP_HOME");
    if homeOverride {
        rootDir: str = abspath(homeOverride);
        return {"data_dir": rootDir, "config_dir": rootDir};
    }
    if TARGET_OS == "windows" {
        return {"data_dir": windowsDataDir(), "config_dir": windowsConfigDir()};
    }
    dataBase = os.environ.get("XDG_DATA_HOME");
    if not dataBase {
        homeDir: str = os.environ.get("HOME", "");
        if not homeDir {
            raise JacupError("cannot locate the home directory; set JACUP_HOME explicitly");
        }
        dataBase = os.path.join(homeDir, ".local", "share");
    }
    configBase = os.environ.get("XDG_CONFIG_HOME");
    if not configBase {
        homeDir: str = os.environ.get("HOME", "");
        if not homeDir {
            raise JacupError("cannot locate the home directory; set JACUP_HOME explicitly");
        }
        configBase = os.path.join(homeDir, ".config");
    }
    return {
        "data_dir": os.path.join(dataBase, "jacup"),
        "config_dir": os.path.join(configBase, "jacup"),
    };
}

glob VERSION: str = "0.1.3";

glob USAGE: str = """jacup 0.1.3 - standalone Jac version manager

usage: jacup <command> [args]

commands:
  install <version|latest> [--index-url <url>]  install an exact version or the newest release
  uninstall <version>                           remove an installed version
  update [--index-url <url>]                    install the newest release and make it the global default
  list                                          list installed versions
  aliases                                       list version aliases
  available [--index-url <url>]                 list versions from the release index
  use <version>                                 set the global default version
  switch <version|alias>                        set the global default version by version or alias
  alias <name> <version>                        give an installed version an alias
  unalias <name>                                remove an alias
  pin <version>                                 pin the version for the current project
  unpin                                         remove .jac-version from the current directory
  current                                       show the resolved version and binary path
  path                                          print only the resolved binary path
  bin                                           print the bin directory holding the 'jac' launcher
  exec -- <jac-args>                            run the selected jac binary with exact args
  doctor [--index-url <url>]                    check installation health
  completions <bash|zsh>                        emit a shell completion script

shell setup: add these to your ~/.bashrc or ~/.zshrc:
  export PATH="$(jacup bin):$PATH"               makes the managed 'jac' your jac
  source <(jacup completions bash)               zsh: source <(jacup completions zsh)

versions are exact: MAJOR.MINOR.PATCH[-PRERELEASE] (e.g. 0.9.2, 1.0.0-rc.1);
'install latest' and 'update' pick the newest release with a build for this platform.
release index precedence: --index-url, then JACUP_INDEX_URL, then config.json.

to run jac directly, put jacup's bin directory on your PATH (print it with 'jacup bin'):
  export PATH="$(jacup bin):$PATH"
the 'jac' launcher there always follows the global default version (use/switch/update).
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

def dispatch(home: dict[str, str], cmd: str, tokens: list[str]) -> int {
    if cmd == "install" {
        parsed = parseIndexFlag(tokens);
        version: str = requireVersionToken(parsed.positional, cmd);
        if version != "latest" {
            parseVersion(version);
        }
        indexUrl: str = resolveIndexUrl(parsed.index_url, home);
        if version == "latest" {
            version = latestReleaseVersion(indexUrl);
            print(f"jacup: latest release is {version}");
        }
        _ = installVersion(home, version, indexUrl);
        return 0;
    }
    if cmd == "update" {
        parsed = parseIndexFlag(tokens);
        requireNoPositional(parsed.positional, cmd);
        return cmdUpdate(home, parsed.index_url);
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
    if cmd == "aliases" {
        requireNoPositional(tokens, cmd);
        return cmdAliases(home);
    }
    if cmd == "available" {
        parsed = parseIndexFlag(tokens);
        requireNoPositional(parsed.positional, cmd);
        return cmdAvailable(home, parsed.index_url);
    }
    if cmd == "use" {
        version = requireVersionToken(tokens, cmd);
        parseVersion(version);
        shim: str | None = setDefaultVersion(home, version);
        print(f"jacup: default Jac version set to {version}");
        printLauncherHint(home, shim);
        return 0;
    }
    if cmd == "switch" {
        if len(tokens) != 1 {
            raise JacupError("'switch' requires exactly one <version|alias> argument; see 'jacup --help'");
        }
        active: str = resolveAliasOrVersion(home, tokens[0]);
        shim = setDefaultVersion(home, active);
        print(f"jacup: default Jac version set to {active}");
        printLauncherHint(home, shim);
        return 0;
    }
    if cmd == "alias" {
        if len(tokens) != 2 {
            raise JacupError("'alias' requires exactly two arguments: <name> <version>; see 'jacup --help'");
        }
        setAlias(home, tokens[0], tokens[1]);
        print(f"jacup: alias '{tokens[0]}' now refers to Jac {tokens[1]}");
        return 0;
    }
    if cmd == "unalias" {
        if len(tokens) != 1 {
            raise JacupError("'unalias' requires exactly one <name> argument; see 'jacup --help'");
        }
        removed: str = removeAlias(home, tokens[0]);
        print(f"jacup: removed alias '{tokens[0]}' (was Jac {removed})");
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
        print(f"jacup: removed {os.path.join(os.getcwd(), '.jac-version')}");
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
    if cmd == "bin" {
        requireNoPositional(tokens, cmd);
        print(binDir(home));
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
    if cmd == "completions" {
        if len(tokens) != 1 {
            raise JacupError("'completions' requires exactly one shell argument: bash or zsh; see 'jacup --help'");
        }
        shell: str = tokens[0];
        if shell != "bash" and shell != "zsh" {
            raise JacupError(f"unsupported shell '{shell}'; use 'jacup completions bash' or 'jacup completions zsh'");
        }
        if shell == "bash" {
            print(bashCompletions());
        } else {
            print(zshCompletions());
        }
        return 0;
    }
    raise JacupError(f"unknown command '{cmd}'; see 'jacup --help'");
}

def cmdList(home: dict[str, str]) -> int {
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

def cmdAvailable(home: dict[str, str], indexFlag: str | None) -> int {
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

def cmdCurrent(home: dict[str, str]) -> int {
    sel = resolveVersion(home, os.getcwd());
    binPath: str = installedPath(home, sel.version);
    print(f"version: {sel.version} ({sel.source})");
    print(f"binary: {binPath}");
    return 0;
}

def latestReleaseVersion(indexUrl: str) -> str {
    index = fetchIndex(indexUrl);
    target = currentTarget();
    latest: str | None = latestVersionString(index, target);
    if latest is None {
        raise JacupError(
            f"no release in index {indexUrl} offers an artifact for target '{target.name()}'"
        );
    }
    return latest;
}

def printLauncherHint(home: dict[str, str], shim: str | None) -> None {
    if shim is None {
        sys.stderr.write(
            f"jacup: could not create the 'jac' launcher link in {binDir(home)}; on Windows, "
            "enable Developer Mode or run as an administrator; until then run Jac via 'jacup exec --'\n"
        );
        return;
    }
    print(f"jacup: '{shim}' runs the default Jac; add {binDir(home)} to PATH to use it as 'jac'");
}

def cmdUpdate(home: dict[str, str], indexFlag: str | None) -> int {
    indexUrl: str = resolveIndexUrl(indexFlag, home);
    latest: str = latestReleaseVersion(indexUrl);
    cfg = loadConfig(home);
    installed: list[str] = installedVersions(home);
    alreadyDefault: bool = cfg.default_version == latest and latest in installed;
    if latest not in installed {
        _ = installVersion(home, latest, indexUrl);
    }
    if alreadyDefault {
        print(f"jacup: Jac {latest} is already the latest version and the global default");
    } else {
        print(f"jacup: default Jac version set to {latest}");
    }
    shim: str | None = setDefaultVersion(home, latest);
    printLauncherHint(home, shim);
    return 0;
}

def cmdAliases(home: dict[str, str]) -> int {
    cfg = loadConfig(home);
    if not cfg.aliases {
        print("no aliases defined");
        return 0;
    }
    for name in sorted(cfg.aliases) {
        print(f"{name} = {cfg.aliases[name]}");
    }
    return 0;
}

def runMain(argv: list[str]) -> int {
    if not argv {
        sys.stderr.write("jacup: no command given; here is how jacup works:\n\n");
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
    home: dict[str, str] = resolveHome();
    try {
        return dispatch(home, cmd, rest);
    } except JacupError as e {
        sys.stderr.write(f"jacup: error: {e.message}\n");
        return 2;
    } except KeyboardInterrupt {
        raise;
    } except Exception as e {
        sys.stderr.write(f"jacup: error: unexpected failure: {type(e).__name__}: {e}\n");
        return 2;
    }
}

with entry:__main__ {
    sys.exit(runMain(sys.argv[1:]));
}
