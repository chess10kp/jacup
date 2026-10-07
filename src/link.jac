"""Native launcher symlink activation."""

import os;
import from src.errors { JacupError }
import from src.path_core { activeJacPath, binaryPath, binDir, isWindows }
def linkShellQuote(value: str) -> str {
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

def linkActiveJac(home: dict[str, str], version: str) -> str | None {
    target: str = binaryPath(home, version);
    if not os.path.isfile(target) {
        raise JacupError(f"cannot link 'jac': {target} is missing; install {version} first");
    }
    binPath: str = binDir(home);
    if not os.path.isdir(binPath) {
        os.makedirs(binPath);
    }
    shim: str = activeJacPath(home);
    linkTmp: str = shim + ".tmp-link";
    try {
        if os.path.exists(linkTmp) {
            os.unlink(linkTmp);
        }
        if os.system("ln -s " + linkShellQuote(target) + " " + linkShellQuote(linkTmp)) != 0 {
            if isWindows() {
                return None;
            }
            raise JacupError(f"cannot create the 'jac' launcher link {shim} -> {target}");
        }
        if os.system("mv " + linkShellQuote(linkTmp) + " " + linkShellQuote(shim)) != 0 {
            if os.path.exists(linkTmp) {
                os.unlink(linkTmp);
            }
            raise JacupError(f"cannot activate the 'jac' launcher link {shim}");
        }
    } except OSError as e {
        if isWindows() {
            return None;
        }
        raise JacupError(f"cannot create the 'jac' launcher link {shim} -> {target}: {e}");
    }
    return shim;
}
