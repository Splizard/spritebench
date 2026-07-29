#!/usr/bin/env bash
# Run the benchmark on an Android device, single command:
#
#   ./bench/run-android.sh
#
# Builds debug-signed arm64 APKs inside the benchmark container (gdscript,
# cpp, rust ×2, go, cs, odin), then installs and runs each one on the
# adb-connected device, scraping frame times from logcat (the implementations
# print them between SPRITEBENCH_RESULTS markers on mobile). Languages with no
# Android support (swift, musl) score an explicit 0 fps. The APKs bake in
# --disable-render-loop so the numbers measure per-frame binding overhead,
# not the phone's GPU.
set -euo pipefail
cd "$(dirname "$0")"

SERIAL=${ANDROID_SERIAL:-}
LANGS="gdscript cpp rust go cs odin"
RUN_NAME=""
NO_BUILD=""
TIMEOUT=${BENCH_RUN_TIMEOUT:-900}
COOLDOWN=30
REPEATS=1
GRAPHICS_GD=""

usage() {
    cat <<'EOF'
usage: run-android.sh [options]

  --serial <adb-serial>       device to run on (default: the only one attached)
  --langs "gdscript cpp"      subset of android-capable languages
                              (gdscript cpp rust go cs odin)
  --name <run-name>           results dir name (default <timestamp>-android);
                              reuse a name to merge results across platforms
  --timeout <seconds>         per-run timeout on the device (default 900)
  --cooldown <seconds>        pause between runs to limit thermal throttling
                              carry-over (default 30)
  --repeats <n>               run the whole set n times, interleaved, so the
                              plot can show the spread (default 1)
  --graphics-gd <path>        benchmark a local graphics.gd checkout (go leg)
  --no-build                  reuse the existing container image
EOF
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --serial)   SERIAL=$2; shift 2 ;;
        --langs)    LANGS=$2; shift 2 ;;
        --name)     RUN_NAME=$2; shift 2 ;;
        --timeout)  TIMEOUT=$2; shift 2 ;;
        --cooldown) COOLDOWN=$2; shift 2 ;;
        --repeats)  REPEATS=$2; shift 2 ;;
        --graphics-gd) GRAPHICS_GD=$2; shift 2 ;;
        --no-build) NO_BUILD="--no-build"; shift ;;
        -h|--help)  usage ;;
    esac
done

RUN_NAME=${RUN_NAME:-$(date +%Y%m%d-%H%M%S)-android}
adb=(adb)
[ -n "$SERIAL" ] && adb=(adb -s "$SERIAL")

state=$("${adb[@]}" get-state 2>&1) || {
    echo "no usable adb device (${state}); plug one in or pass --serial" >&2
    exit 1
}

pkg_for() {
    case "$1" in
        gds)                       echo com.spritebench.gdscript ;;
        cpp)                       echo com.spritebench.cpp ;;
        rustbalanced|rustdisengaged) echo com.spritebench.rust ;;
        cs)                        echo com.spritebench.cs ;;
        odin)                      echo com.spritebench.odin ;;
        graphicsgd)                echo com.example.spritebench_graphicsgd ;;
        *)                         echo "unknown apk label: $1" >&2; return 1 ;;
    esac
}

echo "== building APKs in the container =="
build_args=(--langs "$LANGS" --modes android --name "$RUN_NAME")
[ -n "$GRAPHICS_GD" ] && build_args+=(--graphics-gd "$GRAPHICS_GD")
./run.sh "${build_args[@]}" $NO_BUILD || true

RESULTS=results/$RUN_NAME
mkdir -p "$RESULTS/logs"
if ! compgen -G "$RESULTS/apks/*.apk" >/dev/null; then
    echo "no APKs were produced; see the container output above" >&2
    exit 1
fi

echo "== device: $("${adb[@]}" shell getprop ro.product.model | tr -d '\r') =="
"${adb[@]}" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
"${adb[@]}" shell svc power stayon true >/dev/null 2>&1 || true

# --langs limits the device runs as well as the builds: stale APKs from
# earlier runs into the same results dir must not re-run (and overwrite
# CSVs) when only a subset was requested.
lang_of() {
    case "$1" in
        gds) echo gdscript ;;
        cpp) echo cpp ;;
        rustbalanced|rustdisengaged) echo rust ;;
        cs) echo cs ;;
        odin) echo odin ;;
        graphicsgd) echo go ;;
    esac
}

