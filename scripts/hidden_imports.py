"""Print newline-separated module imports to feed PyInstaller as hidden imports.

jaclang transpiles its own .jac sources at runtime through its meta importer,
so imports living inside those sources are invisible to PyInstaller's static
analysis. This script scans the installed jaclang package's .jac files and
emits every absolute import path it declares. Relative imports are skipped:
the meta importer resolves those from the package's data files at runtime.
"""

import importlib.util;
import pathlib;
import re;

spec = importlib.util.find_spec("jaclang");
if spec is None or not spec.submodule_search_locations:
    raise SystemExit("jaclang must be installed to enumerate hidden imports");
root = pathlib.Path(list(spec.submodule_search_locations)[0]);

mods: set[str] = set();
for f in root.rglob("*.jac"):
    text: str = f.read_text(errors="ignore");
    for m in re.finditer(r"^\s*import\s+(?:from\s+)?([\w.]+)", text, re.M):
        name: str = m.group(1);
        if not name.startswith("."):
            mods.add(name);

print("\n".join(sorted(mods)));
