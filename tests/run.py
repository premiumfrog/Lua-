#!/usr/bin/env python3
"""Runs every interpreter test: Luau's conformance suite and tests/unit, at O0-O2, in fast and debug mode.

Usage (from the repository root):
    python3 tests/run.py <luau> <luau-compile> [--luau-source <dir>] [--levels 0,1,2] [--modes fast,debug]
    [--builds src,bundled]
--builds picks the interpreter under test: the modular src/, the single-file bundled/Interpreter.luau, or both.
--luau-source is the Luau checkout whose tests/conformance runs (default: $LUAU_SOURCE, else ./luau).
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
    levels, modes, builds = ["0", "1", "2"], ["fast", "debug"], ["src", "bundled"]
    rest = sys.argv[3:]
    while rest:
        if rest[0] == "--levels":
            levels, rest = rest[1].split(","), rest[2:]
        elif rest[0] == "--modes":
            modes, rest = rest[1].split(","), rest[2:]
        elif rest[0] == "--builds":
            builds, rest = rest[1].split(","), rest[2:]
        elif rest[0] == "--luau-source":
            os.environ["LUAU_SOURCE"], rest = os.path.abspath(rest[1]), rest[2:]
        else:
            sys.exit(f"unknown option {rest[0]}")

    suites = [[], ["--dir", os.path.join(HERE, "unit"), "--strict"]]
    failed = []
    for level in levels:
        for mode in modes:
            for build in builds:
                for suite in suites:
                    run = subprocess.run([sys.executable, RUNNER, luau, compiler, level, "--mode", mode, "--build", build,
                                          *suite], cwd=ROOT)
                    if run.returncode != 0:
                        failed.append(f"{'unit' if suite else 'conformance'} O{level} {mode} {build}")
    if failed:
        print("FAILED:", ", ".join(failed))
        sys.exit(1)
    print("all suites passed")


if __name__ == "__main__":
    main()
