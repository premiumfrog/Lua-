#!/usr/bin/env python3
"""Runs every interpreter test: the repository's conformance suite and tests/unit, at O0-O2, in fast and debug mode.

Usage (from Interpreter/): python3 tests/run.py <luau> <luau-compile> [--levels 0,1,2] [--modes fast,debug]
Exits non-zero when any test fails. Conformance tests that fail natively under the CLI (they need C++ host
helpers) are skipped; tests/unit must pass natively and interpreted.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RUNNER = os.path.join(ROOT, "tools", "conformance.py")


def main() -> None:
    luau, compiler = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
    levels, modes = ["0", "1", "2"], ["fast", "debug"]
    rest = sys.argv[3:]
    while rest:
        if rest[0] == "--levels":
            levels, rest = rest[1].split(","), rest[2:]
        elif rest[0] == "--modes":
            modes, rest = rest[1].split(","), rest[2:]
        else:
            sys.exit(f"unknown option {rest[0]}")

    suites = [[], ["--dir", os.path.join(HERE, "unit"), "--strict"]]
    failed = []
    for level in levels:
        for mode in modes:
            for suite in suites:
                run = subprocess.run([sys.executable, RUNNER, luau, compiler, level, "--mode", mode, *suite], cwd=ROOT)
                if run.returncode != 0:
                    failed.append(f"{'unit' if suite else 'conformance'} O{level} {mode}")
    if failed:
        print("FAILED:", ", ".join(failed))
        sys.exit(1)
    print("all suites passed")


if __name__ == "__main__":
    main()
