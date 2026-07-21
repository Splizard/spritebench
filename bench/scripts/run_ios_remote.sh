#!/bin/bash
# Build, sign, deploy and run one implementation on a USB-connected iOS
# device, then pull the frame-time CSV out of the app sandbox. Runs ON the
# Mac, invoked by run-ios.sh. iOS os_log redacts dynamic strings as
# <private>, so the app writes results to user:// (its Documents container)
# and we retrieve them over AFC instead of scraping the console.
#
#   run_ios_remote.sh <lang> <csv_label> <bundle_id> <project_subdir> <preset>
set -uo pipefail
export PATH=/opt/homebrew/opt/coreutils/libexec/gnubin:/opt/homebrew/bin:$PATH
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

LANG=$1 LABEL=$2 BUNDLE=$3 SUBDIR=$4 PRESET=${5:-iOS}
ROOT=$HOME/spritebench-bench
PROJ=$ROOT/repo/$SUBDIR
OUT=$ROOT/results/${BENCH_RUN_NAME:?}
mkdir -p "$OUT/logs"
CSV=$OUT/${LABEL}_ios_sprites.csv
LOG=$OUT/logs/$LANG.ios.log
: >"$LOG"

# Signing config, passed through from run-ios.sh (sourced from bench/.env).
UDID=${IOS_UDID:?IOS_UDID not set}
IDENTITY=${IOS_IDENTITY:?IOS_IDENTITY not set}
PROFILE=${IOS_PROFILE:?IOS_PROFILE not set}
TEAM=${IOS_TEAM:?IOS_TEAM not set}
KEYCHAIN=${IOS_KEYCHAIN:-spritebench.keychain}
KEYCHAIN_PW=${IOS_KEYCHAIN_PW:?IOS_KEYCHAIN_PW not set}

fail() { echo "   FAILED: $1"; exit 1; }

security unlock-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN" 2>>"$LOG"

# The tracked export presets carry no Apple team id; stamp IOS_TEAM into the
# synced work copy before anything exports (BSD sed).
find "$ROOT/repo" -name export_presets.cfg -print0 | \
    xargs -0 sed -i '' "s/app_store_team_id=\"[^\"]*\"/app_store_team_id=\"$TEAM\"/" 2>>"$LOG"

