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
# Repeating the whole set is how the run carries its own error bars. The
# repeat is around the language loop rather than inside each language, so the
# passes interleave: a machine that drifts over the half hour a full set takes
# then moves every language together instead of penalising whichever happened
# to run late. The per-run spread turns out to be the dominant uncertainty in
# this benchmark (larger than most of the differences between languages), so a
# single pass is a point estimate with no way to tell how much to trust it.
export BENCH_REPEATS=${BENCH_REPEATS:-1}

mkdir -p "$WORK" "$RESULTS_DIR" "$LOGS_DIR" "${BENCH_CACHE:-/cache}"

echo "== SpriteBench automated run =="
echo "   platform:  ${BENCH_PLATFORM:-linux}"
echo "   languages: $BENCH_LANGS"
echo "   modes:     $BENCH_MODES"
echo "   repeats:   $BENCH_REPEATS"
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

# Build everything before measuring anything. Each bench script compiles its
# language and then immediately benchmarks it, so the first pass measured
# every language on a machine that had just finished compiling it -- parallel
# compile jobs heat the CPU and evict the caches the run is about to want.
# The effect is large and one-sided: excluding the build pass took Go from
# 19.9% spread to 1.2% and the panel mean from 17.6% to 12.9%. Later passes
# never showed it because the builds were already cached, which is exactly
# what makes it easy to mistake for a first-run quirk of the benchmark.
#
# The build sweep runs the same scripts with the measurement stubbed out
# (see run_native in common.sh), so builds stay incremental afterwards and
# every measurement pass starts from a fully built, quiescent tree.
if [ "${BENCH_SKIP_PREBUILD:-}" != 1 ]; then
    echo
    echo "######## building all languages ########"
    for lang in $BENCH_LANGS; do
        script=$SCRIPT_DIR/bench_${lang}.sh
        [ -f "$script" ] || continue
        echo
        echo "==== $lang (build) ===="
        BENCH_BUILD_ONLY=1 bash "$script" || STATUS[$lang]="FAILED (build)"
    done
    # Let the machine settle before the first measurement: a build sweep this
    # large leaves the CPU hot, and the first pass is the one that pays.
    echo
    echo "-- settling for ${BENCH_SETTLE:-30}s after builds"
    sleep "${BENCH_SETTLE:-30}"
fi

for pass in $(seq 1 "$BENCH_REPEATS"); do
    export BENCH_PASS=$pass
    if [ "$BENCH_REPEATS" -gt 1 ]; then
        echo
        echo "######## pass $pass/$BENCH_REPEATS ########"
    fi
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
            # A pass that fails after an earlier one succeeded is worth seeing,
            # so a failure is never overwritten by a later ok.
            case "${STATUS[$lang]:-}" in
                FAILED*) ;;
                *) STATUS[$lang]="ok ($((SECONDS - start))s)" ;;
            esac
        else
            STATUS[$lang]="FAILED ($((SECONDS - start))s)"
        fi
    done
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
