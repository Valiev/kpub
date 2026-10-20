#!/usr/bin/env python3
"""Read or bump the release version. VERSION is the source of truth."""
import argparse
import re
from pathlib import Path

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("part", nargs="?", choices=["patch", "minor", "major"])
args = parser.parse_args()
value = (root / "VERSION").read_text().strip()
if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", value):
    parser.error("VERSION must contain MAJOR.MINOR.PATCH")
if args.part:
    numbers = list(map(int, value.split(".")))
    index = {"major": 0, "minor": 1, "patch": 2}[args.part]
    numbers[index] += 1
    for i in range(index + 1, 3):
        numbers[i] = 0
    value = ".".join(map(str, numbers))
    (root / "VERSION").write_text(value + "\n")
print(value)
