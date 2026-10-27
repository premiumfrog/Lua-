# Luau bytecode interpreter in Luau

This interpreter runs Luau bytecode (versions 3 to 14 and the experimental class version 100, type version 3) on any Luau host, including Roblox. It loads the
bytecode once and turns it into graphs of host closures, so running it involves no opcode dispatch. It is a rework of the
handler-closure design used by [vantoanvh/LuauVM](https://github.com/vantoanvh/LuauVM), and it is faster on all
17 workloads in the benchmark suite (1.38x geometric mean).

```luau
local Interpreter = require(path.to.Interpreter) -- src/ as a folder of modules, or bundled/Interpreter.luau

local main = Interpreter.Load(bytecode, getfenv(), {
	SafeEnv = true, -- resolve imports such as math.floor once, at load time (default)
	ChunkName = "[string \"MyChunk\"]", -- error()/assert() and method-call errors get "MyChunk:line:" positions
	DynamicEnv = nil, -- per-closure environments with getfenv/setfenv (default: on when the chunk uses them)
	Debug = false, -- positions on every error leaving a guest function, exact collection timing (default off)
})
print(main(...))
```

### Options

| Option | Default | Effect |
| --- | --- | --- |
| `SafeEnv` | `true` | Imports such as `math.floor` resolve once at load. Turn it off when globals are replaced after loading. |
| `ChunkName` | none | Prefix for guest error positions (`name:line:`). |
| `DynamicEnv` | automatic | Every closure carries its own environment. Guest code gets `getfenv`/`setfenv` with the host's semantics: numeric levels, function targets, level 0 as the thread's globals, the host's error messages, and imports re-resolving once an environment has been exposed. It turns on by itself when the chunk names `getfenv` or `setfenv`. Pass `false` to keep it off, `true` to force it, or a state from `Interpreter.NewEnvState()` to share one between chunks. |
| `Debug` | `false` | Every error leaving a guest function gets its guest position, including errors a host callback (an event connection, a scheduler) catches, and no handler keeps a value alive after the guest stops referencing it, so weak tables clear exactly as they do natively. It returns to a trampoline after every instruction and tracks the current instruction, which makes the benchmark workloads 1.6 to 1.9 times slower. |

`bytecode` is the output of `luau-compile --binary` or `luau_compile`, as a string or a buffer. Line positions need
line info, so compile with `-g1`. `Interpreter.Deserialize` exposes the parser for tooling.

## Layout

The interpreter ships in two equivalent forms:

* `src/` is the source: one module per responsibility (table below). Use it as a ModuleScript tree, with `init` as
  the parent.
* `bundled/Interpreter.luau` is the entire interpreter in one dependency-free file, generated from `src/` by
  `python3 tools/bundle.py`. Drop it into a single ModuleScript. Edit `src/` and regenerate; CI fails when the bundle
  is out of date, and the test matrix runs against both forms.

| Module | Responsibility |
| --- | --- |
| `init` | Public API: `Load`, `NewEnvState` and `Deserialize` |
| `Deserializer` | Bytecode parsing into protos (constants, imports, children, line info) |
| `Analysis` | Per-proto control flow and dataflow analysis, producing the plan the compiler builds from |
| `Compiler` | Maps every planned instruction to its handler maker, back to front |
| `Runtime` | Frame pools, the function trampoline, the return protocol and upvalue cells |
| `Classes` | Luau classes: class values, instances, inheritance, private members and the `class` library |
| `Env` | `DynamicEnv` state (VM-aware `getfenv`/`setfenv`) and the guest view of the host stack: handler registry, guest frames, error repositioning |
| `Builtins` | Stack-aware replacements guest code sees: `pcall`, `xpcall`, coroutine and `task` bodies, `debug.info`, `debug.traceback` |
| `Ops/*` | Handler makers grouped by kind: values, arithmetic, tables, calls, branches, loops, closures |
| `Ops/Fused` | Generated handlers for hot instruction pairs (`tools/gen_fused.py`) |

## How it executes

Each live instruction becomes one closure with its operands captured as upvalues. A handler either calls its successor
directly (chaining) or returns it to the nearest trampoline. Loops run as real host loops:

* `FORNPREP`/`FORNLOOP` and `FORGPREP*`/`FORGLOOP` become host `for` statements. Generic loops keep the host's `next`,
  `ipairs` and `__iter` fast paths.
* Every other backward jump closes a "back loop" whose header restarts the body when the body returns the loop's token.

Analysis removes work before any handler exists:

* **Folding.** Loads that only feed a call, such as constants, resolved imports, register copies and the callee
  upvalue, are folded into the call, so `math.floor(x)` runs as one handler. Constants live in slots in front of the
  registers, so a folded constant is read like a register. The same applies to the setup operands of numeric loops and
  to constant operands of compares (`n < 2`), where a bounded liveness check proves the temporary dead.
* **Method calls.** `NAMECALL` is folded into its `CALL`, and `select(i, ...)` indexes the vararg table directly.
* **Fusion.** `x = a < b` and `return a > b` become one handler that stores or returns the condition. Hot adjacent
  pairs share one handler, such as field load into arithmetic, arithmetic into a field store, chained arithmetic,
  upvalue indexing, and a value tested by the next branch (`if t.x then`, `if i % 3 == 0 then`).
* **Calls.** A call is a plain host call to a host closure, so pcall, coroutines and host callbacks behave natively.
  Each proto has a frame pool, the factory has fixed-arity and vararg entries, and tail calls run in the factory's
  tail position, so deep tail recursion uses no extra host stack.

## Benchmarks

The table below compares times for O2 bytecode, best of 7 runs on the Luau CLI. "native" is the host running the same
source. Speedup is against the reference VM.

| Workload | native | this VM | reference | speedup |
| --- | ---: | ---: | ---: | ---: |
| array | 19.5 ms | 142.9 ms | 243.2 ms | 1.70x |
| binary_trees | 16.1 ms | 131.1 ms | 160.0 ms | 1.22x |
| builtins | 18.9 ms | 245.1 ms | 328.2 ms | 1.34x |
| closures | 13.9 ms | 141.2 ms | 157.5 ms | 1.12x |
| coroutines | 10.7 ms | 27.4 ms | 50.4 ms | 1.84x |
| fib | 5.0 ms | 56.6 ms | 68.2 ms | 1.20x |
| fields | 27.7 ms | 261.1 ms | 345.1 ms | 1.32x |
| iterate | 5.7 ms | 66.7 ms | 100.4 ms | 1.50x |
| nbody | 74.3 ms | 925.0 ms | 1156.2 ms | 1.25x |
| numeric_loop | 58.9 ms | 342.7 ms | 420.0 ms | 1.23x |
| oop | 80.0 ms | 641.4 ms | 913.5 ms | 1.42x |
| queens | 12.4 ms | 89.3 ms | 110.9 ms | 1.24x |
| sieve | 22.8 ms | 142.8 ms | 234.7 ms | 1.64x |
| sort | 50.0 ms | 193.8 ms | 238.9 ms | 1.23x |
| strings | 27.8 ms | 76.4 ms | 101.0 ms | 1.32x |
| varargs | 18.6 ms | 263.6 ms | 462.2 ms | 1.75x |
| while_loop | 41.3 ms | 314.4 ms | 421.9 ms | 1.34x |

To reproduce, run these from the repository root with a built Luau (see Tests). The `--ref` option takes any module exposing `Load(bytecode, env)`.

```sh
python3 tools/embed.py luau-compile build/bench 2 bench/workloads/*.luau
luau -O2 tools/bench.luau -a build/bench fib nbody sort --ref build/RefVM
```

## Tests

The tests need the Luau CLI and compiler, plus a Luau source checkout for `tests/conformance`:

```sh
git clone https://github.com/premiumfrog/Lua- --branch master luau
make -C luau -j4 config=release luau luau-compile
python3 tests/run.py luau/luau luau/luau-compile --luau-source luau
```

`tests/run.py` runs everything at O0, O1 and O2, in the default (fast) configuration and with `Debug`, against both
`src/` and the bundle (`--builds src,bundled`). CI runs it on every change (`.github/workflows/interpreter.yml`).

* **Conformance.** Luau's own `tests/conformance` suite (from `--luau-source`, or `$LUAU_SOURCE`), run natively and through the interpreter in the
  environment `tests/Conformance.test.cpp` gives each test: its own thread with fresh writable globals, `loadstring`
  bound to the thread's globals, and `limitedstack` set (interpreted calls keep their frames on the heap, so deep
  recursion stress runs out of memory rather than stack, like the ASAN and debug builds the flag exists for). Tests
  using `getfenv`/`setfenv` turn on `DynamicEnv` by themselves, and `classes` is compiled and run with the class fast flags
  `Conformance.test.cpp` sets. All 38 tests that run natively under the CLI pass at every level with `Debug`. In the
  fast configuration, `closure` (weak-table collection timing) is not run, and the other 37 pass.
