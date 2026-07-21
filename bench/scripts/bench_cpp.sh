#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

proj=$WORK/spritebench_cpp
rc=0

echo "-- syncing godot-cpp submodule from cache"
# git-bash on Windows has no rsync; fall back to a tar pipe.
gdcpp=${GODOT_CPP_CACHE:-/opt/cache/godot-cpp}
if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete "$gdcpp/" "$proj/godot-cpp/"
else
    rm -rf "$proj/godot-cpp"; mkdir -p "$proj/godot-cpp"
    tar -C "$gdcpp" -cf - . | tar -xf - -C "$proj/godot-cpp"
fi

case $BENCH_PLATFORM in
    macos)   scons_args=(platform=macos arch=arm64) ;;
    windows) scons_args=(platform=windows arch=x86_64) ;;
    *)       scons_args=(platform=linux arch=x86_64) ;;
esac
echo "-- building godot-cpp extension ($BENCH_PLATFORM release)"
(cd "$proj" && scons target=template_release "${scons_args[@]}" -j"$(nproc)") \
    >"$LOGS_DIR/build.cpp.log" 2>&1

godot_import "$proj"

if mode_enabled headless; then
    godot_export_native "$proj" "$WORK/build/cpp"
    run_native "$NATIVE_BIN" cpp cpp || rc=1
fi

if mode_enabled android; then
    echo "-- building godot-cpp extension (android arm64 release)"
    # godot-cpp defaults to its own pinned NDK version under ANDROID_HOME
    # (ignoring ANDROID_NDK_ROOT when ANDROID_HOME is set); point it at the
    # image's NDK explicitly.
    ndk_version=$(basename "${ANDROID_NDK_ROOT:-}")
    if (cd "$proj" && scons target=template_release platform=android arch=arm64 \
            ${ndk_version:+ndk_version="$ndk_version"} -j"$(nproc)") \
            >"$LOGS_DIR/build.cpp-android.log" 2>&1; then
        apk=$WORK/build/cpp-android/spritebench.apk
        godot_export "$proj" Android "$apk" && stage_apk cpp "$apk" || rc=1
    else
        echo "   FAILED: android build (see $LOGS_DIR/build.cpp-android.log)"
        rc=1
    fi
fi

if mode_enabled web; then
    echo "-- building godot-cpp extension (web release)"
    if (cd "$proj" && set +u && source /opt/emsdk/emsdk_env.sh >/dev/null 2>&1 \
            && scons target=template_release platform=web -j"$(nproc)") \
            >"$LOGS_DIR/build.cpp-web.log" 2>&1; then
        webdir=$WORK/build/cpp-web
        godot_export "$proj" Web "$webdir/index.html"
        run_web "$webdir" index.html cpp cpp || rc=1
    else
        echo "   FAILED: web build (see $LOGS_DIR/build.cpp-web.log)"
        rc=1
    fi
fi

exit $rc
