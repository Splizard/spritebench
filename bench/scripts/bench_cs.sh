#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

proj=$WORK/spritebench_cs
rc=0

godot_import "$proj" mono

if mode_enabled headless; then
    godot_export_native "$proj" "$WORK/build/cs" mono
    if [ "$BENCH_PLATFORM" = macos ]; then
        # macOS AMFI insta-SIGKILLs the mono export's hardened-runtime
        # ad-hoc signature (the plain exports are fine); re-sign plain
        # ad-hoc; it is a local benchmark binary, not a distributed app.
        codesign -f -s - --deep "$WORK/build/cs/spritebench.app" 2>/dev/null
    fi
    run_native "$NATIVE_BIN" cs cs || rc=1
fi

if mode_enabled android; then
    android_abi_override "$proj"
    apk=$WORK/build/cs-android/spritebench.apk
    godot_export "$proj" Android "$apk" mono && stage_apk cs "$apk" || rc=1
fi

if mode_enabled web; then
    mark_unsupported_web cs "Godot does not support C# web exports"
fi

exit $rc
