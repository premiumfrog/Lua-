#!/usr/bin/env python3
"""Bundles the interpreter's src/ into one dependency-free Luau module (default: bundled/Interpreter.luau).

Usage (from anywhere):
    python3 tools/bundle.py                      bundle this checkout's src/
    python3 tools/bundle.py --github [REF]       download src/ from GitHub first (default ref: this branch)
    python3 tools/bundle.py --src DIR --out FILE bundle another source tree, or write elsewhere
    python3 tools/bundle.py --check              exit non-zero when the committed bundle is out of date

--repo OWNER/NAME picks the GitHub repository (default premiumfrog/Lua-). Set GITHUB_TOKEN for a private one.
Modules are found by scanning src/ and ordered by their requires; each becomes a local initialised by an inline
function, with its requires replaced by those locals and its exported types hoisted to the top of the file.
"""
import io
import os
import re
import sys
import tarfile
import tempfile
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = "premiumfrog/Lua-"
BRANCH = "claude/project-thread-p8h4y6"
REQUIRE = re.compile(r"^local (\w+) = require\(\"((?:@self|\.\.?)/[\w/]+)\"\)$")
# exported type names that would collide once hoisted, renamed module-qualified
RENAMES = {("Env", "State"): "EnvState"}


def fetch(repo, ref, into):
    """Downloads repo@ref and returns the path of its interpreter src/ (repository root or Interpreter/)."""
    url = f"https://api.github.com/repos/{repo}/tarball/{ref}"
    request = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json"})
    if os.environ.get("GITHUB_TOKEN"):
        request.add_header("Authorization", f"Bearer {os.environ['GITHUB_TOKEN']}")
    with urllib.request.urlopen(request) as response:
        data = response.read()
    with tarfile.open(fileobj=io.BytesIO(data)) as tar:
        members = [m for m in tar.getmembers() if re.match(r"^[^/]+/(Interpreter/)?src/", m.name)]
        if not members:
            sys.exit(f"{repo}@{ref} has no src/ or Interpreter/src/")
        tar.extractall(into, members=members, filter="data")
    top = os.path.join(into, os.listdir(into)[0])
    nested = os.path.join(top, "Interpreter", "src")
    return nested if os.path.isdir(nested) else os.path.join(top, "src")


def modules(src):
    """Module name ("Ops/Values", "init") -> source text, for every .luau file under src."""
    found = {}
    for folder, _, files in os.walk(src):
        for file in files:
            if file.endswith(".luau"):
                path = os.path.join(folder, file)
                name = os.path.relpath(path, src)[: -len(".luau")].replace(os.sep, "/")
                found[name] = open(path, encoding="utf-8").read()
    if "init" not in found:
        sys.exit(f"{src} has no init.luau")
    return found


def resolve(module, path):
    """Module a require path names, relative to the requiring module (init's @self is src/ itself)."""
    parts = module.split("/")[:-1]
    for part in path.split("/"):
        if part == "@self":
            parts = []
        elif part == "..":
            parts = parts[:-1]
        elif part != ".":
            parts.append(part)
    return "/".join(parts)


def order(found):
    """Modules in dependency order (dependencies first), ties broken by name for a stable output."""
    deps = {m: [] for m in found}
    for m, text in found.items():
        for line in text.split("\n"):
            match = REQUIRE.match(line)
            if match:
                target = resolve(m, match.group(2))
                if target not in found:
                    sys.exit(f"{m}: require of missing module {target}")
                deps[m].append(target)
    result, state = [], {}

    def visit(m):
        if state.get(m) == "done":
            return
        if state.get(m) == "active":
            sys.exit(f"require cycle through {m}")
        state[m] = "active"
        for d in sorted(deps[m]):
            visit(d)
        state[m] = "done"
        result.append(m)

    for m in sorted(found, key=lambda m: (m == "init", m)):
        visit(m)
    return result, deps


def var(name):
    return "Module_" + name.split("/")[-1]


def split_type(lines, i):
    """Returns the end index (exclusive) of the type declaration starting at line i."""
    depth, j = 0, i
    while True:
        depth += lines[j].count("{") + lines[j].count("(") - lines[j].count("}") - lines[j].count(")")
        j += 1
        if depth <= 0:
            return j


def exports(text):
    return re.findall(r"^export type (\w+)", text, re.M)


