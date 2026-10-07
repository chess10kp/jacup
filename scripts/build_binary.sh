#!/usr/bin/env bash
# Build the standalone jacup native executable.
# Usage: build_binary.sh <target> [dist-dir]   e.g. build_binary.sh linux-x86_64 dist
# Requires the Jac compiler (`jac`) installed on PATH.
set -euo pipefail

target="${1:?usage: build_binary.sh <target> [dist-dir]}"
dist_dir="${2:-dist}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

case "$target" in
  linux-x86_64) target_os="linux"; target_arch="x86_64" ;;
  linux-aarch64) target_os="linux"; target_arch="aarch64" ;;
  macos-aarch64) target_os="macos"; target_arch="aarch64" ;;
  macos-x86_64) target_os="macos"; target_arch="x86_64" ;;
  windows-x86_64) target_os="windows"; target_arch="x86_64" ;;
  windows-aarch64) target_os="windows"; target_arch="aarch64" ;;
  *)
    printf 'unsupported target: %s\n' "$target" >&2
    exit 2
    ;;
esac

if [[ "$dist_dir" = /* ]]; then
  output_dir="$dist_dir"
else
  output_dir="$root/$dist_dir"
fi
mkdir -p "$output_dir"

work="$(mktemp -d "${TMPDIR:-/tmp}/jacup-native.XXXXXX")"
trap 'rm -rf "$work"' EXIT
cp -R "$root/src" "$work/src"
cp "$root/jac.toml" "$work/jac.toml"
printf '%s\n' \
  '"""Build-selected target constants."""' \
  '' \
  "glob TARGET_OS: str = \"$target_os\"," \
  "     TARGET_ARCH: str = \"$target_arch\";" \
  > "$work/src/target.jac"

cd "$work"
jac build src/main.jac --native --memory rc -o "$output_dir/jacup-$target"
