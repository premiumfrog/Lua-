#!/usr/bin/env python3
"""Compiles Luau sources to bytecode and embeds them as Luau modules for the test and benchmark drivers.

Usage: embed.py <luau-compile> <out-dir> <opt-level> <file>...
Each <file> becomes <out-dir>/<stem>.luau returning { Source = string, Bytecode = string }.
"""
import os
import subprocess
import sys


def quote(data: bytes) -> str:
    out = []
    for b in data:
        if 32 <= b < 127 and b not in (34, 92):
            out.append(chr(b))
        else:
            out.append("\\x%02x" % b)
    return '"' + "".join(out) + '"'


def main() -> None:
    compiler, out_dir, level = sys.argv[1], sys.argv[2], sys.argv[3]
    os.makedirs(out_dir, exist_ok=True)
    for path in sys.argv[4:]:
        source = open(path, "rb").read()
        result = subprocess.run([compiler, "--binary", f"-O{level}", "-g1", path], capture_output=True)
        if result.returncode != 0:
            print(f"skipped {path}: does not compile", file=sys.stderr)
            continue
        bytecode = result.stdout
        stem = os.path.splitext(os.path.basename(path))[0]
        with open(os.path.join(out_dir, stem + ".luau"), "w") as f:
            f.write("return { Source = %s, Bytecode = %s }\n" % (quote(source), quote(bytecode)))


if __name__ == "__main__":
    main()
