#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

proj=$WORK/spritebench_swift
rc=0

case $BENCH_PLATFORM in
    macos)   triple=arm64-apple-macosx; libext=dylib; libprefix=lib ;;
    windows) triple=x86_64-unknown-windows-msvc; libext=dll; libprefix="" ;;
    *)       triple=x86_64-unknown-linux-gnu; libext=so; libprefix=lib ;;
esac

# SwiftGodot main needs a newer Swift than Xcode ships; use the swift.org
# toolchain installed by setup_macos.sh (TOOLCHAINS steers swift/xcrun).
if [ "$BENCH_PLATFORM" = macos ]; then
    xctc=$(ls -d "$HOME"/Library/Developer/Toolchains/swift-*-RELEASE.xctoolchain 2>/dev/null | sort | tail -1)
    if [ -n "$xctc" ]; then
        TOOLCHAINS=$(plutil -extract CFBundleIdentifier raw "$xctc/Info.plist")
        export TOOLCHAINS
        echo "-- using swift toolchain $TOOLCHAINS"
    fi
fi

echo "-- building SwiftGodot extension (release, first build takes a while)"
# -no-verify-emitted-module-interface: SwiftGodot's library-evolution
# interface fails verification on Linux (upstream issue), but builds fine.
(cd "$proj" && swift build -c release \
    --package-path swift_godot_game \
    --scratch-path "$CACHE/swift-scratch" \
    -Xswiftc -no-verify-emitted-module-interface) \
    >"$LOGS_DIR/build.swift.log" 2>&1

# Populate both the release and debug bin dirs with the release build: the
# editor performing the export loads the .debug gdextension entries, and on
# macOS a missing dylib crashes the export.
for target in release debug; do
    bindir=$proj/addons/swift_godot_extension/bin/$triple/$target
    mkdir -p "$bindir"
    cp "$CACHE/swift-scratch/$triple/release/${libprefix}SpriteBenchSwift.$libext" \
       "$CACHE/swift-scratch/$triple/release/${libprefix}SwiftGodot.$libext" \
       "$bindir/"
    if [ "$BENCH_PLATFORM" = windows ]; then
        # The Swift runtime is not part of Windows; SpriteBenchSwift.dll fails
        # to load (Error 126) without swiftCore/Foundation/etc. beside it.
        rt=$(ls -d "$(cygpath -u "$LOCALAPPDATA")"/Programs/Swift/Runtimes/*/usr/bin 2>/dev/null | sort | tail -1)
        [ -n "$rt" ] && cp "$rt"/*.dll "$bindir/" 2>/dev/null || true
    fi
done

godot_import "$proj"

if mode_enabled headless; then
    godot_export_native "$proj" "$WORK/build/swift"
    if [ "$BENCH_PLATFORM" = macos ]; then
        # Godot bundles the .gdextension's entry dylib (libSpriteBenchSwift)
        # into Contents/Frameworks but not its @rpath dependency on
        # libSwiftGodot.dylib, so the extension fails to dlopen at launch
        # (NSException in open_dynamic_library). Drop the sibling dylib in
        # beside it (same @rpath) and re-sign the modified bundle.
        app=${NATIVE_BIN%/Contents/MacOS/*}
        cp "$CACHE/swift-scratch/$triple/release/${libprefix}SwiftGodot.$libext" \
           "$app/Contents/Frameworks/" 2>/dev/null || true
        codesign -f -s - --deep "$app" >/dev/null 2>&1 || true
    fi
    if [ "$BENCH_PLATFORM" = linux ]; then
        # The extension needs the Swift runtime and its sibling
        # libSwiftGodot.so resolvable at load time. (On macOS the runtime is
        # part of the OS and the export bundles the dylibs.)
        export LD_LIBRARY_PATH="$(dirname "$NATIVE_BIN"):/opt/swift/usr/lib/swift/linux${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    fi
    run_native "$NATIVE_BIN" swift swift || rc=1
fi

if mode_enabled web; then
    mark_unsupported_web swift "SwiftGodot has no web export in this project"
fi

exit $rc
