#!/usr/bin/env bash
# Run the benchmark on a Windows machine over ssh, single command:
#
#   ./bench/run-windows.sh
#
# Syncs the repo to the Windows box, provisions toolchains on first run
# (winget/bootstrappers via an elevated scheduled task: MSVC Build Tools,
# rust, dotnet, python+scons, swift, odin, Godot editors + templates), runs
# every implementation natively (headless) through the shared bench scripts
# under git-bash, then pulls the CSVs back into bench/results/<run-name>/
# and plots them. Requires passwordless ssh to an admin account.
set -euo pipefail
cd "$(dirname "$0")"

# Machine-specific config (hosts, signing) lives in gitignored bench/.env.
[ -f .env ] && . ./.env

HOST=${SPRITEBENCH_WIN_HOST:-}
LANGS=""
TIMEOUT=""
REPEATS=""
RUN_NAME=""
GRAPHICS_GD=""
SETUP_ONLY=0
NO_SETUP=0

usage() {
    cat <<'EOF'
usage: run-windows.sh [options]

  --host <ssh-host>                              Windows machine (default: SPRITEBENCH_WIN_HOST
                                                 from bench/.env, see .env.example)
  --langs "gdscript cpp rust go cs swift odin"   subset of languages to run
  --graphics-gd <path>                           benchmark a local graphics.gd checkout
  --repeats <n>                                  run the whole set n times, interleaved, so
                                                 the plot can show the spread (default 1)
  --timeout <seconds>                            per-run timeout (default 1800)
  --name <run-name>                              results dir name (default <timestamp>-windows);
                                                 reuse a name to merge results across platforms
  --setup-only                                   provision the machine and exit
  --no-setup                                     skip the (idempotent) provisioning step
EOF
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --host)       HOST=$2; shift 2 ;;
        --langs)      LANGS=$2; shift 2 ;;
        --graphics-gd) GRAPHICS_GD=$2; shift 2 ;;
        --repeats)    REPEATS=$2; shift 2 ;;
        --timeout)    TIMEOUT=$2; shift 2 ;;
        --name)       RUN_NAME=$2; shift 2 ;;
        --setup-only) SETUP_ONLY=1; shift ;;
        --no-setup)   NO_SETUP=1; shift ;;
        -h|--help)    usage ;;
        *) echo "unknown option: $1"; usage ;;
    esac
done

[ -n "$HOST" ] || { echo "no Windows host configured: set SPRITEBENCH_WIN_HOST in bench/.env or pass --host"; exit 1; }
RUN_NAME=${RUN_NAME:-$(date +%Y%m%d-%H%M%S)-windows}
SSH=(ssh -o BatchMode=yes "$HOST")

# The remote user profile dir, from the Windows side.
PROFILE=$("${SSH[@]}" 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r')
ROOT_WIN="$PROFILE\\spritebench-bench"

echo "== syncing repo to $HOST =="
"${SSH[@]}" "if not exist \"$ROOT_WIN\\repo\" mkdir \"$ROOT_WIN\\repo\"" 2>/dev/null || true
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
    . | "${SSH[@]}" "cd /d \"$ROOT_WIN\" && (if exist repo rmdir /s /q repo) && mkdir repo && tar -xzf - -C repo"

if [ -n "$GRAPHICS_GD" ]; then
    echo "== syncing local graphics.gd checkout =="
    tar -C "$(realpath "$GRAPHICS_GD")" -czf - --exclude .git . \
        | "${SSH[@]}" "cd /d \"$ROOT_WIN\" && (if exist graphics.gd rmdir /s /q graphics.gd) && mkdir graphics.gd && tar -xzf - -C graphics.gd"
fi

if [ "$NO_SETUP" = 0 ]; then
    echo "== provisioning (idempotent, runs as an elevated scheduled task) =="
    # Delete the previous setup.log first: otherwise the wait below sees the
    # last run's "setup complete" and returns before the new setup even runs.
    "${SSH[@]}" "del /q \"$ROOT_WIN\\setup.log\" 2>nul & copy /y \"$ROOT_WIN\\repo\\bench\\scripts\\setup_windows.ps1\" \"$ROOT_WIN\\setup_windows.ps1\" >nul && schtasks /Create /TN spritebench-setup /TR \"$ROOT_WIN\\setup-task.cmd\" /SC ONCE /ST 23:59 /RL HIGHEST /F >nul && schtasks /Run /TN spritebench-setup" 2>/dev/null || true
    # setup-task.cmd is created on first use; generate it if missing.
    printf 'powershell -NoProfile -ExecutionPolicy Bypass -File "%%USERPROFILE%%\\spritebench-bench\\setup_windows.ps1" > "%%USERPROFILE%%\\spritebench-bench\\setup.log" 2>&1\r\n' \
        | "${SSH[@]}" "cd /d \"$ROOT_WIN\" && (if not exist setup-task.cmd more > setup-task.cmd)" 2>/dev/null || true
    echo "   waiting for setup to complete (first run can take an hour)"
    while :; do
        out=$("${SSH[@]}" "type \"$ROOT_WIN\\setup.log\" 2>nul" 2>/dev/null | tr -d '\r' | tail -1)
        case "$out" in *"setup complete"*) echo "   $out"; break ;; esac
        sleep 60
    done
