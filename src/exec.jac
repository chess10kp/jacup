"""External Jac process execution.

`jacup exec -- <args>` resolves the selected version, validates its metadata
and executable, then invokes it through the host shell's `exec` command.
stdio and arguments pass through unchanged; the child's exit status is
returned to the caller.
"""

import os;
import sys;
import from src.errors { JacupError }
import from src.selection { installedPath, resolveVersion }

def execShellQuote(value: str) -> str {
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

def execJac(home: dict[str, str], jacArgs: list[str]) -> int {
    sel = resolveVersion(home, os.getcwd());
    binPath: str = installedPath(home, sel.version);
    command: str = "exec " + execShellQuote(binPath);
    for arg in jacArgs {
        command = command + " " + execShellQuote(arg);
    }
    try {
        sys.stdout.flush();
        sys.stderr.flush();
        result: int = os.system(command);
    } except OSError as e {
        raise JacupError(f"failed to launch Jac {sel.version} ({binPath}): {e}");
    }
    return int(result / 256) if result >= 0 else 2;
}
