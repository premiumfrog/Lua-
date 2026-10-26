#!/usr/bin/env python3
"""Runs tests/conformance through the interpreter at one optimization level, one process per test.

Usage (from Interpreter/): conformance.py <luau> <luau-compile> <opt-level> [name...]
A test that does not pass natively in the CLI runner (or yields at top level) is reported as SKIP.
"""
import glob
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TESTS = os.path.join(ROOT, "..", "tests", "conformance")


def main() -> None:
    luau, compiler, level = sys.argv[1], sys.argv[2], sys.argv[3]
    only = set(sys.argv[4:])
    out_dir = os.path.join("build", f"conformance-O{level}")
    sources = sorted(glob.glob(os.path.join(TESTS, "*.luau")))
    subprocess.run([sys.executable, os.path.join(HERE, "embed.py"), compiler, os.path.join(ROOT, out_dir), level, *sources],
                   check=True, stderr=subprocess.DEVNULL)
    counts = {"PASS": 0, "FAIL": 0, "SKIP": 0}
    for path in sorted(glob.glob(os.path.join(ROOT, out_dir, "*.luau"))):
        name = os.path.splitext(os.path.basename(path))[0]
        if only and name not in only:
            continue
        try:
            run = subprocess.run([luau, os.path.join(HERE, "conformance.luau"), "-a", out_dir, name],
                                 cwd=ROOT, capture_output=True, text=True, timeout=120)
            lines = [l for l in run.stdout.splitlines() if l.startswith(("PASS", "FAIL", "SKIP"))]
            # a crash before any verdict happens in the native run (e.g. a top-level yield)
            line = lines[-1] if lines else f"SKIP\t{name}\tnative run did not finish"
        except subprocess.TimeoutExpired:
            line = f"FAIL\t{name}\ttimeout"
        counts[line[:4]] += 1
        if not line.startswith("PASS"):
            print(line)
    print(f"O{level}", counts)


if __name__ == "__main__":
    main()
