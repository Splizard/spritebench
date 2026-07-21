#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

proj=$WORK/spritebench_rust
rc=0

for variant in balanced disengaged; do
    features=()
    [ "$variant" = disengaged ] && features=(--features disengaged)

    case $BENCH_PLATFORM in
        macos)   rustlib=librust.dylib ;;
        windows) rustlib=rust.dll ;;
        *)       rustlib=librust.so ;;
    esac

    if mode_enabled headless; then
        echo "-- building rust ($variant, native release)"
        if (cd "$proj/rust" && CARGO_TARGET_DIR=$CACHE/rust-target-$variant \
                cargo build --release "${features[@]}") \
                >"$LOGS_DIR/build.rust-$variant.log" 2>&1; then
            # The editor performing the export loads the extension with the
            # debug feature set; satisfy the .debug gdextension entry with
            # the release lib (on macOS a missing dylib crashes the export).
            mkdir -p "$proj/rust/target/release" "$proj/rust/target/debug"
            cp "$CACHE/rust-target-$variant/release/$rustlib" "$proj/rust/target/release/$rustlib"
            cp "$CACHE/rust-target-$variant/release/$rustlib" "$proj/rust/target/debug/$rustlib"
            godot_import "$proj/godot"
            if godot_export_native "$proj/godot" "$WORK/build/rust-$variant"; then
                run_native "$NATIVE_BIN" "rust$variant" "rust-$variant" || rc=1
            else
                rc=1
            fi
        else
            echo "   FAILED: build (see $LOGS_DIR/build.rust-$variant.log)"
            rc=1
        fi
    fi

    if mode_enabled android; then
        echo "-- building rust ($variant, android arm64 release)"
        # gdext <=0.4.5 (crates.io) fails to register classes on Android:
        # Godot moves the main-thread ID between InitLevel::Core and Server,
        # and only gdext master rediscovers it (godot-rust/gdext#1423, fixed
        # by PR #1574). Build the android lib from a copy pinned to git master
        # so the desktop builds keep using the released 0.4.5.
        andr_src=$proj/rust-android
        if [ ! -d "$andr_src" ]; then
            cp -r "$proj/rust" "$andr_src"
            sed -i 's|^godot = ".*"$|godot = { git = "https://github.com/godot-rust/gdext", branch = "master" }|' "$andr_src/Cargo.toml"
            rm -f "$andr_src/Cargo.lock"
            # gdext master returns Gd<SceneTree> from get_tree(), not Option.
            sed -i 's|get_tree().unwrap().quit()|get_tree().quit()|' "$andr_src/src/window.rs"
        fi
        if (cd "$andr_src" && CARGO_TARGET_DIR=$CACHE/rust-android-$variant \
                CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$(ndk_cc)" \
                cargo build --release --target aarch64-linux-android "${features[@]}") \
                >"$LOGS_DIR/build.rust-$variant-android.log" 2>&1; then
            mkdir -p "$proj/rust/target/aarch64-linux-android/release"
            cp "$CACHE/rust-android-$variant/aarch64-linux-android/release/librust.so" \
               "$proj/rust/target/aarch64-linux-android/release/librust.so"
            # The committed gdextension points android.arm64 at
            # res://../rust/target/..., a path that escapes the godot/
            # project root. Godot packages the .so but its Android runtime
            # cannot map that '../' path back to the packaged basename, so it
            # silently never loads the extension ("Cannot get class Main").
            # Stage the lib inside the project and point the work-copy
            # gdextension at a clean res:// path (desktop keeps the ../ path,
            # which works there).
            mkdir -p "$proj/godot/bin/android"
            cp "$CACHE/rust-android-$variant/aarch64-linux-android/release/librust.so" \
               "$proj/godot/bin/android/librust.so"
            sed -i 's#^android\.\(debug\|release\)\.arm64 =.*#android.\1.arm64 = "res://bin/android/librust.so"#' \
                "$proj/godot/spritebench.gdextension"
            godot_import "$proj/godot"
            apk=$WORK/build/rust-$variant-android/spritebench.apk
            godot_export "$proj/godot" Android "$apk" && stage_apk "rust$variant" "$apk" || rc=1
        else
            echo "   FAILED: android build (see $LOGS_DIR/build.rust-$variant-android.log)"
            rc=1
        fi
    fi

    if mode_enabled web; then
        echo "-- building rust ($variant, wasm release)"
        # Wasm needs FFI bindings regenerated for 32 bits (api-custom), and
        # godot-codegen 0.4.5 cannot parse the Godot 4.6 api dump, so build
        # from a copy that uses gdext git master, matching the commented-out
        # dependency the author used for the published web results.
        export GODOT4_BIN=/usr/local/bin/godot
        web_src=$proj/rust-web
        if [ ! -d "$web_src" ]; then
            cp -r "$proj/rust" "$web_src"
            sed -i 's|^godot = ".*"$|godot = { git = "https://github.com/godot-rust/gdext", branch = "master" }|' "$web_src/Cargo.toml"
            # The lock file from the published crate conflicts with master.
            rm -f "$web_src/Cargo.lock"
            # gdext master returns Gd<SceneTree> from get_tree(), not Option.
            sed -i 's|get_tree().unwrap().quit()|get_tree().quit()|' "$web_src/src/window.rs"
            # -Zemscripten-wasm-eh was removed from recent nightlies.
            sed -i '/emscripten-wasm-eh/d' "$web_src/.cargo/config.toml"
        fi
        rust_web_features="godot/experimental-wasm,godot/lazy-function-tables,godot/api-custom"
        web_features=(--features "$rust_web_features")
        [ "$variant" = disengaged ] && web_features=(--features "disengaged,$rust_web_features")
        # panic=abort: current nightlies only emit the new wasm-EH ABI, which
        # Godot's legacy-EH web templates cannot host; aborting on panic
        # avoids exception imports entirely.
        if (cd "$web_src" && set +u && source /opt/emsdk/emsdk_env.sh >/dev/null 2>&1 \
                && CARGO_TARGET_DIR=$CACHE/rust-wasm-$variant \
                CARGO_PROFILE_RELEASE_PANIC=abort \
                cargo +nightly build --release -Zbuild-std=std,panic_abort --target wasm32-unknown-emscripten "${web_features[@]}") \
                >"$LOGS_DIR/build.rust-$variant-web.log" 2>&1; then
            mkdir -p "$proj/rust/target/wasm32-unknown-emscripten/release"
            # emscripten cdylibs come out as rust.wasm; the gdextension
            # expects librust.wasm.
            wasm_out=$CACHE/rust-wasm-$variant/wasm32-unknown-emscripten/release
            cp "$wasm_out/librust.wasm" "$proj/rust/target/wasm32-unknown-emscripten/release/librust.wasm" 2>/dev/null \
                || cp "$wasm_out/rust.wasm" "$proj/rust/target/wasm32-unknown-emscripten/release/librust.wasm"
            godot_import "$proj/godot"
            webdir=$WORK/build/rust-$variant-web
            godot_export "$proj/godot" Web "$webdir/index.html"
            run_web "$webdir" index.html "rust$variant" "rust-$variant" || rc=1
        else
            echo "   FAILED: wasm build (see $LOGS_DIR/build.rust-$variant-web.log)"
            rc=1
        fi
    fi
done

exit $rc
