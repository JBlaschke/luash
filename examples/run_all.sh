#!/usr/bin/env bash
# Run every example in examples/ with one Lua interpreter, from the
# repository root and with sh/ on the module path, and stop at the first
# one that fails.
#
# Usage: examples/run_all.sh [interpreter]   (default: lua)
#
# LUASH_BACKEND and LUASH_POPEN_STRATEGY pass through, so
# `LUASH_BACKEND=popen examples/run_all.sh luajit` runs them all on the
# popen backend under LuaJIT.
set -euo pipefail

interp="${1:-lua}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
# An unset LUA_PATH becomes ";;", which stands for the default path.
export LUA_PATH="./?/init.lua;./?.lua;${LUA_PATH:-;}"

for example in examples/*.lua; do
    printf '== %s\n' "$example"
    "$interp" "$example" < /dev/null
done
