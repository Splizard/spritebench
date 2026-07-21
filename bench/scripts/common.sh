#!/usr/bin/env bash
# Shared helpers for the per-language benchmark scripts. Sourced, not executed.

BENCH_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_ASSETS=${BENCH_ASSETS:-"$(cd "$BENCH_SCRIPTS_DIR/../assets" && pwd)"}
BENCH_RUN_TIMEOUT=${BENCH_RUN_TIMEOUT:-1800}
CACHE=${BENCH_CACHE:-/cache}
WEB_PORT=${WEB_PORT:-8060}

# Target platform for native runs. The container always benchmarks linux;
# run-macos.sh sets BENCH_PLATFORM=macos on the remote Mac. Native CSVs are
# tagged with the platform (except linux, for continuity with old results).
BENCH_PLATFORM=${BENCH_PLATFORM:-linux}
case $BENCH_PLATFORM in
    macos)
        NATIVE_PRESET=${NATIVE_PRESET:-macOS}
        BENCH_CSV_TAG=macos_
        ;;
    windows)
        NATIVE_PRESET=${NATIVE_PRESET:-Windows}
        BENCH_CSV_TAG=windows_
        ;;
    linux)
        NATIVE_PRESET=${NATIVE_PRESET:-Linux}
        BENCH_CSV_TAG=""
        ;;
    *)
        echo "common.sh: unknown BENCH_PLATFORM '$BENCH_PLATFORM'" >&2
        exit 1
        ;;
esac
# Small window: the web runs rasterize with SwiftShader (software), and a big
# canvas would drown the per-frame call overhead this benchmark measures.
BENCH_WEB_WINDOW=${BENCH_WEB_WINDOW:-640,360}

# godot_import <project_dir> [mono]
# One-shot resource import so exports have everything they need.
# Set GODOT_BIN to use a different editor binary (e.g. godot-next for Go).
godot_import() {
    local bin=${GODOT_BIN:-godot}
    [ "${2:-}" = mono ] && bin=godot-mono
    echo "-- importing $(basename "$1")"
    timeout 600 "$bin" --headless --path "$1" --import \
        >"$LOGS_DIR/import.$(basename "$1").log" 2>&1 || true
}

# godot_export <project_dir> <preset> <out_path> [mono]
godot_export() {
    local bin=${GODOT_BIN:-godot}
    [ "${4:-}" = mono ] && bin=godot-mono
    mkdir -p "$(dirname "$3")"
    # A failed export must not silently reuse the previous run's binary.
    # (-rf: on macOS the out path is a .app directory.)
    rm -rf "$3"
    echo "-- exporting $(basename "$1") preset '$2'"
    if ! timeout 1800 "$bin" --headless --path "$1" --export-release "$2" "$3" \
            >"$LOGS_DIR/export.$(basename "$(dirname "$3")").log" 2>&1; then
        echo "   export command failed (see logs)"
    fi
    if [ ! -e "$3" ]; then
        echo "   FAILED: export did not produce $3"
        return 1
    fi
    chmod +x "$3" 2>/dev/null || true
}

# godot_export_native <project_dir> <out_dir> [mono]
# Export the native preset for $BENCH_PLATFORM and set NATIVE_BIN to the
# runnable binary inside the result (macOS exports are .app bundles).
godot_export_native() {
    local proj=$1 outdir=$2 mono=${3:-}
    case $BENCH_PLATFORM in
        macos)
            godot_export "$proj" "$NATIVE_PRESET" "$outdir/spritebench.app" $mono || return 1
            NATIVE_BIN=$(find "$outdir/spritebench.app/Contents/MacOS" -type f 2>/dev/null | head -1)
            ;;
        windows)
            godot_export "$proj" "$NATIVE_PRESET" "$outdir/spritebench.exe" $mono || return 1
            NATIVE_BIN=$outdir/spritebench.exe
            ;;
        *)
            godot_export "$proj" "$NATIVE_PRESET" "$outdir/spritebench.x86_64" $mono || return 1
            NATIVE_BIN=$outdir/spritebench.x86_64
            ;;
    esac
    if [ -z "$NATIVE_BIN" ] || [ ! -e "$NATIVE_BIN" ]; then
        echo "   FAILED: no runnable binary found in $outdir"
        return 1
    fi
    chmod +x "$NATIVE_BIN" 2>/dev/null || true
}