fi
[ "$SETUP_ONLY" = 1 ] && exit 0

echo "== launching benchmark on $HOST =="
{
    printf 'set BENCH_RUN_NAME=%s\r\n' "$RUN_NAME"
    [ -n "$LANGS" ]   && printf 'set BENCH_LANGS=%s\r\n' "$LANGS"
    [ -n "$TIMEOUT" ] && printf 'set BENCH_RUN_TIMEOUT=%s\r\n' "$TIMEOUT"
    [ -n "$REPEATS" ] && printf 'set BENCH_REPEATS=%s\r\n' "$REPEATS"
    # The engine has to match whatever the other platforms ran, or the numbers
    # pulled back cannot be put beside them: 4.6 and 4.7 differ on this
    # workload by more than most of the languages differ from each other.
    [ -n "${GODOT_BIN:-}" ]          && printf 'set GODOT_BIN=%s\r\n' "$GODOT_BIN"
    [ -n "${GD_NO_FASTCB:-}" ]    && printf 'set GD_NO_FASTCB=%s\r\n' "$GD_NO_FASTCB"
    [ -n "${GD_NO_FASTENTRY:-}" ] && printf 'set GD_NO_FASTENTRY=%s\r\n' "$GD_NO_FASTENTRY"
    # Forward slashes so git-bash and the go toolchain both accept the path.
    [ -n "$GRAPHICS_GD" ] && printf 'set GRAPHICS_GD_DIR=%%USERPROFILE:\\=/%%/spritebench-bench/graphics.gd\r\n'
    printf '"C:\\Program Files\\Git\\bin\\bash.exe" "%%USERPROFILE%%\\spritebench-bench\\repo\\bench\\scripts\\run_windows_remote.sh"\r\n'
} | "${SSH[@]}" "cd /d \"$ROOT_WIN\" && more > bench-run.cmd" 2>/dev/null

rc=0
"${SSH[@]}" "cmd /c \"$ROOT_WIN\\bench-run.cmd\"" || rc=$?

echo "== pulling results =="
mkdir -p "results/$RUN_NAME"
# Fetched one file at a time rather than as a tar stream. Tarring the results
# directory wedged indefinitely twice, leaving a five-hour sweep one hang away
# from being lost, and it still wedges with the logs excluded -- tar over this
# host's ssh is simply not dependable. `type` per file is slower but each
# transfer is bounded, a hang costs one result instead of all of them, and a
# failure is reported rather than silently producing a short directory.
#
# Logs stay on the Windows host; they are diagnostics, they are large, and
# they are what made the bulk transfer worth avoiding. Read them there.
csvs=$("${SSH[@]}" "dir /b \"$ROOT_WIN\\results\\$RUN_NAME\\*.csv\"" </dev/null 2>/dev/null | tr -d '\r')
if [ -z "$csvs" ]; then
    echo "!! no CSVs found on $HOST in $ROOT_WIN\\results\\$RUN_NAME"
else
    pulled=0 missed=0
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        # </dev/null: ssh would otherwise swallow the here-string feeding this
        # loop, stopping after the first file while reporting success.
        for attempt in 1 2; do
            timeout 120 "${SSH[@]}" "type \"$ROOT_WIN\\results\\$RUN_NAME\\$f\"" </dev/null 2>/dev/null \
                | tr -d '\r' | grep -v '^$' >"results/$RUN_NAME/$f"
            [ -s "results/$RUN_NAME/$f" ] && break
        done
        if [ -s "results/$RUN_NAME/$f" ]; then
            pulled=$((pulled + 1))
        else
            echo "!! failed to pull $f (still on $HOST)"
            rm -f "results/$RUN_NAME/$f"
            missed=$((missed + 1))
        fi
    done <<<"$csvs"
    echo "   pulled $pulled result file(s)${missed:+, $missed missing}"
fi

echo "== plotting =="
cp assets/plot.py "results/$RUN_NAME/plot.py" 2>/dev/null || true
if python3 -c 'import seaborn, pandas, matplotlib' 2>/dev/null; then
    (cd "results/$RUN_NAME" && MPLBACKEND=Agg python3 plot.py)
else
    echo "no plotting stack available locally; run plot.py in results/$RUN_NAME later"
fi

echo "results in: bench/results/$RUN_NAME"
exit $rc
