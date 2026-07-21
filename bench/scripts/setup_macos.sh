#!/bin/bash
# Idempotent provisioning for the macOS benchmark runner. Invoked on the Mac
# by run-macos.sh (or manually: bash bench/scripts/setup_macos.sh). Installs
# toolchains via homebrew (no sudo needed), Godot editors + macOS export
# templates, and the pinned third-party sources, all under
# ~/spritebench-bench. Completed steps are skipped on re-runs.
set -euo pipefail

# Keep these in sync with the ARGs in bench/Containerfile.
GODOT_VERSION=4.6-stable
GODOT_NEXT_VERSION=4.7-stable
DOTNET_CHANNEL=10.0
TOXIN_COMMIT=9b4652e
GD_CLASSES_COMMIT=958d411
GODOT_CPP_COMMIT=60b5a4196de8442b43b32ba68ebe1e79cfcb762f

ROOT=${SPRITEBENCH_MAC_ROOT:-$HOME/spritebench-bench}
mkdir -p "$ROOT/bin" "$ROOT/godot" "$ROOT/cache" "$ROOT/work" "$ROOT/results"

export PATH="/opt/homebrew/bin:/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH"

if ! command -v brew >/dev/null 2>&1; then
    echo "homebrew is required: https://brew.sh" >&2
    exit 1
fi

echo "-- homebrew packages"
for formula in bash coreutils scons rustup odin go; do
    brew list --formula "$formula" >/dev/null 2>&1 || brew install "$formula"
done

echo "-- rust toolchain"
if ! command -v cargo >/dev/null 2>&1 && [ ! -x "$HOME/.cargo/bin/cargo" ]; then
    rustup-init -y --profile minimal --default-toolchain stable
fi

# SwiftGodot main needs a newer Swift than Xcode ships; install the same
# swift.org release the container pins into the user's toolchains dir.
SWIFT_VERSION=6.3.2
echo "-- swift ${SWIFT_VERSION} toolchain"
if [ ! -d "$HOME/Library/Developer/Toolchains/swift-${SWIFT_VERSION}-RELEASE.xctoolchain" ]; then
    curl -fsSLo /tmp/swift.pkg \
        "https://download.swift.org/swift-${SWIFT_VERSION}-release/xcode/swift-${SWIFT_VERSION}-RELEASE/swift-${SWIFT_VERSION}-RELEASE-osx.pkg"
    installer -pkg /tmp/swift.pkg -target CurrentUserHomeDirectory
    rm /tmp/swift.pkg
fi

echo "-- dotnet sdk"
if [ ! -x "$ROOT/dotnet/dotnet" ]; then
    curl -fsSL https://dot.net/v1/dotnet-install.sh \
        | bash -s -- --channel "$DOTNET_CHANNEL" --install-dir "$ROOT/dotnet"
fi

