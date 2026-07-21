Automated SpriteBench
=====================

Fully automated, containerized version of the benchmark: one command builds
every implementation, exports release builds with Godot, runs them, and
produces one result CSV per implementation plus a comparison chart.

```sh
./bench/run.sh
```

The metric is **max sprites sustained at the target frame rate**: the frame
rate is a per-frame deadline (16.7 ms at 60 fps; a frame that misses it is a
visible stutter), and a sprite count only counts as sustained if the
99th-percentile frame time of a 120-frame window stays within 5% of that
deadline. The search doubles/halves the count, binary-searches the boundary,
and confirms the answer with a best-of-3 verify that walks the count down
until it passes. On devices the target is the display refresh
(e.g. 120 Hz on a Fold5); headless and web target 60 fps.

Requires only [podman](https://podman.io) (set `CONTAINER_ENGINE=docker` to
use docker instead). Results land in `bench/results/<timestamp>/`:

- `<impl>_sprites.csv`: the native headless result line
  `<max_sprites> <target_fps> <fps_at_max>`
- `<impl>_html5_sprites.csv`: web build result, measured in headless Chromium
- `<impl>_macos_sprites.csv`: results from other platforms, tagged by
  platform (see below)
- `benchmark_results.svg`: comparison chart (one panel per platform/variant)
- `logs/`: build/export/run logs for every step

If a language does not support a platform, it scores an explicit **0**
there (a zeros-only CSV, drawn as a 0 bar) rather than being silently
omitted.

Other platforms
---------------

The container covers Linux native + web. Additional single-command runners
benchmark the same tree on real hardware over the network:

```sh
./bench/run-macos.sh        # ssh to a Mac, provision on first run, run all
                            # implementations natively, pull the CSVs back
./bench/run-windows.sh      # same pattern against a Windows machine
./bench/run-android.sh      # build APKs in the container, run on an
                            # adb-connected device, scrape logcat
./bench/run-ios.sh          # build/sign on the Mac, run on a USB iPhone,
                            # pull results from the app sandbox
```

Machine-specific config (ssh hosts, Apple signing team, keychain password)
lives in the gitignored `bench/.env`; copy `bench/.env.example` and fill it
in. `run-macos.sh` needs passwordless ssh to the Mac (set
`SPRITEBENCH_MAC_HOST` there, or pass `--host`) and
homebrew on the Mac; everything else (Godot editors + export templates,
scons, rust, dotnet, odin + bindings, godot-cpp) is provisioned
automatically into `~/spritebench-bench` on first run. All runners accept
`--name`: reuse one results dir name across platforms to merge everything
into a single chart (`assets/plot_final.py` collates the panels).

How it works
------------

- The repo is mounted read-only and copied into a persistent work volume, so
  your checkout is never touched and rebuilds are incremental.
- Each implementation checks the `SPRITEBENCH_OUTPUT` environment variable:
  when set, it writes its result line to that file and quits instead of
  showing the interactive TextEdit. Native benchmarks run the release
  exports with `--headless`, so the benchmark measures per-frame call
  overhead rather than rendering.
- Web builds print the result line to the JS console between
  `SPRITEBENCH_RESULTS_BEGIN`/`END` markers. The runner serves each web export
  locally (with cross-origin isolation headers) and loads it in
  `chrome-headless-shell`, scraping the console log.
- All toolchains are pinned via build args in the `Containerfile`
  (Godot 4.6, Go, Rust stable+nightly, .NET, Swift, Odin + Toxin bindings,
  emsdk, godot-cpp).

Options
-------

```sh
./bench/run.sh --langs "gdscript go rust"    # subset of implementations
./bench/run.sh --modes headless              # skip the web benchmarks
./bench/run.sh --graphics-gd ~/git/quaadgras/graphics.gd
                                             # bench a local graphics.gd checkout
./bench/run.sh --no-build                    # reuse the existing image
```

Web coverage: GDScript, C++, Rust, and Go have web export presets; C#, Swift,
and Odin are native-only. A failing implementation never blocks the others;
check the summary at the end of the run and the corresponding log file.

The Rust web build compiles a patched copy (`rust-web/`, created at bench
time) against gdext git master with `-Zbuild-std` and `panic=abort`: the
published crate's codegen cannot parse the Godot 4.6 API dump, and current
Rust nightlies only emit the new wasm-EH ABI, which Godot's legacy-EH web
templates cannot host unless the module needs no exception handling at all.

Caveats
-------

- Results measure *relative* overhead between bindings on whatever machine
  runs the container; absolute sprite counts are not comparable across
  machines.
- The web runs disable the render loop (`--disable-render-loop` injected into
  the exported shell): headless Chromium only has SwiftShader (software
  WebGL), which would otherwise rasterization-bind every implementation to
  the same ~7.5 fps. With rendering off they measure per-frame binding
  overhead, same as the native `--headless` runs.
- For the fairest numbers, run on a quiet machine, ideally freshly
  rebooted. The criterion judges the slowest 1% of frames, so stray
  background processes can swing spiky-tailed implementations by up to a
  third of their score.
