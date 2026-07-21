#!/usr/bin/env python3
"""Extract the sprites-at-target result line printed between
SPRITEBENCH_RESULTS_BEGIN/END markers from a Chromium --enable-logging=stderr
log and write it to a CSV. The payload is a single line: "<max_sprites>
<target_fps> <fps_at_max>".

Console messages look like:
  [0718/072722.385700:INFO:CONSOLE:452] "163840 60 58.21", source: http://... (452)
so only the quoted message contents are considered; the line prefix contains
timestamps that would otherwise be mistaken for result fields."""

import re
import sys


def main():
    log_path, csv_path = sys.argv[1], sys.argv[2]
    with open(log_path, errors="replace") as f:
        log = f.read()

    messages = re.findall(r':CONSOLE[^\]]*\]\s+"(.*?)", source:', log, re.DOTALL)
    joined = "\n".join(messages)

    match = re.search(
        r"SPRITEBENCH_RESULTS_BEGIN(.*?)SPRITEBENCH_RESULTS_END", joined, re.DOTALL
    )
    if not match:
        print("no results markers found in " + log_path, file=sys.stderr)
        sys.exit(1)

    result = re.search(r"(\d+)\s+(\d+)\s+([\d.]+)", match.group(1))
    if not result:
        print("no result line found between markers in " + log_path, file=sys.stderr)
        sys.exit(1)

    with open(csv_path, "w") as f:
        f.write(" ".join(result.groups()) + "\n")
    print(f"extracted result '{' '.join(result.groups())}' -> {csv_path}")


if __name__ == "__main__":
    main()
