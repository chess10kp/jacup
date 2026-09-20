"""Standalone jacup entry point for PyInstaller.

Invokes the bundled src/main.jac through the jaclang CLI so the packaged
binary behaves exactly like `jac run src/main.jac <args>`, including
exit-status propagation from `jacup exec`. Onefile builds extract data files
under sys._MEIPASS; source builds fall back to the directory holding this
file. Script arguments are appended after the filename; jaclang's `run`
command treats everything after it as REMAINDER script args.
"""

import os;
import sys;

from jaclang.cli.cli import start_cli;

base = getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__)));
main = os.path.join(base, "src", "main.jac");
sys.argv = ["jacup", "run", main] + sys.argv[1:];
start_cli();
