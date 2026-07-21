#!/usr/bin/env bash
# Benchmark driver: copy the (read-only) repo into a work tree, build +
# export + run every requested benchmark, then plot the results. Runs as the
# container entrypoint for linux/web, and over ssh for the other platforms
# (see run-macos.sh), which is why nothing here assumes container paths.
set -uo pipefail

if ((BASH_VERSINFO[0] < 4)); then
    echo "entrypoint.sh needs bash >= 4 (this is $BASH_VERSION; on macOS use homebrew bash)" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO=${REPO:-/repo}
WORK=${WORK:-/work}
RUN_NAME=${BENCH_RUN_NAME:-$(date +%Y%m%d-%H%M%S)}
export RESULTS_DIR=${RESULTS_DIR:-/results/$RUN_NAME}
export LOGS_DIR=$RESULTS_DIR/logs
export WORK
export BENCH_LANGS=${BENCH_LANGS:-gdscript cpp rust go musl cs swift odin}
export BENCH_MODES=${BENCH_MODES:-headless web}

mkdir -p "$WORK" "$RESULTS_DIR" "$LOGS_DIR" "${BENCH_CACHE:-/cache}"

echo "== SpriteBench automated run =="
echo "   platform:  ${BENCH_PLATFORM:-linux}"
echo "   languages: $BENCH_LANGS"
echo "   modes:     $BENCH_MODES"
echo "   results:   $RESULTS_DIR"
nproc_val=$(nproc)
echo "   cpus:      $nproc_val"

echo "-- syncing sources into work tree"
# Build outputs (build/, bin/, target/, .godot/, ...) are excluded so they are
# neither copied from the host nor deleted from the persistent work volume,
# which keeps rebuilds incremental across runs. git-bash on Windows has no
# rsync; fall back to a tar pipe (no --delete, which is acceptable there).
if ! command -v rsync >/dev/null 2>&1; then
    tar -C "$REPO" -cf - \
        --exclude .git --exclude .godot --exclude releases --exclude build \
        --exclude bin --exclude bench --exclude csv --exclude other \
        --exclude go.work --exclude go.work.sum --exclude 'musl_amd64.*' \
        --exclude spritebench_rust/rust/target --exclude .build \
        --exclude profile.out . | tar --overwrite -xf - -C "$WORK"
else
rsync -a --delete \
    --exclude .git \
    --exclude .godot \
    --exclude releases \
    --exclude build \
    --exclude bin \
    --exclude bench \
    --exclude csv \
    --exclude other \
    --exclude go.work \
    --exclude go.work.sum \
    --exclude 'musl_amd64.*' \
    --exclude 'spritebench_rust/rust/target' \
    --exclude '.build' \
    --exclude 'profile.out' \
    "$REPO/" "$WORK/"
fi

declare -A STATUS
overall_start=$SECONDS
for lang in $BENCH_LANGS; do
    script=$SCRIPT_DIR/bench_${lang}.sh
    if [ ! -f "$script" ]; then
        echo "!! unknown language: $lang (no $script)"
        STATUS[$lang]="unknown language"
        continue
    fi
    echo
    echo "==== $lang ===="
    start=$SECONDS
    if bash "$script"; then
        STATUS[$lang]="ok ($((SECONDS - start))s)"
    else
        STATUS[$lang]="FAILED ($((SECONDS - start))s)"
    fi
done

echo
echo "==== Generating plot ===="
if compgen -G "$RESULTS_DIR/*.csv" >/dev/null; then
    cp "$SCRIPT_DIR/../assets/plot.py" "$RESULTS_DIR/plot.py"
    if [ -n "${BENCH_SKIP_PLOT:-}" ]; then
        # e.g. on the Mac, which has no seaborn; run-macos.sh plots after
        # pulling the results back.
        echo "plotting skipped (BENCH_SKIP_PLOT set)"
    else
        (cd "$RESULTS_DIR" && python3 plot.py)
    fi
else
    echo "no CSVs produced; skipping plot"
fi

echo
echo "==== Summary ($((SECONDS - overall_start))s total) ===="
failed=0
for lang in $BENCH_LANGS; do
    printf '  %-10s %s\n' "$lang" "${STATUS[$lang]:-skipped}"
    case "${STATUS[$lang]:-}" in ok*) ;; *) failed=1 ;; esac
done
echo "  results in: $RESULTS_DIR"
exit $failed