* **Skipped conformance tests.** 18 tests fail natively under the CLI because they need the C++ test host: native
  code generation, userdata and light userdata constructors, coverage and debugger hooks, `collectgarbage` options,
  or running on the main thread. `jit_inliner` needs a compiler flag for the native inliner.
* **Interpreter tests.** `tests/unit` covers what the interpreter rewrites: environments, error positions, collection
  timing, the guest view of the stack (`stack`), coroutines, metamethods and host callbacks, control flow, calls and varargs, globals and values. Each test
  must pass natively too, so it only checks real Luau behavior. A `-- interpreter: debug-only` line limits a test to
  `Debug`, and `-- interpreter: unsafe-env` loads it with `SafeEnv` off.

`tools/conformance.py` runs one suite at one level (`--mode fast|debug`, `--build src|bundled`, `--dir`, `--strict`,
test names).

## Guest view of the stack

On the host stack a guest function is an interpreter closure running handlers. Every handler is registered with its
instruction and the closures factories make are recognisable by their definition site, so walking the host stack with
`debug.info` recovers the guest frames and the instruction each is running. Nothing is tracked while code runs; the
walk happens only when guest code catches an error or inspects the stack:

* **Error positions.** `pcall`, `xpcall`, coroutine bodies (`coroutine.create`/`wrap`, Roblox's `task.spawn`/`defer`/
  `delay`) and the main function catch with an xpcall handler, which runs while the faulting handler is still on the
  stack and rewrites an interpreter position ("Interpreter:812: attempt to index nil with 'x'") to the guest line.
  Coroutines pay this once when they start, not per resume.
