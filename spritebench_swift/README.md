Swift (SwiftGodot) SpriteBench
=============================

Prerequisites
-------------

- [Swift 6.1+](https://www.swift.org/install/) toolchain
- Godot 4.6+

Build
-----

```sh
# Debug (for development / editor testing)
swift build -c debug --package-path swift_godot_game --build-path addons/swift_godot_extension/bin

# Release (for benchmarking)
swift build -c release --package-path swift_godot_game --build-path addons/swift_godot_extension/bin
```

The `--build-path` flag places the compiled `.dylib`/`.so`/`.dll` where the `.gdextension` file expects them.