echo "-- [$LANG] language-specific iOS build"
case $LANG in
    gdscript) : ;;  # pure GDScript, no native extension
    go)
        export GOWORK=off
        # graphics.gd tracks upstream Godot; make `godot` resolve to 4.7 for
        # the gd tool's export step.
        mkdir -p "$ROOT/go-godot-shim"; ln -sf "$ROOT/bin/godot-next" "$ROOT/go-godot-shim/godot"
        export PATH="$ROOT/go-godot-shim:$ROOT/bin:$PATH"
        export GOBIN=$ROOT/cache/gobin
        # Xcode 26's compilation cache fails with CacheCheckFailed inside the
        # `godot --export-release iOS` xcodebuild step; disable it.
        export COMPILATION_CACHE_ENABLE_CACHING=NO CLANG_ENABLE_COMPILE_CACHE=NO
        # Xcode 26's `strip` aborts on Go's object format inside libgo.a
        # ("string table not at the end of the file"), failing Godot's iOS
        # export (which archives via xcodebuild, stripping installed products
        # by default). xcodebuild applies XCODE_XCCONFIG_FILE globally, so use
        # it to turn stripping off (graphics.gd re-links the binary itself).
        printf 'STRIP_INSTALLED_PRODUCT = NO\nCOPY_PHASE_STRIP = NO\n' >"$OUT/nostrip.xcconfig"
        export XCODE_XCCONFIG_FILE="$OUT/nostrip.xcconfig"
        if [ -n "${GRAPHICS_GD_DIR:-}" ] && [ -d "$GRAPHICS_GD_DIR" ]; then
            echo "-- [go] using local graphics.gd from $GRAPHICS_GD_DIR"
            # Build the gd tool from graphics.gd's OWN module: it carries the
            # complete go.sum for the tool's deps (progressbar, lipo, ...). A
            # filesystem replace in spritebench_go only covers the RUNTIME deps
            # it imports, so `go install graphics.gd/cmd/gd` from here would
            # miss the tool's own go.sum entries. Rewrite spritebench_go's
            # go.mod so `gd build` still compiles against the local runtime.
            ( cd "$GRAPHICS_GD_DIR" && GOBIN=$GOBIN go install ./cmd/gd ) >>"$LOG" 2>&1 \
                || fail "go install local gd (see $LOG)"
            ( cd "$PROJ/.." && go mod edit -replace "graphics.gd=$GRAPHICS_GD_DIR" && go mod tidy ) \
                >>"$LOG" 2>&1 || fail "go mod replace graphics.gd (see $LOG)"
            ( cd "$PROJ" && GOOS=ios GOARCH=arm64 "$GOBIN/gd" build ) >>"$LOG" 2>&1 \
                || fail "gd ios build (see $LOG)"
        else
            ( cd "$PROJ" && go get graphics.gd/cmd/gd && go install graphics.gd/cmd/gd \
                && GOOS=ios GOARCH=arm64 "$GOBIN/gd" build ) >>"$LOG" 2>&1 \
                || fail "gd ios build (see $LOG)"
        fi
        ;;
    cpp)
        rsync -a --delete "$ROOT/cache/godot-cpp/" "$PROJ/godot-cpp/" >>"$LOG" 2>&1
        # The macOS editor loads the extension for ITS OWN platform to
        # enumerate classes when opening/exporting the project, so the macOS
        # lib must exist too (a missing dylib crashes the editor), so build
        # both the host (macos) and target (ios) libraries.
        ( cd "$PROJ" && scons target=template_release platform=macos arch=arm64 -j"$(sysctl -n hw.ncpu)" \
            && scons target=template_release platform=ios arch=arm64 -j"$(sysctl -n hw.ncpu)" ) \
            >>"$LOG" 2>&1 || fail "godot-cpp ios build (see $LOG)"
        ;;
    rust|rustdisengaged)
        # Homebrew's rustup puts neither cargo nor rustc on PATH; add the
        # installed toolchain's bin directly so cargo can find rustc.
        rustup default stable >>"$LOG" 2>&1 || true
        tcbin=$(ls -d "$HOME"/.rustup/toolchains/stable-*/bin 2>/dev/null | head -1)
        export PATH="${tcbin:+$tcbin:}$HOME/.cargo/bin:$PATH"
        # Same crate, two variants: "disengaged" turns gdext's runtime
        # safety checks off (see bench_rust.sh). Plain string, not an array:
        # macOS bash 3.2 + set -u aborts on expanding an empty array.
        feat=""
        [ "$LANG" = rustdisengaged ] && feat="--features disengaged"
        # gdext cdylib for the device (aarch64-apple-ios) plus the host
        # (macos) lib the editor loads to enumerate classes at export time.
        ( cd "$PROJ/../rust" && rustup target add aarch64-apple-ios >>"$LOG" 2>&1
          cargo build --release $feat >>"$LOG" 2>&1 \
          && cargo build --release --target aarch64-apple-ios $feat >>"$LOG" 2>&1 ) \
            || fail "cargo ios build (see $LOG)"
        # The editor loads the macos DEBUG variant (res://../rust/target/debug)
        # when it opens the project to enumerate classes; satisfy it with the
        # release lib (a missing dylib crashes the editor).
        mkdir -p "$PROJ/../rust/target/debug" "$PROJ/bin/ios"
        cp "$PROJ/../rust/target/release/librust.dylib" "$PROJ/../rust/target/debug/librust.dylib"
        cp "$PROJ/../rust/target/aarch64-apple-ios/release/librust.dylib" "$PROJ/bin/ios/librust.dylib"
        ;;
    cs)
        # No separate native build: godot-mono's iOS export runs `dotnet
        # publish` itself. Put the .NET SDK on PATH for the editor and
        # switch the export below to the mono editor.
        export DOTNET_ROOT=$ROOT/dotnet
        export PATH="$ROOT/dotnet:$PATH"
        export GODOT_BIN=godot-mono
        ;;
    odin)
        # Brew odin + the bindings staged by setup_macos.sh. Same fastcall
        # arm64 patch bench_odin.sh applies: the pinned Toxin bindings declare
        # three InputEvent callbacks with the x86-only "fastcall" convention.
        export ODIN_ROOT=$ROOT/odin-root
        odin_input=$ODIN_ROOT/shared/Toxin/Input/InputEvent.odin
        if [ -f "$odin_input" ] && grep -q '"fastcall"' "$odin_input"; then
            sed 's/proc "fastcall"/proc "c"/' "$odin_input" >"$odin_input.tmp" \
                && mv "$odin_input.tmp" "$odin_input"
        fi
        # The project ships no export presets; stage the benchmark's, and
        # stamp the team id (the global stamping pass above already ran).
        if [ ! -f "$PROJ/export_presets.cfg" ]; then
            cp "$ROOT/repo/bench/assets/odin_export_presets.cfg" "$PROJ/export_presets.cfg"
            sed -i '' "s/app_store_team_id=\"[^\"]*\"/app_store_team_id=\"$TEAM\"/" "$PROJ/export_presets.cfg"
        fi
        # Host (macos) lib for the exporting editor to load, plus the device
        # (ios) lib; odin resolves the iPhone SDK via xcrun itself.
        mkdir -p "$PROJ/bin/ios"
        ( cd "$PROJ" && odin build . -build-mode:shared -o:aggressive -out:bin/libgdexample.dylib \
            && odin build . -build-mode:shared -o:aggressive \
                -target:darwin_arm64 -subtarget:iphone -out:bin/ios/libgdexample.dylib ) \
            >>"$LOG" 2>&1 || fail "odin ios build (see $LOG)"
        ;;
    swift)
        # SwiftGodot's source build can't cross-compile to iOS (its
        # code-generator build-tool plugin's host-only deps fail for iOS, and
        # xcodebuild rejects its unsafeFlags). build_swift_ios.sh consumes the
        # PREBUILT SwiftGodot xcframeworks + a host-built macro plugin instead,
        # staging libSpriteBenchSwift.dylib + the two .frameworks into the
        # addons bin for both macos (editor) and ios (device).
        bash "$SCRIPT_DIR/build_swift_ios.sh" >>"$LOG" 2>&1 || fail "swift ios build (see $LOG)"
        ;;
    *) fail "no iOS build recipe for $LANG" ;;
