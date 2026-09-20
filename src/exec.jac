"""External Jac process execution.

`jacup exec -- <args>` resolves the selected version, validates its metadata
and executable, then replaces the process with the Jac binary via os.execv:
stdio and arguments pass through unchanged and the child's exit status (or
signal death) is the caller's, with no manager code left behind.
"""

import os;
import sys;
import from src.errors { JacupError }
import from src.paths { JacupHome }
import from src.selection { installedPath, resolveVersion }

def execJac(home: JacupHome, jacArgs: list[str]) -> int {
    sel = resolveVersion(home, os.getcwd());
    binPath: str = installedPath(home, sel.version);
    argv: list[str] = [binPath] + jacArgs;
    try {
        sys.stdout.flush();
        sys.stderr.flush();
        os.execv(binPath, argv);
    } except JacupError {
        raise;
    } except OSError as e {
        raise JacupError(f"failed to launch Jac {sel.version} ({binPath}): {str(e)}");
    }
    return 0;
}
