#!/usr/bin/env bash
# Run the benchmark on a macOS machine over ssh, single command:
#
#   ./bench/run-macos.sh
#
# Syncs the repo to the Mac, provisions toolchains on first run (homebrew,
# Godot editors + macOS export templates, rust, dotnet, odin bindings,
# godot-cpp), runs every implementation natively (headless), then pulls the
# frame-time CSVs back into bench/results/<run-name>/ and plots them.
# Languages that cannot run on macOS score an explicit 0 fps.
set -euo pipefail
cd "$(dirname "$0")"

# Machine-specific config (hosts, signing) lives in gitignored bench/.env.
[ -f .env ] && . ./.env

HOST=${SPRITEBENCH_MAC_HOST:-}
LANGS=""
TIMEOUT=""
RUN_NAME=""
GRAPHICS_GD=""
SETUP_ONLY=0
NO_SETUP=0

usage() {
    cat <<'EOF'
usage: run-macos.sh [options]

  --host <ssh-host>                              Mac to run on (default: SPRITEBENCH_MAC_HOST
                                                 from bench/.env, see .env.example)
  --langs "gdscript cpp rust go cs swift odin"   subset of languages to run
  --graphics-gd <path>                           benchmark a local graphics.gd checkout
  --timeout <seconds>                            per-run timeout (default 1800)
  --name <run-name>                              results dir name (default <timestamp>-macos);
                                                 reuse a name to merge results across platforms
  --setup-only                                   provision the Mac and exit
  --no-setup                                     skip the (idempotent) provisioning step
EOF
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --host)        HOST=$2; shift 2 ;;
        --langs)       LANGS=$2; shift 2 ;;
        --graphics-gd) GRAPHICS_GD=$2; shift 2 ;;
        --timeout)     TIMEOUT=$2; shift 2 ;;
        --name)        RUN_NAME=$2; shift 2 ;;
        --setup-only)  SETUP_ONLY=1; shift ;;
        --no-setup)    NO_SETUP=1; shift ;;
        -h|--help)     usage ;;
        *) echo "unknown option: $1"; usage ;;
    esac
done

[ -n "$HOST" ] || { echo "no Mac host configured: set SPRITEBENCH_MAC_HOST in bench/.env or pass --host"; exit 1; }
RUN_NAME=${RUN_NAME:-$(date +%Y%m%d-%H%M%S)-macos}

REMOTE_HOME=$(ssh -o BatchMode=yes "$HOST" 'echo $HOME')
ROOT=$REMOTE_HOME/spritebench-bench

# Sync with tar over ssh: works with nothing but ssh installed on either
# end (the linux host has no rsync). The synced tree is small once build
# artifacts are excluded, so a full copy per run is cheap.
echo "== syncing repo to $HOST:$ROOT/repo =="
tar -C .. -czf - \
    --exclude .git \
    --exclude .godot \
    --exclude bench/results \
    --exclude releases \
    --exclude build \
    --exclude __pycache__ \
    --exclude go.work \
    --exclude go.work.sum \
    --exclude 'musl_amd64.*' \
    --exclude spritebench_rust/rust/target \
    --exclude .build \
    --exclude profile.out \
    . | ssh -o BatchMode=yes "$HOST" \
        "rm -rf '$ROOT/repo' && mkdir -p '$ROOT/repo' && tar -xzf - -C '$ROOT/repo'"

remote_env=(
    "PATH=$ROOT/bin:$ROOT/dotnet:/opt/homebrew/opt/coreutils/libexec/gnubin:/opt/homebrew/opt/rustup/bin:/opt/homebrew/bin:$REMOTE_HOME/.cargo/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    "BENCH_PLATFORM=macos"
    "BENCH_MODES=headless"
    "BENCH_SKIP_PLOT=1"
    "REPO=$ROOT/repo"
    "WORK=$ROOT/work"
    "RESULTS_DIR=$ROOT/results/$RUN_NAME"
    "BENCH_CACHE=$ROOT/cache"
    "GODOT_CPP_CACHE=$ROOT/cache/godot-cpp"
    "ODIN_ROOT=$ROOT/odin-root"
    "DOTNET_ROOT=$ROOT/dotnet"
)
[ -n "$LANGS" ]   && remote_env+=("BENCH_LANGS=$LANGS")
[ -n "$TIMEOUT" ] && remote_env+=("BENCH_RUN_TIMEOUT=$TIMEOUT")
[ -n "${GD_NO_FASTCB:-}" ]    && remote_env+=("GD_NO_FASTCB=$GD_NO_FASTCB")
[ -n "${GD_NO_FASTENTRY:-}" ] && remote_env+=("GD_NO_FASTENTRY=$GD_NO_FASTENTRY")

if [ -n "$GRAPHICS_GD" ]; then
    echo "== syncing local graphics.gd checkout =="
    tar -C "$(realpath "$GRAPHICS_GD")" -czf - --exclude .git . \
        | ssh -o BatchMode=yes "$HOST" \
            "rm -rf '$ROOT/graphics.gd' && mkdir -p '$ROOT/graphics.gd' && tar -xzf - -C '$ROOT/graphics.gd'"
    remote_env+=("GRAPHICS_GD_DIR=$ROOT/graphics.gd")
fi

if [ "$NO_SETUP" = 0 ]; then
    echo "== provisioning (idempotent) =="
    ssh -o BatchMode=yes "$HOST" "bash '$ROOT/repo/bench/scripts/setup_macos.sh'"
fi
[ "$SETUP_ONLY" = 1 ] && exit 0

echo "== running benchmark on $HOST =="
rc=0
ssh -o BatchMode=yes "$HOST" \
    "env ${remote_env[*]@Q} /opt/homebrew/bin/bash '$ROOT/repo/bench/scripts/entrypoint.sh'" || rc=$?

echo "== pulling results =="
mkdir -p "results/$RUN_NAME"
ssh -o BatchMode=yes "$HOST" "tar -C '$ROOT/results/$RUN_NAME' -czf - ." \
    | tar -xzf - -C "results/$RUN_NAME"

echo "== plotting =="
if python3 -c 'import seaborn, pandas, matplotlib' 2>/dev/null; then
    (cd "results/$RUN_NAME" && MPLBACKEND=Agg python3 plot.py)
elif command -v podman >/dev/null 2>&1 && podman image exists localhost/spritebench 2>/dev/null; then
    podman run --rm -v "$(pwd)/results/$RUN_NAME":/plotdir --entrypoint bash \
        localhost/spritebench -c 'cd /plotdir && MPLBACKEND=Agg python3 plot.py'
else
    echo "no plotting stack available locally; run plot.py in results/$RUN_NAME later"
fi

echo "results in: bench/results/$RUN_NAME"
exit $rc