rc=0
first=1
# The repeat wraps the APK loop rather than sitting inside it, so the passes
# interleave. Measured one language at a time, a phone that heats up over the
# run would load all of that drift onto whichever ran last; rotating spreads
# it across every language instead. The cooldown between runs still applies.
apks=("$RESULTS"/apks/*.apk)
napks=${#apks[@]}
for pass in $(seq 1 "$REPEATS"); do
if [ "$REPEATS" -gt 1 ]; then echo "######## pass $pass/$REPEATS ########"; fi
# Rotate which language goes first each pass. The phone warms up over a pass
# and the run order is otherwise alphabetical, so a fixed order hands whichever
# runs first a cool device every time -- worth 22-35% here, enough to put cpp
# above odin on this device when every desktop platform has it the other way.
# Rotating spreads the cool slot around instead of compounding the same bias.
for i in $(seq 0 $((napks - 1))); do
    apk=${apks[$(( (i + pass - 1) % napks ))]}
    label=$(basename "$apk" .apk)
    case " $LANGS " in
        *" $(lang_of "$label") "*) ;;
        *) continue ;;
    esac
    pkg=$(pkg_for "$label") || { rc=1; continue; }
    csv=$RESULTS/${label}_android_sprites.csv
    log=$RESULTS/logs/run.$label.android.log
    # One row per pass; the first truncates so a re-run replaces its old
    # result, later ones append.
    if [ "$pass" -gt 1 ]; then
        log=$RESULTS/logs/run.$label.android.pass$pass.log
    else
        rm -f "$csv"
    fi

    [ "$first" = 1 ] || { echo "-- cooldown ${COOLDOWN}s"; sleep "$COOLDOWN"; }
    first=0

    echo "-- running $label on device"
    "${adb[@]}" install -r -g "$apk" >/dev/null || { echo "   FAILED: install"; rc=1; continue; }
    "${adb[@]}" logcat -c || true
    # Resolve the exported launcher activity (GodotAppLauncher on Godot 4.6;
    # the name varies across versions) and start it directly. Godot's main
    # activity itself is not exported, and monkey is broken on emulators
    # without input devices.
    component=$("${adb[@]}" shell cmd package resolve-activity --brief \
        -c android.intent.category.LAUNCHER "$pkg" 2>/dev/null | tr -d '\r' | tail -1)
    if [ -z "$component" ] || [ "${component#*/}" = "$component" ]; then
        echo "   FAILED: no launchable activity found for $pkg"; rc=1; continue
    fi
    "${adb[@]}" shell am start -a android.intent.action.MAIN \
        -c android.intent.category.LAUNCHER -n "$component" >/dev/null 2>&1 || true

    waited=0
    while :; do
        "${adb[@]}" logcat -d -s godot:* >"$log" 2>/dev/null
        grep -q SPRITEBENCH_RESULTS_END "$log" && break
        if ! "${adb[@]}" shell pidof "$pkg" >/dev/null 2>&1 \
                && [ "$waited" -gt 20 ]; then
            echo "   app exited without producing results (see $log)"
            break
        fi
        if [ "$waited" -ge "$TIMEOUT" ]; then
            echo "   timeout after ${TIMEOUT}s"
            break
        fi
        sleep 5
        waited=$((waited + 5))
    done

    "${adb[@]}" shell am force-stop "$pkg" >/dev/null 2>&1 || true
    "${adb[@]}" uninstall "$pkg" >/dev/null 2>&1 || true

    row=$RESULTS/.row.$$.csv
    if python3 ./assets/extract_logcat_results.py "$log" "$row"; then
        cat "$row" >>"$csv"
        rm -f "$row"
        echo "   ok: $(tail -1 "$csv") -> $(basename "$csv")"
    else
        echo "   FAILED: no results captured (see $log)"
        rc=1
    fi
done
done

"${adb[@]}" shell svc power stayon false >/dev/null 2>&1 || true

# User rule: languages that cannot run on this platform score an explicit
# 0 (sprites) instead of being omitted. (musl is exempt: it's a Linux-only
# variant of the Go entry, so it's absent rather than scored 0.)
for label in swift; do
    csv=$RESULTS/${label}_android_sprites.csv
    [ -f "$csv" ] || { echo 0 >"$csv"; echo "-- $label: unsupported on android -> scored 0 fps"; }
done

echo "== plotting =="
cp assets/plot.py "$RESULTS/plot.py"
if python3 -c 'import seaborn, pandas, matplotlib' 2>/dev/null; then
    (cd "$RESULTS" && MPLBACKEND=Agg python3 plot.py)
else
    echo "no plotting stack available locally; run plot.py in $RESULTS later"
fi

echo "results in: bench/$RESULTS"
exit $rc
