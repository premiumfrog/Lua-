#!/usr/bin/env python3
"""Runs tests/conformance through the interpreter at one optimization level, one process per test.

Usage (from the repository root):
    conformance.py <luau> <luau-compile> <opt-level> [--mode fast|debug] [--build src|bundled] [--dir <tests>] [--strict] [name...]
--dir runs another directory of tests (default: tests/conformance of the Luau checkout in $LUAU_SOURCE or ./luau). --strict reports a test that
fails natively as FAIL instead of SKIP, for suites written to pass on any host (tests/unit).
"debug" loads with the Debug option (host-raised error positions, host-exact GC liveness); "fast" is the default
configuration, where tests observing those differences are expected to fail (see EXPECTED_FAST).
A test that does not pass natively in the CLI runner (or yields at top level) is reported as SKIP.
"""
import glob
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
# Luau's conformance suite: a Luau source checkout at $LUAU_SOURCE, or ./luau
TESTS = os.path.join(os.environ.get("LUAU_SOURCE", os.path.join(ROOT, "luau")), "tests", "conformance")

# Tests that observe what only Debug mode reproduces: collection of values the guest no longer references while
# chained handlers are still running (closure). Not run in fast mode.
NEEDS_DEBUG = {"closure"}

# Tests for features behind fast flags, as tests/Conformance.test.cpp enables them; passed to compiler and runtime.
FFLAGS = {
    "classes": "DebugLuauUserDefinedClasses=true,DebugLuauUserDefinedClassesRuntime=true,"
               "LuauEmitCallFeedback=true,LuauBytecodeCostModel=true",
}


def main() -> None:
    luau, compiler, level = sys.argv[1], sys.argv[2], sys.argv[3]
    rest = sys.argv[4:]
    mode, build, tests, strict = "debug", "src", TESTS, False
    while rest and rest[0].startswith("--"):
        if rest[0] == "--mode":
            mode, rest = rest[1], rest[2:]
        elif rest[0] == "--build":
            build, rest = rest[1], rest[2:]
        elif rest[0] == "--dir":
            tests, rest = os.path.abspath(rest[1]), rest[2:]
        elif rest[0] == "--strict":
            strict, rest = True, rest[1:]
        else:
            sys.exit(f"unknown option {rest[0]}")
    only = set(rest)
    suite = os.path.basename(os.path.normpath(tests))
    out_dir = os.path.join("build", f"{suite}-O{level}")
    sources = sorted(glob.glob(os.path.join(tests, "*.luau")))
    debug_only = {os.path.splitext(os.path.basename(p))[0] for p in sources
                  if "-- interpreter: debug-only" in open(p, encoding="utf-8", errors="replace").read()}
    for stale in glob.glob(os.path.join(ROOT, out_dir, "*.luau")):
        os.remove(stale)
    flagged = [p for p in sources if os.path.splitext(os.path.basename(p))[0] in FFLAGS]
    plain = [p for p in sources if p not in flagged]
    embed = [sys.executable, os.path.join(HERE, "embed.py"), compiler, os.path.join(ROOT, out_dir), level]
    subprocess.run([*embed, *plain], check=True, stderr=subprocess.DEVNULL)
    for path in flagged:
        name = os.path.splitext(os.path.basename(path))[0]
        subprocess.run([*embed, f"--fflags={FFLAGS[name]}", path], check=True, stderr=subprocess.DEVNULL)
    counts = {"PASS": 0, "FAIL": 0, "SKIP": 0}
    for path in sources:
        name = os.path.splitext(os.path.basename(path))[0]
        if only and name not in only:
            continue
        if not os.path.exists(os.path.join(ROOT, out_dir, name + ".luau")):
            line = f"{'FAIL' if strict else 'SKIP'}\t{name}\tdoes not compile"
            counts[line[:4]] += 1
            print(line)
            continue
        if mode == "fast" and (name in NEEDS_DEBUG or name in debug_only):
            counts["SKIP"] += 1
            continue
        try:
            flags = [f"--fflags={FFLAGS[name]}"] if name in FFLAGS else []
            run = subprocess.run([luau, *flags, os.path.join(HERE, "conformance.luau"), "-a", out_dir, name, mode, build],
                                 cwd=ROOT, capture_output=True, text=True, timeout=120)
            lines = [l for l in run.stdout.splitlines() if l.startswith(("PASS", "FAIL", "SKIP"))]
            # a crash before any verdict happens in the native run (e.g. a top-level yield)
            line = lines[-1] if lines else f"SKIP\t{name}\tnative run did not finish"
            if strict and line.startswith("SKIP"):
                line = "FAIL" + line[4:] + " (fails natively)"
        except subprocess.TimeoutExpired:
            line = f"FAIL\t{name}\ttimeout"
        counts[line[:4]] += 1
        if not line.startswith("PASS"):
            print(line)
    print(f"{suite} O{level} {mode} {build}", counts)
    sys.exit(1 if counts["FAIL"] else 0)


if __name__ == "__main__":
    main()