esac

BIN=${GODOT_BIN:-godot}
[ -d "$ROOT/bin" ] && BIN=$ROOT/bin/$BIN

if [ "$LANG" = go ]; then
    # graphics.gd's ld64.lld path (Godot now only scaffolds the xcodeproj/.pck,
    # export_project_only=true, no xcodebuild) writes an UNSIGNED .ipa under the
    # Go MODULE root's releases (spritebench_go/releases), one level above the
    # graphics/ project dir ($PROJ); basename is the AppleSafePackageName
    # (underscores stripped). Extract its .app so it goes through the normal
    # sign → zip → install path below, and read the real bundle id from it (the
    # Go project's gd.graphics.* id differs from lang_spec's placeholder).
    ipa=$(find "$PROJ/../releases/ios/arm64" "$PROJ/releases/ios/arm64" \
        -maxdepth 1 -name '*.ipa' 2>/dev/null | head -1)
    [ -n "$ipa" ] && [ -f "$ipa" ] || fail "gd build produced no .ipa (see $LOG)"
    rm -rf "$OUT/xc-$LANG"; mkdir -p "$OUT/xc-$LANG"
    ( cd "$OUT/xc-$LANG" && unzip -q "$ipa" ) >>"$LOG" 2>&1
    app=$(find "$OUT/xc-$LANG/Payload" -maxdepth 1 -name '*.app' 2>/dev/null | head -1)
    [ -n "$app" ] && [ -d "$app" ] || fail "no .app inside $(basename "$ipa") (see $LOG)"
    BUNDLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist" 2>/dev/null || echo "$BUNDLE")
    echo "-- [go] using gd-built ipa: $(basename "$ipa"), bundle $BUNDLE"
else
    echo "-- [$LANG] export Xcode project"
    rm -rf "$OUT/xc-$LANG"; mkdir -p "$OUT/xc-$LANG"
    "$BIN" --headless --path "$PROJ" --import >>"$LOG" 2>&1 || true
    "$BIN" --headless --path "$PROJ" --export-release "$PRESET" "$OUT/xc-$LANG/spritebench.ipa" >>"$LOG" 2>&1 || true
    [ -f "$OUT/xc-$LANG/spritebench.xcodeproj/project.pbxproj" ] || fail "no Xcode project exported (see $LOG)"

    echo "-- [$LANG] xcodebuild (unsigned)"
    ( cd "$OUT/xc-$LANG" && xcodebuild -project spritebench.xcodeproj -scheme spritebench \
        -configuration Release -sdk iphoneos -destination generic/platform=iOS build \
        CODE_SIGNING_ALLOWED=NO BUILD_DIR="$OUT/xc-$LANG/build" ) >>"$LOG" 2>&1
    app=$OUT/xc-$LANG/build/Release-iphoneos/spritebench.app
    [ -d "$app" ] || fail "xcodebuild produced no .app (see $LOG)"