# mark_unsupported <csv_prefix> <reason>
# User rule: a language that cannot run on this platform scores an explicit
# 0 fps (a single 0 frame-time row, rendered as a 0 bar by plot.py) instead
# of being silently omitted from the results.
mark_unsupported() {
    local csv=$RESULTS_DIR/${1}_${BENCH_CSV_TAG}sprites.csv
    echo 0 >"$csv"
    echo "-- $1: unsupported on $BENCH_PLATFORM ($2) -> scored 0 fps"
}

# mark_unsupported_web <csv_prefix> <reason>: same rule for the web panel,
# which has its own CSV tag regardless of the build platform.
mark_unsupported_web() {
    local csv=$RESULTS_DIR/${1}_html5_sprites.csv
    echo 0 >"$csv"
    echo "-- $1: unsupported on web ($2) -> scored 0 fps"
}

# wait_for_output <pid> <file> [log]: wait until <file> is non-empty, the
# process dies, or the timeout expires; then tear the process down. If a log
# is given, abort as soon as it shows the extension failed to load (the game
# would otherwise idle with a placeholder scene until the timeout).
wait_for_output() {
    local pid=$1 file=$2 log=${3:-} waited=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ -s "$file" ]; then
            sleep 2 # grace period so the process finishes writing/quitting
            break
        fi
        if [ -n "$log" ] && grep -qE 'Cannot load a GDExtension|placeholder will be created' "$log" 2>/dev/null; then
            echo "   extension failed to load; aborting run (see $log)"
            break
        fi
        if [ "$waited" -ge "$BENCH_RUN_TIMEOUT" ]; then
            echo "   timeout after ${BENCH_RUN_TIMEOUT}s"
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done
    kill "$pid" 2>/dev/null
    sleep 1
    kill -9 "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
}

# run_native <binary> <csv_prefix> <label>
# Runs an exported binary headless; the game writes SPRITEBENCH_OUTPUT and
# quits (or gets killed once the file appears, for implementations that keep
# running).
run_native() {
    local bin=$1 csv=$RESULTS_DIR/${2}_${BENCH_CSV_TAG}sprites.csv label=$3
    local log=$LOGS_DIR/run.$label.native.log
    rm -f "$csv"
    echo "-- running $label (native headless, $BENCH_PLATFORM)"
    # exec so $! is the game's actual PID, not a wrapper's.
    (cd "$(dirname "$bin")" && SPRITEBENCH_OUTPUT="$csv" exec "$bin" --headless >"$log" 2>&1) &
    wait_for_output $! "$csv" "$log"
    if [ -s "$csv" ]; then
        echo "   ok: $(cat "$csv" | head -1) -> $(basename "$csv")"
    else
        echo "   FAILED: no output produced (see $log)"
        return 1
    fi
}

