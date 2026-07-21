#!/usr/bin/env python3
"""Plot automated SpriteBench results (sprites-at-target metric).

Each CSV holds one line, "<max_sprites> <target_fps> <fps_at_max>": the
largest sprite count the language sustains at the target frame rate (the
display refresh rate on device, 60 fps headless). A lone "0" marks a
language the platform does not support: scored as an explicit 0 rather than
omitted. Renders one panel per variant from the directory this script sits
in."""

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

# CSV names are <label>[_<variant>]_sprites.csv; no variant tag means the
# Linux container's native headless run.
VARIANTS = {
    "html5": "Web (headless Chromium)",
    "macos": "macOS (native headless)",
    "windows": "Windows (native headless)",
    "android": "Android (on device)",
    "ios": "iOS (on device)",
    None: "Linux (native headless)",
}


def parse_label(label):
    label = label.replace("_sprites", "")
    parts = label.split("_")
    name = NAME_MAP.get(parts[0], parts[0].capitalize())
    variant = VARIANTS[None]
    for tag in parts[1:]:
        if tag in VARIANTS:
            variant = VARIANTS[tag]
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
            print(f"Skipping empty file: {file_name}")
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
    variants = [v for v in VARIANTS.values() if v in set(plot_df["Variant"])]

    sns.set_theme()
    fig, axes = plt.subplots(
        len(variants), 1, figsize=(10, 4.5 * len(variants)), squeeze=False
    )

    # Sort implementations by native results when available.
    base = plot_df[plot_df["Variant"] == VARIANTS[None]]
    if base.empty:
        base = plot_df
    order = (base.groupby("Implementation")["Sprites"].mean()
             .sort_values(ascending=False).index)

    for ax, variant in zip(axes.flat, variants):
        vdf = plot_df[plot_df["Variant"] == variant]
        vorder = [i for i in order if i in set(vdf["Implementation"])]
        targets = sorted(set(t for t in vdf["Target"] if t and t > 0))
        note = " / ".join(f"{t:.0f}" for t in targets) + " fps target" if targets else ""
        sns.barplot(
            x="Implementation", y="Sprites", data=vdf,
            order=vorder, errorbar=None, ax=ax,
        )
        ax.bar_label(
            ax.containers[-1], padding=2, fmt="%.0f",
            fontweight="bold", fontsize=8, label_type="center",
        )
        ax.set_title(f"{variant}: {note}" if note else variant, fontsize=13)
        ax.set_xlabel("")
        ax.set_ylabel("Max sprites at target (higher is better)", fontsize=10)

    fig.suptitle("SpriteBench: max sprites sustained at target frame rate",
                 fontsize=15)
    fig.tight_layout(rect=(0, 0, 1, 0.97))
    output_path = os.path.join(dir_path, "benchmark_results.svg")
    fig.savefig(output_path)
    print(f"Plot saved to {output_path}")


if __name__ == "__main__":
    main()
