#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

proj=$WORK/spritebench_gdscript
rc=0

godot_import "$proj"

if mode_enabled headless; then
    godot_export_native "$proj" "$WORK/build/gds"
    run_native "$NATIVE_BIN" gds gds || rc=1
fi

if mode_enabled web; then
    webdir=$WORK/build/gds-web
    godot_export "$proj" Web "$webdir/index.html"
    run_web "$webdir" index.html gds gds || rc=1
fi

if mode_enabled android; then
    android_abi_override "$proj"
    apk=$WORK/build/gds-android/spritebench.apk
    godot_export "$proj" Android "$apk" && stage_apk gds "$apk" || rc=1
fi

exit $rc
