#!/usr/bin/env bash
# Run the benchmark on a USB-connected iOS device via the Mac, single command:
#
#   ./bench/run-ios.sh
#
# The iOS toolchain lives on the Mac (Xcode), so this drives everything over
# ssh to the Mac the device is plugged into: sync the repo, build + sign +
# install + launch each implementation on the device, and pull the frame-time
# CSVs (written to the app sandbox, retrieved over AFC; iOS os_log redacts
# console output). Signing uses a dedicated keychain seeded once from the
# login keychain (see the iOS notes in bench/README.md).
#
# Languages with no iOS support score an explicit 0 fps.
set -euo pipefail
cd "$(dirname "$0")"

# Machine-specific config (hosts, signing) lives in gitignored bench/.env.
[ -f .env ] && . ./.env

HOST=${SPRITEBENCH_MAC_HOST:-}
LANGS=""
RUN_NAME=""
TIMEOUT=""
REPEATS=1

usage() {
    cat <<'EOF'
usage: run-ios.sh [options]

  --host <ssh-host>            Mac the device is plugged into (default:
                               SPRITEBENCH_MAC_HOST from bench/.env)
  --langs "gdscript cpp go"    subset of iOS-capable languages
  --name <run-name>            results dir name (default <timestamp>-ios);
                               reuse a name to merge results across platforms
  --repeats <n>                run the whole set n times, interleaved, so the
                               plot can show the spread (default 1)
  --timeout <seconds>          per-run device timeout (default 300)
  --graphics-gd <path>         benchmark a local graphics.gd checkout (go leg)

Device/signing config (env, usually via bench/.env; see .env.example):
  IOS_UDID, IOS_IDENTITY, IOS_PROFILE, IOS_TEAM, IOS_KEYCHAIN_PW
EOF
    exit 1
}

GRAPHICS_GD=""
while [ $# -gt 0 ]; do
    case "$1" in
        --host)        HOST=$2; shift 2 ;;
        --langs)       LANGS=$2; shift 2 ;;
        --name)        RUN_NAME=$2; shift 2 ;;
        --repeats)     REPEATS=$2; shift 2 ;;
        --timeout)     TIMEOUT=$2; shift 2 ;;
        --graphics-gd) GRAPHICS_GD=$2; shift 2 ;;
        -h|--help)     usage ;;
        *) echo "unknown option: $1"; usage ;;
    esac
done

[ -n "$HOST" ] || { echo "no Mac host configured: set SPRITEBENCH_MAC_HOST in bench/.env or pass --host"; exit 1; }
[ -n "${IOS_TEAM:-}" ] || { echo "no Apple team id configured: set IOS_TEAM in bench/.env"; exit 1; }
[ -n "${IOS_KEYCHAIN_PW:-}" ] || { echo "no keychain password configured: set IOS_KEYCHAIN_PW in bench/.env"; exit 1; }
RUN_NAME=${RUN_NAME:-$(date +%Y%m%d-%H%M%S)-ios}
ALL_LANGS="gdscript cpp rust rustdisengaged go cs odin"  # have iOS build recipes on the test device
# swift: SwiftGodot's prebuilt frameworks require iOS 17+ (Swift runtime is
# in-OS); the iOS test device is an iPhone 8 (iOS 16.7) where it can't load,
# so swift is unsupported here and scores 0.
# (musl is exempt from the 0 rule: it's a Linux-only variant of the Go entry,
# absent rather than scored 0.)
UNSUPPORTED="swift"
LANGS=${LANGS:-$ALL_LANGS}

# lang -> "csv_label bundle_id project_subdir" (preset defaults to iOS)
lang_spec() {
    case "$1" in
        gdscript) echo "gds com.spritebench.gdscript spritebench_gdscript" ;;
        cpp)      echo "cpp com.spritebench.cpp spritebench_cpp" ;;
        rust)     echo "rustbalanced com.spritebench.rust spritebench_rust/godot" ;;
        rustdisengaged) echo "rustdisengaged com.spritebench.rust spritebench_rust/godot" ;;
        swift)    echo "swift com.spritebench.swift spritebench_swift" ;;
        cs)       echo "cs com.spritebench.cs spritebench_cs" ;;
        odin)     echo "odin com.spritebench.odin spritebench_Odin" ;;
        go)       echo "graphicsgd com.example.spritebenchgraphicsgd spritebench_go/graphics" ;;
        *) return 1 ;;
    esac
}

SSH=(ssh -o BatchMode=yes "$HOST")
REMOTE_HOME=$("${SSH[@]}" 'echo $HOME')
ROOT=$REMOTE_HOME/spritebench-bench

echo "== syncing repo to $HOST =="
tar -C .. -czf - --exclude .git --exclude .godot --exclude bench/results \
    --exclude releases --exclude build --exclude __pycache__ --exclude go.work \
    --exclude go.work.sum --exclude 'musl_amd64.*' --exclude spritebench_rust/rust/target \
    --exclude .build --exclude profile.out . \
    | "${SSH[@]}" "rm -rf '$ROOT/repo' && mkdir -p '$ROOT/repo' && tar -xzf - -C '$ROOT/repo'"

