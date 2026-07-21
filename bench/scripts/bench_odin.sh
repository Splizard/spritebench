#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

proj=$WORK/spritebench_Odin
rc=0

# The Toxin bindings declare engine callbacks as proc "fastcall", an
# x86-only calling convention, so they cannot compile for arm64 targets.
if [ "$BENCH_PLATFORM" = macos ]; then
    mode_enabled headless && mark_unsupported odin "Toxin bindings use x86-only 'fastcall', no arm64 support"
    exit 0
fi

case $BENCH_PLATFORM in
    macos)   odinlib=bin/libgdexample.dylib ;;
    windows) odinlib=bin/libgdexample.dll ;;
    *)       odinlib=bin/libgdexample.so ;;
esac
echo "-- building Odin extension"
mkdir -p "$proj/bin"
(cd "$proj" && odin build . -build-mode:dll -o:speed -out:"$odinlib") \
    >"$LOGS_DIR/build.odin.log" 2>&1

# The Odin project ships without an export preset; provide one.
[ -f "$proj/export_presets.cfg" ] || cp "$BENCH_ASSETS/odin_export_presets.cfg" "$proj/export_presets.cfg"

godot_import "$proj"

if mode_enabled headless; then
    godot_export_native "$proj" "$WORK/build/odin"
    # The Odin implementation writes the CSV but keeps running; run_native
    # kills it once the output file appears.
    run_native "$NATIVE_BIN" odin odin || rc=1
fi

if mode_enabled web; then
    mark_unsupported_web odin "the Odin bindings have no wasm target"
fi

exit $rc