# fetch_godot <zip_name> <dest_subdir> <link_name>
# Download a Godot macOS editor build, unpack it, and symlink its binary
# into $ROOT/bin under a stable name.
fetch_godot() {
    local zip=$1 dest=$ROOT/godot/$2 link=$ROOT/bin/$3
    if [ ! -e "$link" ] || [ ! -e "$(readlink "$link")" ]; then
        echo "-- godot: $zip"
        local ver=${zip#Godot_v}; ver=${ver%%_*}
        rm -rf "$dest"; mkdir -p "$dest"
        curl -fsSLo /tmp/godot-dl.zip \
            "https://github.com/godotengine/godot/releases/download/${ver}/${zip}"
        unzip -q /tmp/godot-dl.zip -d "$dest"
        rm /tmp/godot-dl.zip
        xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true
        local bin
        bin=$(find "$dest" -path '*/Contents/MacOS/*' -type f | head -1)
        [ -n "$bin" ] || { echo "no binary found in $zip" >&2; exit 1; }
        chmod +x "$bin"
        # Wrapper script, NOT a symlink: macOS does not resolve symlinks for
        # the executable path, so a symlinked mono editor cannot find its
        # sibling Resources/GodotSharp and .NET init fails silently.
        printf '#!/bin/sh\nexec "%s" "$@"\n' "$bin" >"$link"
        chmod +x "$link"
    fi
}
fetch_godot "Godot_v${GODOT_VERSION}_macos.universal.zip"          godot      godot
fetch_godot "Godot_v${GODOT_VERSION}_mono_macos.universal.zip"     godot-mono godot-mono
fetch_godot "Godot_v${GODOT_NEXT_VERSION}_macos.universal.zip"     godot-next godot-next

# fetch_templates <version> <tpz_name> <dest_subdir>
# Extract just the macOS template archive from a .tpz into the editor's
# expected export_templates location.
TEMPLATES="$HOME/Library/Application Support/Godot/export_templates"
fetch_templates() {
    local ver=$1 tpz=$2 dest=$TEMPLATES/$3
    if [ ! -f "$dest/macos.zip" ]; then
        echo "-- export templates: $3"
        mkdir -p "$dest"
        curl -fsSLo /tmp/godot-templates.tpz \
            "https://github.com/godotengine/godot/releases/download/${ver}/${tpz}"
        unzip -q -j -o /tmp/godot-templates.tpz templates/macos.zip -d "$dest"
        rm /tmp/godot-templates.tpz
    fi
}
TVER="$(echo "$GODOT_VERSION" | tr - .)"
TNVER="$(echo "$GODOT_NEXT_VERSION" | tr - .)"
fetch_templates "$GODOT_VERSION"      "Godot_v${GODOT_VERSION}_export_templates.tpz"      "$TVER"
fetch_templates "$GODOT_VERSION"      "Godot_v${GODOT_VERSION}_mono_export_templates.tpz" "$TVER.mono"
fetch_templates "$GODOT_NEXT_VERSION" "Godot_v${GODOT_NEXT_VERSION}_export_templates.tpz" "$TNVER"

# iOS export templates (the editor consumes ios.zip directly, still zipped).
# Fetched separately from fetch_templates: the template dirs already exist on
# provisioned Macs (the regular ios.zip was historically hand-installed), so
# key the check on the ios.zip file itself. The mono one is what the C# iOS
# export needs.
fetch_ios_templates() {
    local ver=$1 tpz=$2 dest=$TEMPLATES/$3
    if [ ! -f "$dest/ios.zip" ]; then
        echo "-- iOS export templates: $3"
        mkdir -p "$dest"
        curl -fsSLo /tmp/godot-templates.tpz \
            "https://github.com/godotengine/godot/releases/download/${ver}/${tpz}"
        unzip -q -j -o /tmp/godot-templates.tpz templates/ios.zip -d "$dest"
        rm /tmp/godot-templates.tpz
    fi
}
fetch_ios_templates "$GODOT_VERSION" "Godot_v${GODOT_VERSION}_export_templates.tpz"      "$TVER"
fetch_ios_templates "$GODOT_VERSION" "Godot_v${GODOT_VERSION}_mono_export_templates.tpz" "$TVER.mono"

echo "-- godot-cpp (pinned ${GODOT_CPP_COMMIT:0:10})"
if [ ! -e "$ROOT/cache/godot-cpp/.git" ]; then
    git init -q "$ROOT/cache/godot-cpp"
    git -C "$ROOT/cache/godot-cpp" remote add origin https://github.com/godotengine/godot-cpp
    git -C "$ROOT/cache/godot-cpp" fetch -q --depth=1 origin "$GODOT_CPP_COMMIT"
    git -C "$ROOT/cache/godot-cpp" checkout -q FETCH_HEAD
fi

# Odin's `shared:` collection lives under ODIN_ROOT; build a private root
# (symlinks to the brew install's base/core/vendor plus our own shared/) so
# the brew cellar stays untouched. Export ODIN_ROOT=$ROOT/odin-root to use.
echo "-- odin bindings"
odin_real_root=$(odin root)
mkdir -p "$ROOT/odin-root/shared"
for d in base core vendor; do
    ln -sfn "$odin_real_root/$d" "$ROOT/odin-root/$d"
done
if [ ! -d "$ROOT/odin-root/shared/GDWrapper" ]; then
    tmp=$(mktemp -d)
    git clone -q https://github.com/Ferinzz/Toxin.git "$tmp/Toxin"
    git -C "$tmp/Toxin" checkout -q "$TOXIN_COMMIT"
    git clone -q https://github.com/Ferinzz/Godot_Odin_Binds.git "$tmp/Godot_Odin_Binds"
    git -C "$tmp/Godot_Odin_Binds" checkout -q "$GD_CLASSES_COMMIT"
    cp -R "$tmp/Toxin/Toxin" "$tmp/Toxin/GDWrapper" "$tmp/Godot_Odin_Binds" "$ROOT/odin-root/shared/"
    rm -rf "$tmp"
fi

echo "-- setup complete ($ROOT)"
