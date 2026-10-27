#!/usr/bin/env python3
"""Bundles src/ into bundled/Interpreter.luau: the whole interpreter as one dependency-free module.

Usage (from the repository root): python3 tools/bundle.py [--check]
Each module becomes a local initialised by an inline function, in dependency order, with its requires replaced by those
locals and its exported types hoisted to the top. --check exits non-zero when the committed bundle is out of date.
"""
import os
import re
import sys

ORDER = ["Types", "Runtime", "Env", "Classes", "Deserializer", "Analysis", "Ops/Values", "Ops/Arith", "Ops/Tables",
         "Ops/Calls", "Ops/Branches", "Ops/Loops", "Ops/Closures", "Ops/Fused", "Ops/Objects", "Compiler", "init"]
TYPES = "Proto|Chunk|Frame|Handler|Factory|Options|Loop|Edge|CallPlan|Bool|Program"


def var(name):
    return "Module_" + name.replace("Ops/", "")


def split_type(lines, i):
    """Returns the end index (exclusive) of the type declaration starting at line i."""
    depth = 0
    j = i
    while True:
        depth += lines[j].count("{") + lines[j].count("(") - lines[j].count("}") - lines[j].count(")")
        j += 1
        if depth <= 0:
            return j


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main():
    src, out = os.path.join(ROOT, "src"), os.path.join(ROOT, "bundled", "Interpreter.luau")
    types, bodies = [], []
    for mod in ORDER:
        text = open(os.path.join(src, mod + ".luau")).read()
        text = re.sub(rf"\b(Types|Analysis)\.({TYPES})\b", r"\2", text)
        text = text.replace("Env.State", "EnvState").replace("Classes.Class", "Class")
        if mod == "Env":
            text = re.sub(r"\bState\b", "EnvState", text)
        lines = text.split("\n")
        body = []
        i = 0
        while i < len(lines):
            line = lines[i]
            if line.startswith("--!"):
                i += 1
                continue
            m = re.match(r"^local (\w+) = require\(\"(?:@self/|\./|\.\./)([\w/]+)\"\)$", line)
            if m:
                target = m.group(2)
                target = target if target in ORDER else "Ops/" + target
                if target == "Types":
                    i += 1
                    continue
                body.append(f"local {m.group(1)} = {var(target)}")
                i += 1
                continue
            if re.match(rf"^type ({TYPES}|Class|EnvState) = \w+$", line) or re.match(rf"^type ({TYPES}) = \w+\.\w+$", line):
                i += 1
                continue
            if line.startswith("export type "):
                end = split_type(lines, i)
                decl = lines[i:end]
                if mod != "init":  # init only re-exports
                    types.append("\n".join(decl))
                i = end
                continue
            body.append(line)
            i += 1
        while body and body[0].strip() == "":
            body.pop(0)
        if mod == "Types":
            continue
        code = "\n".join(body).rstrip()
        code = "\n".join(("\t" + l) if l.strip() else "" for l in code.split("\n"))
        bodies.append(f"-- {mod}.luau\nlocal {var(mod)} = (function()\n{code}\nend)()\n")

    header = open(os.path.join(src, "init.luau")).read().split("\n")
    doc = []
    for line in header[2:]:
        if not line.startswith("--"):
            if doc:
                break
            continue
        doc.append(line)
    result = ["--!optimize 2", "--!strict", ""] + doc + [
        "--",
        "-- This file is the whole interpreter, generated from src/ by tools/bundle.py: each section below is one module, in",
        "-- dependency order. Edit src/ and regenerate rather than editing this file.",
        "",
        "\n\n".join(types),
        "",
        "\n".join(bodies),
        "return Module_init",
        "",
    ]
    bundle = "\n".join(result)
    if "--check" in sys.argv[1:]:
        current = open(out).read() if os.path.exists(out) else ""
        if current != bundle:
            sys.exit("bundled/Interpreter.luau is out of date: run python3 tools/bundle.py")
        return
    os.makedirs(os.path.dirname(out), exist_ok=True)
    open(out, "w").write(bundle)


main()
