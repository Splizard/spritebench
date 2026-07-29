#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

proj=$WORK/spritebench_Odin
rc=0

# The pinned Toxin bindings declare three InputEvent engine callbacks as
# proc "fastcall", an x86-only calling convention that fails to compile for
# arm64 targets (macOS/Android/iOS). The convention is never actually relied
# on (the procs are Godot C function pointers), so patch it to "c" in the
# staged shared collection. Tmp-file dance: BSD sed (macOS) has no GNU -i.
odin_input=${ODIN_ROOT:-$(odin root)}/shared/Toxin/Input/InputEvent.odin
if [ -f "$odin_input" ] && grep -q '"fastcall"' "$odin_input"; then
    sed 's/proc "fastcall"/proc "c"/' "$odin_input" >"$odin_input.tmp" \
        && mv "$odin_input.tmp" "$odin_input"
fi

# The pinned Toxin declares godot_entry_init without the GDExtensionBool
# return the engine contract requires, so the engine reads leftover register
# state: Godot 4.6 happened to see nonzero, 4.7 sees false and refuses to
# load the extension. Upstream has since fixed it; patch the pinned copy.
odin_entry=${ODIN_ROOT:-$(odin root)}/shared/Toxin/main_entry.odin
if [ -f "$odin_entry" ] && ! grep -q 'Initialization) -> b8' "$odin_entry"; then
    sed -e 's/initialization: ^GDE.Initialization) {/initialization: ^GDE.Initialization) -> b8 {/' \
        -e 's/^    initialization.minimum_initialization_level = .INITIALIZATION_SCENE$/&\n    return true/' \
        "$odin_entry" >"$odin_entry.tmp" && mv "$odin_entry.tmp" "$odin_entry"
fi

case $BENCH_PLATFORM in
    macos)   odinlib=bin/libgdexample.dylib ;;
    windows) odinlib=bin/libgdexample.dll ;;
    *)       odinlib=bin/libgdexample.so ;;
esac
echo "-- building Odin extension"
mkdir -p "$proj/bin"
(cd "$proj" && odin build . -build-mode:shared -o:aggressive -out:"$odinlib") \
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

if mode_enabled android; then
    echo "-- building Odin extension (android arm64)"
    mkdir -p "$proj/bin/android"
    # Odin defaults to Android API 34, newer than the image's NDK r23 ships
    # sysroot libs for; pin the API level the NDK actually has (24, matching
    # the other languages' android builds).
    if (cd "$proj" && ODIN_ANDROID_NDK="${ANDROID_NDK_ROOT:?}" \
            odin build . -build-mode:shared -o:aggressive \
            -target:linux_arm64 -subtarget:android -minimum-os-version:24 \
            -out:bin/android/libgdexample.so) \
            >"$LOGS_DIR/build.odin-android.log" 2>&1; then
        apk=$WORK/build/odin-android/spritebench.apk
        godot_export "$proj" Android "$apk" && stage_apk odin "$apk" || rc=1
    else
        echo "   FAILED: android build (see $LOGS_DIR/build.odin-android.log)"
        rc=1
    fi
fi

if mode_enabled web; then
    mark_unsupported_web odin "the Odin bindings have no wasm target"
fi

exit $rc
