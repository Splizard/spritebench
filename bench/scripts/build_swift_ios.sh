#!/bin/bash
# Build the Swift GDExtension for iOS and run it on an iOS 17+ device.
# Runs ON the Mac. Proven working (iPhone 16, iOS 26: 60 fps).
#
# Why this is separate from the other platforms' Swift build: SwiftGodot's
# source build needs a code-generator build-tool plugin whose host-only deps
# (swift-syntax, ArgumentParser) do not cross-compile to iOS, and xcodebuild
# refuses SwiftGodot's unsafeFlags in a versioned dependency. The escape is
# SwiftGodot's PREBUILT xcframeworks (SwiftGodot/SwiftGodotRuntime/GDExtension):
# no source build, no cross-compiled build-tool plugins. Only the @Godot /
# #initSwiftExtension MACROS remain, and macros always build for the host.
#
# IMPORTANT: the prebuilt frameworks target iOS 17+ (Swift's runtime is in the
# OS), so this needs an iOS 17+ device. An iOS 16 device fails at launch with
# "Symbol not found ... libswiftCore.dylib (built for iOS 17.0)".
set -euo pipefail

SG_VERSION=${SG_VERSION:-v0.76.1}
ROOT=${SPRITEBENCH_MAC_ROOT:-$HOME/spritebench-bench}
PROJ=$ROOT/repo/spritebench_swift
GG=$PROJ/swift_godot_game
IOS_MIN=17.0
export PATH=/opt/homebrew/opt/coreutils/libexec/gnubin:/opt/homebrew/bin:$PATH

# 1. Prebuilt SwiftGodot xcframeworks (cached).
cache=$ROOT/cache/swiftgodot-$SG_VERSION
if [ ! -d "$cache/SwiftGodot.xcframework" ]; then
    mkdir -p "$cache"; cd "$cache"
    for a in SwiftGodot SwiftGodotRuntime GDExtension; do
        curl -fsSLo $a.zip "https://github.com/migueldeicaza/SwiftGodot/releases/download/$SG_VERSION/$a.xcframework.zip"
        unzip -q -o $a.zip; rm $a.zip
    done
fi

# 2. Host-built @Godot/#initSwiftExtension macro plugin (from matching
# source). SwiftGodot's manifest is swift-tools 6.3, so parsing/building it
# needs the swift.org 6.3+ toolchain (Xcode's 6.2.1 can't). The macro is a
# host plugin; the resulting executable loads fine into the default-toolchain
# compile of our extension below.
macro=$ROOT/cache/SwiftGodotMacroLibrary-tool
if [ ! -x "$macro" ]; then
    sgsrc=$(mktemp -d)
    git clone -q --depth 1 --branch "$SG_VERSION" https://github.com/migueldeicaza/SwiftGodot "$sgsrc/SwiftGodot"
    xctc=$(ls -d "$HOME"/Library/Developer/Toolchains/swift-*-RELEASE.xctoolchain 2>/dev/null | sort | tail -1)
    ( cd "$sgsrc/SwiftGodot" \
      && TOOLCHAINS=$(plutil -extract CFBundleIdentifier raw "$xctc/Info.plist") \
         swift build -c release --product SwiftGodotMacroLibrary --scratch-path "$sgsrc/build" )
    cp "$sgsrc/build/"*/release/SwiftGodotMacroLibrary-tool "$macro"
    rm -rf "$sgsrc"
fi

# 3. A binary-only Package.swift + inline entry point, in a build copy.
work=$ROOT/cache/swift-ios-work
rm -rf "$work"; cp -R "$GG" "$work"
rm -rf "$work/.build"* "$work/Package.resolved"
mkdir -p "$work/Frameworks"
cp -R "$cache"/SwiftGodot.xcframework "$cache"/SwiftGodotRuntime.xcframework "$cache"/GDExtension.xcframework "$work/Frameworks/"
cat >"$work/Sources/SpriteBenchSwift/Entry.swift" <<EOF
import SwiftGodot
#initSwiftExtension(cdecl: "swift_entry_point", types: [SpriteBench.self, Sprite.self])
EOF
cat >"$work/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "SpriteBenchSwift",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "SpriteBenchSwift", type: .dynamic, targets: ["SpriteBenchSwift"])],
    targets: [
        .binaryTarget(name: "SwiftGodot", path: "Frameworks/SwiftGodot.xcframework"),
        .binaryTarget(name: "SwiftGodotRuntime", path: "Frameworks/SwiftGodotRuntime.xcframework"),
        .binaryTarget(name: "GDExtension", path: "Frameworks/GDExtension.xcframework"),
        .target(
            name: "SpriteBenchSwift",
            dependencies: ["SwiftGodot", "SwiftGodotRuntime", "GDExtension"],
            swiftSettings: [.unsafeFlags(["-load-plugin-executable", "$macro#SwiftGodotMacroLibrary"])]
        ),
    ]
)
EOF

# 4. Build the extension for the device (iOS) and host (macOS, for the editor).
iossdk=$(xcrun --sdk iphoneos --show-sdk-path)
( cd "$work" && swift build -c release --scratch-path .build-ios --triple arm64-apple-ios${IOS_MIN} -Xswiftc -sdk -Xswiftc "$iossdk" )
( cd "$work" && swift build -c release --scratch-path .build-mac )

# 5. Stage libs + framework slices into the addons bin the gdextension points at.
for pair in "arm64-apple-macosx:.build-mac:macos-arm64_x86_64" "arm64-apple-ios:.build-ios:ios-arm64"; do
    triple=${pair%%:*}; rest=${pair#*:}; build=${rest%%:*}; slice=${rest#*:}
    dst=$PROJ/addons/swift_godot_extension/bin/$triple/release
    rm -rf "$dst"; mkdir -p "$dst"
    cp "$work/$build/${triple}/release/libSpriteBenchSwift.dylib" "$dst/"
    cp -R "$cache/SwiftGodot.xcframework/$slice/SwiftGodot.framework" "$dst/"
    cp -R "$cache/SwiftGodotRuntime.xcframework/$slice/SwiftGodotRuntime.framework" "$dst/"
done
echo "swift iOS + macOS extension libs staged; export the Godot iOS project, then"
echo "xcodebuild, ensure the two frameworks are in the .app/Frameworks, sign, and"
echo "deploy to an iOS 17+ device (devicectl install/launch, copy Documents back)."
