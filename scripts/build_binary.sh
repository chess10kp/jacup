#!/usr/bin/env bash
# Build a standalone jacup binary with PyInstaller.
# Usage: build_binary.sh <target> [dist-dir]   e.g. build_binary.sh linux-x86_64 dist
# Requires a python environment with jaclang and pyinstaller installed.
set -euo pipefail

target="${1:?usage: build_binary.sh <target> [dist-dir]}"
dist_dir="${2:-dist}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

# One hidden-import flag per module found in jaclang's runtime-transpiled .jac
# sources; PyInstaller cannot see those imports statically.
flags="$(python scripts/hidden_imports.py | sed 's/^/--hidden-import /' | tr '\n' ' ')"

pyinstaller --onefile --clean --noconfirm \
  --name "jacup-$target" \
  --distpath "$dist_dir" --workpath build --specpath build \
  --collect-all jaclang \
  --add-data "$root/src:src" \
  $flags \
  entry.py