def type_only(text):
    """Whether a module only declares types (it returns nil and has no runtime code)."""
    lines = [l for l in text.split("\n") if l.strip() and not l.lstrip().startswith("--")]
    code, depth = [], 0
    for l in lines:
        if depth == 0 and not l.startswith("export type"):
            code.append(l.strip())
        if l.startswith("export type") or depth > 0:
            depth += l.count("{") + l.count("(") - l.count("}") - l.count(")")
    return code in (["return nil"], [])


def bundle(src):
    found = modules(src)
    ordered, _ = order(found)
    names = {}
    for m in ordered:
        if len({var(o) for o in ordered if var(o) == var(m)}) > 1:
            sys.exit(f"two modules named {m.split('/')[-1]}")
        for t in exports(found[m]):
            names[(m, t)] = RENAMES.get((m.split("/")[-1], t), t)

    types, bodies = [], []
    for m in ordered:
        text = found[m]
        aliases = {}
        for line in text.split("\n"):
            match = REQUIRE.match(line)
            if match:
                aliases[match.group(1)] = resolve(m, match.group(2))
        # Alias.Type -> hoisted name, for the types each required module exports
        for alias, target in aliases.items():
            for t in exports(found[target]):
                text = re.sub(rf"\b{alias}\.{t}\b", names[(target, t)], text)
        for t in exports(found[m]):
            if names[(m, t)] != t:
                text = re.sub(rf"\b{t}\b", names[(m, t)], text)
        hoisted = set(names.values())
        lines = text.split("\n")
        body, i = [], 0
        while i < len(lines):
            line = lines[i]
            match = REQUIRE.match(line)
            if line.startswith("--!"):
                i += 1
            elif match:
                target = resolve(m, match.group(2))
                if not type_only(found[target]):
                    body.append(f"local {match.group(1)} = {var(target)}")
                i += 1
            elif re.match(r"^type (\w+) = \w+$", line) and line.split()[1] in hoisted and line.split()[3] in hoisted:
                i += 1  # local alias of a hoisted type ("type Proto = Proto")
            elif line.startswith("export type "):
                end = split_type(lines, i)
                decl = "\n".join(lines[i:end])
                alias = re.match(r"^export type (\w+) = (\w+)$", decl)
                if not (alias and alias.group(2) in hoisted):  # re-exports of hoisted types are dropped
                    types.append(decl)
                i = end
            else:
                body.append(line)
                i += 1
        while body and not body[0].strip():
            body.pop(0)
        code = "\n".join(body).rstrip()
        if type_only(found[m]):
            continue
        code = "\n".join(("\t" + l) if l.strip() else "" for l in code.split("\n"))
        bodies.append(f"-- {m}.luau\nlocal {var(m)} = (function()\n{code}\nend)()\n")

    doc = []
    for line in found["init"].split("\n")[2:]:
        if not line.startswith("--"):
            if doc:
                break
            continue
        doc.append(line)
    return "\n".join(["--!optimize 2", "--!strict", ""] + doc + [
        "--",
        "-- This file is the whole interpreter, generated from src/ by tools/bundle.py: each section below is one module, in",
        "-- dependency order. Edit src/ and regenerate rather than editing this file.",
        "",
        "\n\n".join(types),
        "",
        "\n".join(bodies),
        "return Module_init",
        "",
    ])


def main():
    args = sys.argv[1:]
    src, out, repo, ref, check = os.path.join(ROOT, "src"), os.path.join(ROOT, "bundled", "Interpreter.luau"), REPO, None, False
    while args:
        arg = args.pop(0)
        if arg == "--src":
            src = os.path.abspath(args.pop(0))
        elif arg == "--out":
            out = os.path.abspath(args.pop(0))
        elif arg == "--repo":
            repo = args.pop(0)
        elif arg == "--github":
            ref = args.pop(0) if args and not args[0].startswith("--") else BRANCH
        elif arg == "--check":
            check = True
        else:
            sys.exit(__doc__)
    with tempfile.TemporaryDirectory() as tmp:
        if ref is not None:
            src = fetch(repo, ref, tmp)
        result = bundle(src)
    if check:
        current = open(out, encoding="utf-8").read() if os.path.exists(out) else ""
        if current != result:
            sys.exit(f"{os.path.relpath(out)} is out of date: run python3 tools/bundle.py")
        print(f"{os.path.relpath(out)} is up to date")
        return
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write(result)
    print(f"wrote {out} ({result.count(chr(10))} lines, from {src if ref is None else repo + '@' + ref})")


if __name__ == "__main__":
    main()
