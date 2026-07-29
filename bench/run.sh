#!/usr/bin/env bash
# Build the benchmark container image and run the full automated benchmark.
# Results (CSVs, logs, SVG plot) land in bench/results/<timestamp>/.
set -euo pipefail
cd "$(dirname "$0")"

ENGINE=${CONTAINER_ENGINE:-podman}
IMAGE=${IMAGE:-localhost/spritebench}
LANGS=""
MODES=""
REPEATS=""
GRAPHICS_GD=""
GO_FORK=""
NO_BUILD=0
TIMEOUT=""
DETACH=0
RUN_NAME=""

usage() {
    cat <<'EOF'
usage: run.sh [options]

  --langs "gdscript cpp rust go cs swift odin"   subset of languages to run
  --modes "headless web"                         native headless and/or web (chromium)
  --graphics-gd <path>                           benchmark a local graphics.gd checkout
  --go <path>                                    GOROOT of an alternative Go toolchain for the
                                                 go leg (e.g. the compiler.gd fork)
  --repeats <n>                                  run the whole set n times, interleaved, so
                                                 the plot can show the spread (default 1)
  --timeout <seconds>                            per-run timeout (default 1800)
  --no-build                                     skip rebuilding the image
  --name <run-name>                              write into results/<run-name>/ instead of a
                                                 fresh timestamped dir (reuse to merge results
                                                 from multiple partial runs)
  --detach                                       run in the background
                                                 (follow with: podman logs -f spritebench-run)
EOF
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --langs)       LANGS=$2; shift 2 ;;
        --modes)       MODES=$2; shift 2 ;;
        --graphics-gd) GRAPHICS_GD=$2; shift 2 ;;
        --go)          GO_FORK=$2; shift 2 ;;
        --repeats)     REPEATS=$2; shift 2 ;;
        --timeout)     TIMEOUT=$2; shift 2 ;;
        --no-build)    NO_BUILD=1; shift ;;
        --name)        RUN_NAME=$2; shift 2 ;;
        --detach)      DETACH=1; shift ;;
        -h|--help)     usage ;;
        *) echo "unknown option: $1"; usage ;;
    esac
done

if [ "$NO_BUILD" = 0 ]; then
    "$ENGINE" build -t "$IMAGE" -f Containerfile .
fi

mkdir -p results

args=(run --rm)
if [ "$DETACH" = 1 ]; then
    args+=(-d --name spritebench-run --replace)
fi
args+=(
    -v "$(cd .. && pwd)":/repo:ro
    -v "$(pwd)/results":/results
    -v spritebench-cache:/cache
    -v spritebench-work:/work
    # The image bakes in a copy of these (see Containerfile), which means
    # --no-build would otherwise run the image's versions and silently ignore
    # any local edit to the driver or the plot. They live beside this script
    # and are versioned with it, so the working copy is the authoritative one.
    -v "$(pwd)/scripts":/opt/bench/scripts:ro
    -v "$(pwd)/assets":/opt/bench/assets:ro)

# The musl leg needs a graphics.gd toolchain (zig 0.15.2 + the libgodot.musl
# static lib + runtime overlays) that the offline container can't download.
# If the host has a provisioned one at ~/gd, mount it at the SAME path (so the
# overlay config's absolute references resolve) and point the build's GDPATH
# at it. Override with GD_HOME.
GD_HOME=${GD_HOME:-$HOME/gd}
if [ -f "$GD_HOME/lib/libgodot.musl.amd64.a" ] && [ -x "$GD_HOME/bin/zig" ]; then
    args+=(-v "$GD_HOME":"$GD_HOME" -e "GD_MUSL_GDPATH=$GD_HOME")
fi

[ -n "$LANGS" ]   && args+=(-e "BENCH_LANGS=$LANGS")
[ -n "$MODES" ]   && args+=(-e "BENCH_MODES=$MODES")
[ -n "$TIMEOUT" ] && args+=(-e "BENCH_RUN_TIMEOUT=$TIMEOUT")
[ -n "$REPEATS" ] && args+=(-e "BENCH_REPEATS=$REPEATS")
[ -n "${BENCH_ANDROID_ABI:-}" ] && args+=(-e "BENCH_ANDROID_ABI=$BENCH_ANDROID_ABI")
[ -n "$RUN_NAME" ] && args+=(-e "BENCH_RUN_NAME=$RUN_NAME")
[ -n "${SPRITEBENCH_START:-}" ] && args+=(-e "SPRITEBENCH_START=$SPRITEBENCH_START")
# Comparing languages means running them on one engine; the Go legs pin
# godot-next themselves, so this is how the others are brought alongside.
[ -n "${GODOT_BIN:-}" ] && args+=(-e "GODOT_BIN=$GODOT_BIN")
[ -n "${SPRITEBENCH_HOLD:-}" ] && args+=(-e "SPRITEBENCH_HOLD=$SPRITEBENCH_HOLD")
[ -n "${GD_NO_FASTCB:-}" ] && args+=(-e "GD_NO_FASTCB=$GD_NO_FASTCB")
[ -n "${GD_NO_FASTENTRY:-}" ] && args+=(-e "GD_NO_FASTENTRY=$GD_NO_FASTENTRY")
[ -n "${SPRITEBENCH_PROFILE:-}" ] && args+=(-e "SPRITEBENCH_PROFILE=$SPRITEBENCH_PROFILE")
[ -n "${SPRITEBENCH_TRACE:-}" ] && args+=(-e "SPRITEBENCH_TRACE=$SPRITEBENCH_TRACE")
if [ -n "$GRAPHICS_GD" ]; then
    args+=(-v "$(realpath "$GRAPHICS_GD")":/graphics.gd:ro -e GRAPHICS_GD_DIR=/graphics.gd)
fi
if [ -n "$GO_FORK" ]; then
    args+=(-v "$(realpath "$GO_FORK")":/opt/gofork:ro -e GO_FORK_DIR=/opt/gofork)
fi

exec "$ENGINE" "${args[@]}" "$IMAGE"
