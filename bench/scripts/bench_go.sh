#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

proj=$WORK/spritebench_go
rc=0
export GOWORK=off
export CGO_ENABLED=1
# graphics.gd tracks upstream Godot; use the newer editor for this benchmark,
# including for the `gd` tool's own PATH lookup of "godot".
export GODOT_BIN=godot-next
[ -d /opt/godot-next-path ] && export PATH=/opt/godot-next-path:$PATH
[ -n "${GODOT_NEXT_PATH_DIR:-}" ] && export PATH=$GODOT_NEXT_PATH_DIR:$PATH
export GOBIN=$CACHE/gobin

# Benchmark an alternative Go toolchain (e.g. the compiler.gd fork) by
# mounting its GOROOT and setting GO_FORK_DIR (see run.sh --go). The fork
# reports GOVERSION "gd1.26.x", which (a) fails go.mod's `go >= 1.26.1`
# directive check — it parses as language version 1.26 — so the directives in
# the work copies are relaxed, and (b) fails gd's "go1.26" prefix check for
# the fastcb overlay, so gd builds the fork's own (stock-layout-incompatible)
# runtime unpatched, which is what we want.
if [ -n "${GO_FORK_DIR:-}" ] && [ -d "$GO_FORK_DIR" ]; then
    echo "-- using Go toolchain fork: $("$GO_FORK_DIR/bin/go" version)"
    export PATH=$GO_FORK_DIR/bin:$PATH
    export GOTOOLCHAIN=local
    sed -i 's/^go 1\.26\.[0-9][0-9]*$/go 1.26/' "$proj/go.mod"
    if [ -n "${GRAPHICS_GD_DIR:-}" ] && [ -d "$GRAPHICS_GD_DIR" ]; then
        rsync -a --delete --exclude .git "$GRAPHICS_GD_DIR/" "$WORK/graphics.gd-fork/"
        sed -i 's/^go 1\.26\.[0-9][0-9]*$/go 1.26/' "$WORK/graphics.gd-fork/go.mod"
        GRAPHICS_GD_DIR=$WORK/graphics.gd-fork
    fi
fi

# The fastcb runtime overlay cannot apply to a toolchain the go command
# auto-downloads into the module cache (go refuses -overlay replacements
# there) — which is what happens when the PATH go is older than go.mod's
# directive. If a real sdk toolchain (golang.org/dl shim layout) matching
# gd's go1.26 requirement is installed, select it directly.
if [ -z "${GO_FORK_DIR:-}" ] && [ -z "${GOTOOLCHAIN:-}" ]; then
    # `|| true`: an empty glob makes ls exit non-zero, which under
    # `set -o pipefail` would abort the script (the 2>/dev/null hides why).
    sdkgo=$(ls -d "$HOME"/sdk/go1.26*/bin 2>/dev/null | sort -V | tail -1 || true)
    if [ -n "$sdkgo" ] && [ -x "$sdkgo/go" ]; then
        echo "-- using $("$sdkgo/go" version) from $sdkgo"
        export PATH=$sdkgo:$PATH
        export GOTOOLCHAIN=local
    fi
fi

# All builds go through the `gd` tool (NOT plain `go build`) so gd's build
# machinery applies (notably the fastcb resident-callback runtime overlay,
# which is what real users of `gd build` get). Benchmark a local graphics.gd
# checkout by mounting it and setting GRAPHICS_GD_DIR (see run.sh
# --graphics-gd); the gd tool is then built from the checkout's OWN module (it
# carries the complete go.sum for the tool's deps; a filesystem replace in
# spritebench_go only covers the runtime deps it imports).
if [ -n "${GRAPHICS_GD_DIR:-}" ] && [ -d "$GRAPHICS_GD_DIR" ]; then
    echo "-- using local graphics.gd from $GRAPHICS_GD_DIR"
    (cd "$proj" && go mod edit -replace "graphics.gd=$GRAPHICS_GD_DIR" && go mod tidy) \
        >"$LOGS_DIR/build.go-tidy.log" 2>&1
    (cd "$GRAPHICS_GD_DIR" && GOBIN=$GOBIN go install ./cmd/gd) \
        >>"$LOGS_DIR/build.go-tidy.log" 2>&1
else
    # The repo's go.sum is maintained against a go.work workspace, so resolve
    # modules fresh in the work copy; gd comes from the go.mod-pinned version.
    echo "-- resolving go modules + gd tool"
    (cd "$proj" && go mod tidy && go get graphics.gd/cmd/gd && go install graphics.gd/cmd/gd) \
        >"$LOGS_DIR/build.go-tidy.log" 2>&1
fi

