#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

# graphics.gd "musl" mode: the Go code is built as a -tags musl c-archive and
# linked (zig, static) with a libgodot static library into one self-contained
# executable; the engine main loop is entered FROM Go, unlike the c-shared
# GDExtension entry where Godot's (foreign) thread calls into Go. Same Godot
# 4.7 line as the regular go entry.
proj=$WORK/spritebench_go
rc=0

# musl static linking is Linux-only; it is not scored 0 elsewhere (the way
# unsupported languages are) but absent; it is a Linux-specific
# variant of the Go entry, not a language a platform failed to run.
if [ "$BENCH_PLATFORM" != linux ]; then
    echo "-- musl entry is linux-only, skipping"
    exit 0
fi

export GOWORK=off
export CGO_ENABLED=1
# The musl build overlays patched runtime files onto GOROOT; a toolchain
# auto-downloaded into GOMODCACHE cannot be overlaid, so force the local
# toolchain (the container's Go must be >= go.mod's `go` directive).
export GOTOOLCHAIN=local
export GODOT_BIN=godot-next
export PATH=/opt/godot-next-path:$PATH
# gd needs zig + libgodot.musl.amd64.a under GDPATH. The offline container
# can't download them, so run.sh mounts the host's provisioned ~/gd and points
# GD_MUSL_GDPATH at it; fall back to the cache dir otherwise.
export GDPATH=${GD_MUSL_GDPATH:-/cache/gdpath}
export GOBIN=/cache/gobin

if ! mode_enabled headless; then
    echo "-- musl entry only has a native headless variant, skipping"
    exit 0
fi

# Benchmark a local graphics.gd checkout instead of the pinned release by
# mounting it and setting GRAPHICS_GD_DIR (see run.sh --graphics-gd). The gd
# tool is built from the checkout's OWN module (complete go.sum for its deps).
if [ -n "${GRAPHICS_GD_DIR:-}" ] && [ -d "$GRAPHICS_GD_DIR" ]; then
    echo "-- using local graphics.gd from $GRAPHICS_GD_DIR"
    (cd "$proj" && go mod edit -replace "graphics.gd=$GRAPHICS_GD_DIR" && go mod tidy) \
        >"$LOGS_DIR/build.musl-tidy.log" 2>&1
    (cd "$GRAPHICS_GD_DIR" && GOBIN=$GOBIN go install ./cmd/gd) \
        >>"$LOGS_DIR/build.musl-tidy.log" 2>&1
else
    # The repo's go.sum is maintained against a go.work workspace, so resolve
    # modules fresh in the work copy; gd comes from the go.mod-pinned version.
    echo "-- resolving go modules + gd tool"
    (cd "$proj" && go mod tidy && go get graphics.gd/cmd/gd && go install graphics.gd/cmd/gd) \
        >"$LOGS_DIR/build.musl-tidy.log" 2>&1
fi

# Import the project once with the regular c-shared extension present so the
# .godot import cache is built with the extension classes loaded; the musl
# export itself removes/ignores .gdextension files (everything is linked in).
echo "-- importing project (c-shared extension present)"
(cd "$proj" && go build -buildmode=c-shared -o graphics/linux_amd64.so .) \
    >"$LOGS_DIR/build.musl-import.log" 2>&1
cp "$BENCH_ASSETS/go-library.gdextension" "$proj/graphics/library.gdextension"
godot_import "$proj/graphics"

echo "-- building musl static binary (GOOS=musl gd build)"
out=$proj/releases/musl/amd64/spritebench_graphicsgd
rm -f "$out"
if (cd "$proj" && GOOS=musl timeout 1800 "$GOBIN/gd" build) \
        >"$LOGS_DIR/build.musl.log" 2>&1 && [ -f "$out" ]; then
    run_native "$out" graphicsgdmusl musl || rc=1
else
    echo "   FAILED: musl export (see $LOGS_DIR/build.musl.log)"
    rc=1
fi

exit $rc