fi

if [ "$LANG" = swift ]; then
    # Godot's iOS export doesn't embed the SwiftGodot .frameworks the dylib
    # links against; copy them into the app so dyld can resolve @rpath.
    fwsrc=$PROJ/addons/swift_godot_extension/bin/arm64-apple-ios/release
    mkdir -p "$app/Frameworks"
    for fw in SwiftGodot SwiftGodotRuntime; do
        [ -d "$app/Frameworks/$fw.framework" ] || cp -R "$fwsrc/$fw.framework" "$app/Frameworks/" 2>>"$LOG"
    done
fi

echo "-- [$LANG] sign"
mkdir -p "$OUT/xc-$LANG"
cp "$PROFILE" "$app/embedded.mobileprovision"
cat >"$OUT/xc-$LANG/ent.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>application-identifier</key><string>$TEAM.$BUNDLE</string>
  <key>com.apple.developer.team-identifier</key><string>$TEAM</string>
  <key>get-task-allow</key><true/>
</dict></plist>
EOF
# Sign every embedded binary before the app (deepest-first so nested ones
# are signed before their container).
find "$app" \( -name "*.dylib" -o -name "*.framework" \) -depth 2>/dev/null | while read -r f; do
    codesign --force --sign "$IDENTITY" "$f" >>"$LOG" 2>&1
done
codesign --force --sign "$IDENTITY" --entitlements "$OUT/xc-$LANG/ent.plist" "$app" >>"$LOG" 2>&1 \
    || fail "codesign (keychain locked? see $LOG)"

# Swift's prebuilt SwiftGodot frameworks target iOS 17+ (Swift runtime is
# in-OS), so it must run on the iOS 17+ device (IOS17_UDID) via devicectl;
# every other language runs on the default device via ios-deploy/AFC. An
# iOS 16 device would crash Swift at launch with a missing libswiftCore
# symbol. The app runs with --disable-render-loop (black screen = working).
mkdir -p "$OUT/dl-$LANG"
found=""
if [ "$LANG" = swift ]; then
    D17=${IOS17_UDID:?swift needs an iOS 17+ device (IOS17_UDID)}
    echo "-- [swift] install + run on iOS 17+ device via devicectl"
    # Clear any prior install first: a stale bundle signed with a different
    # application-identifier makes iOS reject the upgrade.
    xcrun devicectl device uninstall app --device "$D17" "$BUNDLE" >>"$LOG" 2>&1 || true
    xcrun devicectl device install app --device "$D17" "$app" >>"$LOG" 2>&1 || fail "devicectl install (see $LOG)"
    for attempt in 1 2 3 4 5; do
        timeout "${BENCH_RUN_TIMEOUT:-300}" xcrun devicectl device process launch --device "$D17" \
            --terminate-existing "$BUNDLE" --arguments "--disable-render-loop" >>"$LOG" 2>&1 || true
        sleep 45
        rm -f "$OUT/dl-$LANG/spritebench_results.csv"
        xcrun devicectl device copy from --device "$D17" --domain-type appDataContainer \
            --domain-identifier "$BUNDLE" --source Documents/spritebench_results.csv \
            --destination "$OUT/dl-$LANG/spritebench_results.csv" >>"$LOG" 2>&1 || true
        [ -s "$OUT/dl-$LANG/spritebench_results.csv" ] && { found="$OUT/dl-$LANG/spritebench_results.csv"; break; }
        echo "   attempt $attempt: no results yet (device locked?), retrying"
    done
    [ -n "$found" ] || fail "no results CSV from device after retries (see $LOG)"
    xcrun devicectl device uninstall app --device "$D17" "$BUNDLE" >>"$LOG" 2>&1 || true
