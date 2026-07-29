#!/usr/bin/env python3
"""Plot automated SpriteBench results (sprites-at-target metric).

Each CSV holds one line per pass, "<max_sprites> <target_fps> <fps_at_max>":
the largest sprite count the language sustains at the target frame rate (the
display refresh rate on device, 60 fps headless). A lone "0" marks a language
the platform does not support: scored as an explicit 0 rather than omitted.
Renders one panel per variant from the directory this script sits in.

A run made with BENCH_REPEATS>1 leaves several rows per language, and those
are drawn as a box spanning the full range rather than averaged into a bar.
The spread is not incidental here: it is often larger than the gap between
neighbouring languages, so a single bar invites a ranking the measurement
does not support. With one row per language the plot falls back to bars,
which is honest in the other direction — nothing is known about the spread,
so none is drawn."""

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


def read_results(file_path):
    """-> [(sprites, target_fps or None)], one per pass"""
    rows = []
    with open(file_path) as f:
        for line in f:
            fields = line.split()
            if not fields:
                continue
            if len(fields) < 3:
                rows.append((int(float(fields[0])), None))
            else:
                rows.append((int(float(fields[0])), float(fields[1])))
    return rows


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
            for sprites, target in read_results(file_path):
                data.append({"Implementation": name, "Variant": variant,
                             "Sprites": sprites, "Target": target})
        except Exception as e:
            print(f"Error reading {file_name}: {e}")

    if not data:
        print("No valid data found in CSV files.")
        return

    plot_df = pd.DataFrame(data)

    # A zero means two different things: a language the platform cannot run
    # (mark_unsupported writes a lone 0, and it should stay on the chart as an
    # explicit zero), or a pass whose fit the benchmark refused to extrapolate
    # from. The two are only distinguishable by company: if any pass of an
    # implementation produced a real number, the zeros beside it are failed
    # passes and averaging them in would drag the bar toward a value nothing
    # measured. Drop those, and say so rather than quietly plotting fewer.
    dropped = []
    keep = []
    for (impl, variant), group in plot_df.groupby(["Implementation", "Variant"]):
        good = group[group["Sprites"] > 0]
        if good.empty or len(good) == len(group):
            keep.append(group)
            continue
        dropped.append((impl, variant, len(group) - len(good), len(group)))
        keep.append(good)
    plot_df = pd.concat(keep)
    for impl, variant, n, total in dropped:
        print(f"{impl} ({variant}): {n}/{total} passes had no usable fit; "
              f"plotting the remaining {total - n}")

    variants = [v for v in VARIANTS.values() if v in set(plot_df["Variant"])]

    sns.set_theme()
    fig, axes = plt.subplots(
        len(variants), 1, figsize=(10, 4.5 * len(variants)), squeeze=False
    )

    # Sort implementations by native results when available. The median is
    # the summary throughout: with a handful of passes and the odd bad one,
    # a mean would let a single outlier decide the ordering.
    base = plot_df[plot_df["Variant"] == VARIANTS[None]]
    if base.empty:
        base = plot_df
    order = (base.groupby("Implementation")["Sprites"].median()
             .sort_values(ascending=False).index)

    for ax, variant in zip(axes.flat, variants):
        vdf = plot_df[plot_df["Variant"] == variant]
        vorder = [i for i in order if i in set(vdf["Implementation"])]
        targets = sorted(set(t for t in vdf["Target"] if t and t > 0))
        note = " / ".join(f"{t:.0f}" for t in targets) + " fps target" if targets else ""
        passes = vdf.groupby("Implementation").size().max()
        medians = vdf.groupby("Implementation")["Sprites"].median()
        counts = vdf.groupby("Implementation").size()
        sns.barplot(
            x="Implementation", y="Sprites", data=vdf, order=vorder,
            estimator="median", errorbar=None, ax=ax,
        )
        if passes > 1:
            # The bar carries the magnitude, the whisker the uncertainty. The
            # whisker spans the full range rather than a confidence interval:
            # with a handful of passes every point is signal, and the spread
            # here is often wider than the gap to the neighbouring language —
            # which is the thing a bare bar chart invites you to misread.
            lo = vdf.groupby("Implementation")["Sprites"].min()
            hi = vdf.groupby("Implementation")["Sprites"].max()
            # Only bars with something to say get a whisker: a zero-height
            # one on a single measurement reads as a very small spread, which
            # is the opposite of what n=1 means.
            spread = [j for j, i in enumerate(vorder) if counts[i] > 1]
            if spread:
                ax.errorbar(
                    spread, [medians[vorder[j]] for j in spread],
                    yerr=[[medians[vorder[j]] - lo[vorder[j]] for j in spread],
                          [hi[vorder[j]] - medians[vorder[j]] for j in spread]],
                    fmt="none", ecolor="0.15", elinewidth=1.4, capsize=5,
                    capthick=1.4, zorder=5,
                )
            sns.stripplot(
                x="Implementation", y="Sprites", data=vdf[vdf["Implementation"].map(counts) > 1],
                order=vorder, color="0.15", size=3.5, jitter=0.12, alpha=0.85,
                ax=ax, zorder=6,
            )
            # Say how many passes each bar is made of. A language measured
            # once has no whisker, which otherwise reads as a language with no
            # variance rather than one with no evidence about it.
            ax.set_xticks(range(len(vorder)))
            ax.set_xticklabels([f"{i}\nn={counts[i]}" for i in vorder])
            note = f"{note}, whisker spans full range" if note else "whisker spans full range"
        ax.bar_label(
            ax.containers[0], labels=[f"{medians[i]:.0f}" for i in vorder],
            padding=2, fontweight="bold", fontsize=8, label_type="center",
            color="white",
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