* **`error(message, level)`** at level 2 and above gets the position of that guest-visible level.
* **`debug.info(level, ...)`** and **`debug.traceback`** count and describe guest frames (source, current line,
  name, function, arity) in the host's format, for the running thread and for other coroutines.

These are swapped in where guest code reads the builtins, at load for imports and per read for other globals.

## Limitations

* An error that escapes a guest function into a host callback the interpreter does not wrap (an event connection,
  `table.sort`'s comparator, a metamethod the host calls) keeps the interpreter position unless `Debug` is on, since
  no guest catch point sees it.
* Guest calls nest two host frames each (the function and the handler that called it), so the host's call depth
  limit (about 20000 frames) allows about 10000 guest levels, or about 3300 with `Debug`.
* A function that is returning a call (`return f(x)`) has handed control to its factory, so while the call runs it
  appears in `debug.info`/`debug.traceback` without a source line. `debug.info(f, ...)` on an interpreted function
  value describes the interpreter's closure; levels describe the guest.
* A stack overflow inside nested guest `pcall`s may report "error in error handling" (the host leaves no room to call
  the repositioning handler).
* Class values and instances are tables behind protected metatables, because Luau code cannot create new value
  types. In class chunks, `type`, `typeof` and `getmetatable` are swapped for class-aware versions and `class` is
  the interpreter's own library, so guest code sees `"class"`/`"object"` and the host's error messages. Raw access
  (`rawget`, `next`) and the default `tostring` address differ from the host's.
* With `SafeEnv` (the default) imports resolve once at load, as the host does for a safe environment. Turn it off
  when guest globals such as `math` are replaced after loading.
* Each proto keeps up to 17 frames for reuse, which can hold stale register values until they are reused.

## Tools

* `tools/embed.py` compiles sources and embeds them as Luau modules for the drivers.
* `tools/gen_fused.py` regenerates `src/Ops/Fused.luau`.
* `tools/bundle.py` regenerates `bundled/Interpreter.luau` from `src/`. It works from any directory, finds the
  modules and their order from the requires, and takes `--github [REF]` to download the source from GitHub first
  (`--repo`, `GITHUB_TOKEN` for private repositories), `--src`/`--out` for other paths, and `--check` for CI.
* `tools/bench.luau` is the benchmark driver.
* `tools/conformance.py` and `tools/conformance.luau` run one test suite; `tests/run.py` runs all of them.