# Benchmark a local graphics.gd checkout (Go leg) instead of the pinned
# release: sync it and pass GRAPHICS_GD_DIR so run_ios_remote.sh adds a
# go.mod replace before building the gd tool.
if [ -n "$GRAPHICS_GD" ]; then
    echo "== syncing local graphics.gd checkout =="
    tar -C "$(realpath "$GRAPHICS_GD")" -czf - --exclude .git . \
        | "${SSH[@]}" "rm -rf '$ROOT/graphics.gd' && mkdir -p '$ROOT/graphics.gd' && tar -xzf - -C '$ROOT/graphics.gd'"
fi

# Device UDID + signing identity, discovered on the Mac if not provided.
IOS_UDID=${IOS_UDID:-$("${SSH[@]}" 'export PATH=/opt/homebrew/bin:$PATH; idevice_id -l 2>/dev/null | head -1' | tr -d '\r')}
IOS_IDENTITY=${IOS_IDENTITY:-$("${SSH[@]}" 'security find-identity -v -p codesigning spritebench.keychain 2>/dev/null | grep -m1 "Apple Development" | grep -oE "[0-9A-F]{40}"' | tr -d '\r')}
IOS_PROFILE=${IOS_PROFILE:-$("${SSH[@]}" 'ls "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/"*.mobileprovision 2>/dev/null | head -1' | tr -d '\r')}
[ -n "$IOS_UDID" ]     || { echo "no iOS device connected to $HOST"; exit 1; }
[ -n "$IOS_IDENTITY" ] || { echo "no Apple Development identity in spritebench.keychain on $HOST"; exit 1; }
echo "   device $IOS_UDID, identity ${IOS_IDENTITY:0:10}…"

# Swift's prebuilt SwiftGodot frameworks need an iOS 17+ device, driven by
# devicectl (its identifier is a UUID; the iOS 16 ios-deploy device uses a
# hex UDID and typically doesn't show in devicectl). Discover the first
# available one.
# "available" also matches "unavailable", so exclude the latter explicitly.
IOS17_UDID=${IOS17_UDID:-$("${SSH[@]}" 'xcrun devicectl list devices 2>/dev/null | grep -viE "unavailable" | grep -iE "available|connected" | grep -oiE "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}" | head -1' | tr -d '\r')}
if [ -n "$IOS17_UDID" ]; then echo "   iOS 17+ device (swift): $IOS17_UDID"
elif echo " $LANGS " | grep -q ' swift '; then echo "   note: no iOS 17+ device found; swift will be skipped"; fi

remote_env="BENCH_RUN_NAME=$RUN_NAME IOS_UDID=$IOS_UDID IOS_IDENTITY=$IOS_IDENTITY IOS_PROFILE='$IOS_PROFILE'"
remote_env="$remote_env IOS_TEAM=$IOS_TEAM IOS_KEYCHAIN_PW=$IOS_KEYCHAIN_PW"
[ -n "$IOS17_UDID" ] && remote_env="$remote_env IOS17_UDID=$IOS17_UDID"
[ -n "$GRAPHICS_GD" ] && remote_env="$remote_env GRAPHICS_GD_DIR='$ROOT/graphics.gd'"
[ -n "$TIMEOUT" ]        && remote_env="$remote_env BENCH_RUN_TIMEOUT=$TIMEOUT"
[ -n "${GD_NO_FASTCB:-}" ]    && remote_env="$remote_env GD_NO_FASTCB=$GD_NO_FASTCB"
[ -n "${GD_NO_FASTENTRY:-}" ] && remote_env="$remote_env GD_NO_FASTENTRY=$GD_NO_FASTENTRY"
# GODOT_BIN selects the engine; the C# leg overrides it with godot-mono for
# itself, which is what it needs since only the 4.6 templates have a mono
# variant.
[ -n "${GODOT_BIN:-}" ]          && remote_env="$remote_env GODOT_BIN=$GODOT_BIN"

rc=0
# The repeat wraps the language loop rather than sitting inside it, so the
# passes interleave: a device that warms up over the run then moves every
# language together instead of penalising whichever installed last.
for pass in $(seq 1 "$REPEATS"); do
    [ "$REPEATS" -gt 1 ] && echo "######## pass $pass/$REPEATS ########"
    for lang in $LANGS; do
        spec=$(lang_spec "$lang") || { echo "!! no iOS spec for $lang, skipping"; continue; }
        echo "==== $lang ===="
        "${SSH[@]}" "env BENCH_PASS=$pass $remote_env bash '$ROOT/repo/bench/scripts/run_ios_remote.sh' $lang $spec" || rc=1
    done
done

echo "== pulling results =="
mkdir -p "results/$RUN_NAME"
"${SSH[@]}" "tar -C '$ROOT/results/$RUN_NAME' -czf - . 2>/dev/null" | tar -xzf - -C "results/$RUN_NAME" 2>/dev/null || true

# 0-sprites rule for languages iOS cannot run.
for lang in $UNSUPPORTED; do
    case "$lang" in
        rust) label=rustbalanced ;;
        cs) label=cs ;; swift) label=swift ;;
    esac
    csv="results/$RUN_NAME/${label}_ios_sprites.csv"
    [ -f "$csv" ] || { echo 0 >"$csv"; echo "-- $lang: unsupported on iOS -> scored 0 fps"; }
done

echo "== plotting =="
cp assets/plot.py "results/$RUN_NAME/plot.py" 2>/dev/null || true
if python3 -c 'import seaborn,pandas,matplotlib' 2>/dev/null; then
    (cd "results/$RUN_NAME" && MPLBACKEND=Agg python3 plot.py) || true
fi
echo "results in: bench/results/$RUN_NAME"
exit $rc
