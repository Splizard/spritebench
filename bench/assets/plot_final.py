#!/usr/bin/env python3
"""Collate the full cross-platform SpriteBench sweep into one figure.

Like plot.py, but every platform panel is titled with the exact device the
numbers were measured on, and languages a platform cannot run are shown as an
explicit 0 bar (never omitted). Reads the merged result CSVs from the
directory this script sits in.

CSV names are <label>[_<variant>]_sprites.csv; no variant tag is the Linux
container's native headless run. Each CSV holds one line, "<max_sprites>
<target_fps> <fps_at_max>": the largest sprite count the language sustains
at the target frame rate: the display refresh rate on devices whose main
loop is vsync-paced (Android/iOS), 60 fps headless. A lone "0" marks an
unsupported language."""

import glob
import os

import matplotlib.pyplot as plt
import pandas as pd
import seaborn as sns

NAME_MAP = {
    "cs": "C#",
    "gds": "GDScript",
    "graphicsgd": "Go",
    "graphicsgdmusl": "Go (musl)",
    "rustbalanced": "Safe Rust",
    "rustdisengaged": "Unsafe Rust",
    "swift": "Swift",
    "odin": "Odin",
    "cpp": "C++",
}

# variant tag -> (panel title, device the run was measured on)
VARIANTS = {
    None:      ("Linux (native headless)",
                "AMD Ryzen 9 5900XT · 16C/32T · Void Linux 7.0.12"),
    "html5":   ("Web (headless Chromium, WASM)",
                "AMD Ryzen 9 5900XT · 16C/32T · Void Linux 7.0.12"),
    "macos":   ("macOS (native headless)",
                "Apple M4 · 10-core · 16 GB · macOS 26.2 (25C56)"),
    "windows": ("Windows (native headless)",
                "Surface Pro 6 · Intel Core i7-8650U · 8 GB · Windows 11 (22631)"),
    "android": ("Android (on device)",
                "Samsung Galaxy Z Fold5 (SM-F946B) · Snapdragon 8 Gen 2 · Android 16"),
    "ios":     ("iOS (on device)",
                "iPhone 8 (A11, iOS 16.7)"),
}
ORDER = [None, "macos", "windows", "android", "ios", "html5"]


def parse_label(label):
    label = label.replace("_sprites", "")
    parts = label.split("_")
    name = NAME_MAP.get(parts[0], parts[0].capitalize())
    variant = None
    for tag in parts[1:]:
        if tag in VARIANTS:
            variant = tag
            break
    return name, variant


def read_result(file_path):
    """-> (sprites, target_fps or None)"""
    with open(file_path) as f:
        fields = f.readline().split()
    if not fields:
        return None, None
    if len(fields) < 3:
        return int(float(fields[0])), None
    return int(float(fields[0])), float(fields[1])


def main():
    dir_path = os.path.dirname(os.path.realpath(__file__))
    data = []
    for file_path in glob.glob(os.path.join(dir_path, "*.csv")):
        file_name = os.path.basename(file_path)
        if os.path.getsize(file_path) == 0:
            continue
        name, variant = parse_label(file_name.replace(".csv", ""))
        try:
            sprites, target = read_result(file_path)
            if sprites is None:
                continue
            data.append({"Implementation": name, "Variant": variant,
                         "Sprites": sprites, "Target": target})
        except Exception as e:
            print(f"Error reading {file_name}: {e}")

    if not data:
        print("No valid data found in CSV files.")
        return

    plot_df = pd.DataFrame(data)
    present = set(plot_df["Variant"])
    variants = [v for v in ORDER if v in present]

    # Sort implementations by the Linux native results when available.
    base = plot_df[plot_df["Variant"].isnull()]
    if base.empty:
        base = plot_df
    order = (base.groupby("Implementation")["Sprites"].mean()
             .sort_values(ascending=False).index)

    sns.set_theme()
    fig, axes = plt.subplots(
        len(variants), 1, figsize=(11, 4.6 * len(variants)), squeeze=False
    )

    for ax, variant in zip(axes.flat, variants):
        title, device = VARIANTS[variant]
        vdf = plot_df[plot_df["Variant"].isnull()] if variant is None \
            else plot_df[plot_df["Variant"] == variant]
        targets = sorted(set(t for t in vdf["Target"] if t and t > 0))
        note = " / ".join(f"{t:.0f}" for t in targets) + " fps target" if targets else ""
        vorder = [i for i in order if i in set(vdf["Implementation"])]
        sns.barplot(
            x="Implementation", y="Sprites", data=vdf,
            order=vorder, errorbar=None, ax=ax,
        )
        ax.bar_label(
            ax.containers[-1], padding=2, fmt="%.0f",
            fontweight="bold", fontsize=8, label_type="center",
        )
        ax.set_title(f"{title}: {note}\n{device}" if note else f"{title}\n{device}",
                     fontsize=12, linespacing=1.4)
        ax.set_xlabel("")
        ax.set_ylabel("Max sprites at target (higher is better)", fontsize=10)

    fig.suptitle("SpriteBench: max sprites sustained at the target frame rate\n"
                 "(render loop disabled: measures per-frame binding overhead)",
                 fontsize=14)
    fig.tight_layout(rect=(0, 0, 1, 0.97))
    for ext in ("svg", "png"):
        out = os.path.join(dir_path, f"benchmark_final.{ext}")
        fig.savefig(out, dpi=140)
        print(f"saved {out}")


if __name__ == "__main__":
    main()
