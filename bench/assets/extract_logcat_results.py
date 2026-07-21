#!/usr/bin/env python3
"""Extract the sprites-at-target result line printed between
SPRITEBENCH_RESULTS_BEGIN/END markers from an `adb logcat` capture and write
it to a CSV. The payload is a single line: "<max_sprites> <target_fps>
<fps_at_max>".

Godot's print() lands in logcat as one record per line, e.g.:
  07-20 17:30:00.123 12345 12399 I godot   : 163840 120 113.52
Only the message payload after the "tag : " separator is considered; the
line prefix contains timestamps/pids that would otherwise be mistaken for
result fields."""

import re
import sys


def main():
    log_path, csv_path = sys.argv[1], sys.argv[2]
    payloads = []
    with open(log_path, errors="replace") as f:
        for line in f:
            m = re.match(r"^\S+\s+\S+\s+\d+\s+\d+\s+[A-Z]\s+\S+\s*:\s?(.*)$", line)
            if m:
                payloads.append(m.group(1))
    joined = "\n".join(payloads)

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