# run_web <export_dir> <html_file> <csv_prefix> <label>
# Serves a web export locally and loads it in headless Chromium; frame times
# are printed to the JS console between markers and scraped from the log.
run_web() {
    local dir=$1 html=$2 csv=$RESULTS_DIR/${3}_html5_sprites.csv label=$4
    local log=$LOGS_DIR/run.$label.web.log
    # Remove stale outputs so a dead browser can't satisfy the marker check
    # with a previous run's log.
    rm -f "$csv" "$log"
    echo "-- running $label (web, headless chromium)"

    # Run the engine with the render loop disabled: otherwise SwiftShader
    # rasterizing 20k sprites (~130ms/frame) dominates every language equally
    # and the numbers only measure the software renderer. --disable-render-loop
    # keeps DisplayServerWeb (whose requestAnimationFrame callback is what
    # pumps Main::iteration on the web platform; a true --headless boots but
    # never ticks a frame) while skipping all drawing, matching what the
    # native --headless runs measure. Patch a copy of the export to inject the
    # flag into GODOT_CONFIG args.
    local patched
    patched=$(mktemp -d)
    cp -a "$dir/." "$patched/"
    sed -i 's/"args":\[\]/"args":["--disable-render-loop"]/' "$patched/$html"
    if ! grep -q '"args":\["--disable-render-loop"\]' "$patched/$html"; then
        echo "   WARNING: could not inject --disable-render-loop into $html; running with rendering"
    fi

    python3 "$BENCH_ASSETS/serve.py" --dir "$patched" --port "$WEB_PORT" &
    local server_pid=$!
    sleep 1

    chrome-headless-shell \
        --no-sandbox --disable-dev-shm-usage --user-data-dir="$(mktemp -d)" \
        --enable-unsafe-swiftshader --disable-gpu-vsync --disable-frame-rate-limit \
        --run-all-compositor-stages-before-draw \
        --enable-features=SharedArrayBuffer \
        --enable-logging=stderr --v=0 --window-size="$BENCH_WEB_WINDOW" \
        "http://127.0.0.1:$WEB_PORT/$html" >"$log" 2>&1 &
    local chrome_pid=$!

    local waited=0
    while kill -0 "$chrome_pid" 2>/dev/null; do
        if grep -q SPRITEBENCH_RESULTS_END "$log" 2>/dev/null; then
            break
        fi
        if grep -qE 'Cannot load a GDExtension|placeholder will be created|LinkError|CompileError' "$log" 2>/dev/null; then
            echo "   extension failed to load; aborting run (see $log)"
            break
        fi
        if [ "$waited" -ge "$BENCH_RUN_TIMEOUT" ]; then
            echo "   timeout after ${BENCH_RUN_TIMEOUT}s"
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done
    kill "$chrome_pid" 2>/dev/null
    sleep 1
    kill -9 "$chrome_pid" 2>/dev/null
    kill "$server_pid" 2>/dev/null
    wait "$chrome_pid" 2>/dev/null
    wait "$server_pid" 2>/dev/null
    rm -rf "$patched"

    if python3 "$BENCH_ASSETS/extract_web_results.py" "$log" "$csv"; then
        echo "   ok: $(cat "$csv" | head -1) -> $(basename "$csv")"
    else
        echo "   FAILED: no web results captured (see $log)"
        return 1
    fi
}

# android_abi_override <project_dir>
# Benchmarks target arm64 phones; BENCH_ANDROID_ABI=x86_64 retargets the
# (work-copy) preset so the pipeline can be smoke-tested on x86_64
# emulators like Waydroid. Only meaningful for gdscript; the native-code
# languages would need x86_64-android library builds too.
android_abi_override() {
    [ -n "${BENCH_ANDROID_ABI:-}" ] && [ "$BENCH_ANDROID_ABI" != arm64 ] || return 0
    echo "-- retargeting android preset to $BENCH_ANDROID_ABI"
    sed -i "s|architectures/arm64-v8a=true|architectures/arm64-v8a=false|; s|architectures/$BENCH_ANDROID_ABI=false|architectures/$BENCH_ANDROID_ABI=true|" \
        "$1/export_presets.cfg"
}

# stage_apk <csv_label> <apk_path>
# The container only builds APKs; run-android.sh (on the host, where adb and
# the device live) installs and runs everything staged here.
stage_apk() {
    mkdir -p "$RESULTS_DIR/apks"
    cp "$2" "$RESULTS_DIR/apks/$1.apk"
    echo "   staged $1.apk for run-android.sh"
}

# NDK toolchain for android cross-builds (cpp uses scons's own NDK support).
ndk_cc() {
    echo "${ANDROID_NDK_ROOT:?}/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android24-clang"
}

# mode_enabled <mode>: check against BENCH_MODES
mode_enabled() {
    case " $BENCH_MODES " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}