else
    # Install with libimobiledevice, NOT ios-deploy: Xcode 26 dropped iOS 16
    # DeviceSupport, so ios-deploy's install-then-debug-launch aborts on the
    # missing Symbols dir (reporting failure even though the install part
    # succeeded). ideviceinstaller wants a package file, so wrap the .app in a
    # Payload/ .ipa. The developer disk image is already mounted (idevicedebug
    # uses it to launch), and house_arrest/AFC pulls results; neither needs
    # the Xcode DeviceSupport that broke.
    echo "-- [$LANG] install on device"
    # Re-package the (now signed) .app as a fresh Payload/ .ipa. For go the
    # source .app was extracted from gd's unsigned .ipa into $OUT/xc-go/Payload,
    # so build the zip in a clean subdir to avoid nesting it inside itself.
    stage=$OUT/xc-$LANG/stage; rm -rf "$stage"; mkdir -p "$stage/Payload"
    cp -R "$app" "$stage/Payload/"
    ( cd "$stage" && rm -f app.ipa && zip -qr app.ipa Payload ) >>"$LOG" 2>&1
    ideviceinstaller -u "$UDID" uninstall "$BUNDLE" >>"$LOG" 2>&1 || true
    if ! ideviceinstaller -u "$UDID" install "$stage/app.ipa" >>"$LOG" 2>&1; then
        # ideviceinstaller's AFC staging fails for some bundle ids (e.g. the Go
        # app's gd.graphics: "afc_file_open on PublicStaging/... failed").
        # ios-deploy's install path works; its --justlaunch then fails at the
        # debug-launch (missing iOS-16 DeviceSupport), but the install completes
        # first and idevicedebug does the real launch below.
        echo "   ideviceinstaller failed; installing via ios-deploy"
        ios-deploy --id "$UDID" --bundle "$app" --justlaunch --noninteractive >>"$LOG" 2>&1 || true
        ios-deploy --id "$UDID" --list_bundle_id 2>/dev/null | tr -d '\r' | grep -qx "$BUNDLE" \
            || fail "install failed via ideviceinstaller and ios-deploy (see $LOG)"
    fi
    # Launch via the mounted DDI and pull, retrying: a passcode-locked device
    # can't launch until unlocked (the iPhone 8 here has no passcode). The
    # app's screen goes black under --disable-render-loop while it runs.
    echo "-- [$LANG] launch + pull"
    if [ "$LANG" = go ]; then
        # The Go app runs to completion then exits on its own. It must be
        # launched DETACHED and left alone: a resident idevicedebug session is
        # torn down by the AFC/house_arrest pull, which takes the app with it
        # mid-run (and re-launching each retry restarts the benchmark). Launch
        # once, then poll only the pull until the results file appears.
        idevicedebug --detach -u "$UDID" run "$BUNDLE" -- --disable-render-loop >>"$LOG" 2>&1 || true
        # The sprites-at-target search runs for a few minutes; poll generously.
        for attempt in $(seq 1 24); do
            sleep 15
            rm -rf "$OUT/dl-$LANG"
            ios-deploy --id "$UDID" --bundle_id "$BUNDLE" --download=/Documents --to "$OUT/dl-$LANG" >>"$LOG" 2>&1 || true
            found=$(find "$OUT/dl-$LANG" -name 'spritebench_results.csv' 2>/dev/null | head -1)
            [ -n "$found" ] && break
            echo "   attempt $attempt: no results yet"
        done
    else
        for attempt in 1 2 3 4 5; do
            timeout "${BENCH_RUN_TIMEOUT:-300}" idevicedebug -u "$UDID" run "$BUNDLE" -- --disable-render-loop >>"$LOG" 2>&1 || true
            rm -rf "$OUT/dl-$LANG"
            ios-deploy --id "$UDID" --bundle_id "$BUNDLE" --download=/Documents --to "$OUT/dl-$LANG" >>"$LOG" 2>&1 || true
            found=$(find "$OUT/dl-$LANG" -name 'spritebench_results.csv' 2>/dev/null | head -1)
            [ -n "$found" ] && break
            echo "   attempt $attempt: no results yet (device locked?), retrying in 15s"
            sleep 15
        done
    fi
    [ -n "$found" ] || fail "no results CSV in sandbox after retries (device stayed locked? see $LOG)"
    ideviceinstaller -u "$UDID" uninstall "$BUNDLE" >>"$LOG" 2>&1 || true
fi
cp "$found" "$CSV"
echo "   ok: $(cat "$CSV" | head -1) -> $(basename "$CSV")"
