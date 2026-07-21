#!/usr/bin/env bash
# Runs ON the Windows machine inside git-bash, invoked by run-windows.sh
# (via a generated .cmd launcher that sets BENCH_RUN_NAME/BENCH_LANGS).
# Resolves the provisioned toolchains into PATH and hands off to the shared
# entrypoint with BENCH_PLATFORM=windows.
set -uo pipefail

ROOT=$(cygpath -u "$USERPROFILE")/spritebench-bench

# Python + scons live wherever setup_windows.ps1 found the real python
# (the WindowsApps store stub shadows it on PATH).
pyexe=$(tr -d '\r' <"$ROOT/python-path.txt" 2>/dev/null || true)
pydir=""
[ -n "$pyexe" ] && pydir=$(cygpath -u "$(dirname "$pyexe")")

# Latest installed Swift toolchain, if any.
swiftbin=$(ls -d "$(cygpath -u "$LOCALAPPDATA")/Programs/Swift/Toolchains/"*/usr/bin 2>/dev/null | sort | tail -1)

# mingw gcc for cgo (the Go graphics.gd build). $ROOT is already a unix path.
mingw=""
[ -x "$ROOT/mingw64/bin/gcc.exe" ] && mingw="$ROOT/mingw64/bin"

export PATH="$ROOT/bin:$ROOT/odin${mingw:+:$mingw}${pydir:+:$pydir:$pydir/Scripts}${swiftbin:+:$swiftbin}:$HOME/.cargo/bin:$(cygpath -u "$LOCALAPPDATA")/Microsoft/WinGet/Links:$PATH"

export BENCH_PLATFORM=windows
export BENCH_MODES=headless
export BENCH_SKIP_PLOT=1
export REPO=$ROOT/repo
export WORK=$ROOT/work
export BENCH_CACHE=$ROOT/cache
export GODOT_CPP_CACHE=$ROOT/cache/godot-cpp
export RESULTS_DIR=$ROOT/results/${BENCH_RUN_NAME:?BENCH_RUN_NAME not set}

exec bash "$ROOT/repo/bench/scripts/entrypoint.sh"