if mode_enabled headless; then
    case $BENCH_PLATFORM in
        macos)   rel=releases/darwin/universal/spritebench_graphicsgd.app ;;
        windows) rel=releases/windows/amd64/spritebench_graphicsgd.exe ;;
        *)       rel=releases/linux/amd64/spritebench_graphicsgd ;;
    esac
    echo "-- building graphics.gd release (gd build, $BENCH_PLATFORM)"
    rm -rf "$proj/$rel"
    if (cd "$proj" && timeout 1800 "$GOBIN/gd" build) >"$LOGS_DIR/build.go.log" 2>&1 \
            && [ -e "$proj/$rel" ]; then
        # gd falls back to a stock runtime with only a buried warning when the
        # installed Go doesn't match go.mod (auto-downloaded toolchains can't
        # take overlays); surface it so the number isn't silently un-fastcb'd.
        # Not meaningful on the fork: gd correctly skips the stock overlay
        # there, and the fork's runtime carries fastcb natively.
        [ -z "${GO_FORK_DIR:-}" ] && grep -q "without the resident-callback" "$LOGS_DIR/build.go.log" && \
            echo "   WARNING: fastcb runtime patch NOT applied (install a Go toolchain matching go.mod)"
        if [ "$BENCH_PLATFORM" = macos ]; then
            NATIVE_BIN=$(find "$proj/$rel/Contents/MacOS" -type f | head -1)
        else
            NATIVE_BIN=$proj/$rel
        fi
        chmod +x "$NATIVE_BIN" 2>/dev/null || true
        run_native "$NATIVE_BIN" graphicsgd go || rc=1
    else
        echo "   FAILED: gd build (see $LOGS_DIR/build.go.log)"
        rc=1
    fi
fi

if mode_enabled android; then
    # `gd build` for android wants adb + apksigner (it deploys); the device
    # lives on the host, so build only the LIBRARY with gd (no args +
    # RUNNING_INSIDE_GODOT short-circuits before it launches the editor;
    # fastcb overlay still applies) and export the APK with the bench's own
    # godot flow. gd's android path cross-compiles with zig from GDPATH.
    echo "-- building graphics.gd extension (android arm64, gd)"
    # gd resolves godot and zig under GDPATH/bin. The host-mounted ~/gd
    # carries a MUSL-linked godot editor the (glibc) container can't exec
    # ("fork/exec: no such file" = missing musl loader), so assemble a
    # container-local GDPATH: the container's godot-next plus the mounted
    # zig/libs (zig resolves its own lib dir through the symlink).
    gdp=$CACHE/gd-android
    mkdir -p "$gdp/bin" "$gdp/lib"
    ln -sf "$(command -v godot)" "$gdp/bin/godot"
    if [ -n "${GD_MUSL_GDPATH:-}" ] && [ -d "$GD_MUSL_GDPATH" ]; then
        for f in "$GD_MUSL_GDPATH"/bin/zig*; do [ -e "$f" ] && ln -sf "$f" "$gdp/bin/"; done
        for f in "$GD_MUSL_GDPATH"/lib/*; do [ -e "$f" ] && ln -sf "$f" "$gdp/lib/"; done
    fi
    if (cd "$proj" && RUNNING_INSIDE_GODOT=1 GOOS=android GOARCH=arm64 \
            GDPATH=$gdp timeout 1800 "$GOBIN/gd") \
            >"$LOGS_DIR/build.go-android.log" 2>&1 \
            && [ -f "$proj/graphics/libandroid_arm64.so" ]; then
        grep -q "without the resident-callback" "$LOGS_DIR/build.go-android.log" && \
            echo "   WARNING: fastcb runtime patch NOT applied (install a Go toolchain matching go.mod)"
    else
        echo "   gd android build failed; falling back to NDK go build (no fastcb)"
        echo "   (see $LOGS_DIR/build.go-android.log)"
        if ! (cd "$proj" && CC="$(ndk_cc)" GOOS=android GOARCH=arm64 CGO_ENABLED=1 \
                go build -buildmode=c-shared -o graphics/libandroid_arm64.so .) \
                >>"$LOGS_DIR/build.go-android.log" 2>&1; then
            echo "   FAILED: android build (see $LOGS_DIR/build.go-android.log)"
            rc=1
        fi
    fi
    if [ -f "$proj/graphics/libandroid_arm64.so" ]; then
        cp "$BENCH_ASSETS/go-library.gdextension" "$proj/graphics/library.gdextension"
        godot_import "$proj/graphics"
        apk=$WORK/build/go-android/spritebench.apk
        godot_export "$proj/graphics" Android "$apk" && stage_apk graphicsgd "$apk" || rc=1
    fi
fi

if mode_enabled web; then
    # gd manages the wasm glue and web template itself.
    echo "-- building graphics.gd web export (gd build)"
    webdir=$proj/releases/js/wasm
    mkdir -p "$webdir"
    if (cd "$proj" && CGO_ENABLED=0 GOOS=js GOARCH=wasm timeout 1800 "$GOBIN/gd" build) \
            >"$LOGS_DIR/build.go-web.log" 2>&1 \
            && [ -f "$webdir/index.html" ]; then
        run_web "$webdir" index.html graphicsgd go || rc=1
    else
        echo "   FAILED: web build (see $LOGS_DIR/build.go-web.log)"
        rc=1
    fi
fi

exit $rc
