# Luau bytecode interpreter in Luau

This interpreter runs Luau bytecode (versions 3 to 14, type version 3) on any Luau host, including Roblox. It loads the
bytecode once and turns it into graphs of host closures, so running it involves no opcode dispatch. It is a rework of the
handler-closure design used by [vantoanvh/LuauVM](https://github.com/vantoanvh/LuauVM), and it is faster on all
17 workloads in the benchmark suite (1.38x geometric mean).

```luau
local Interpreter = require(path.to.Interpreter.src)

local main = Interpreter.Load(bytecode, getfenv(), {
	SafeEnv = true, -- resolve imports such as math.floor once, at load time (default)
	ChunkName = "[string \"MyChunk\"]", -- error()/assert() and method-call errors get "MyChunk:line:" positions
})
print(main(...))
```

`bytecode` is the output of `luau-compile --binary` or `luau_compile`, as a string or a buffer. Line positions need
line info, so compile with `-g1`. `Interpreter.Deserialize` exposes the parser for tooling.

## Layout

| Module | Responsibility |
| --- | --- |
| `init` | Public API: `Load` and `Deserialize` |
| `Deserializer` | Bytecode parsing into protos (constants, imports, children, line info) |
| `Analysis` | Per-proto control flow and dataflow analysis, producing the plan the compiler builds from |
| `Compiler` | Maps every planned instruction to its handler maker, back to front |
| `Runtime` | Frame pools, the function trampoline, the return protocol and upvalue cells |
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

To reproduce, run these from `Interpreter/`. The `--ref` option takes any module exposing `Load(bytecode, env)`.

```sh
python3 tools/embed.py luau-compile build/bench 2 bench/workloads/*.luau
luau -O2 tools/bench.luau -a build/bench fib nbody sort --ref build/RefVM
```

## Conformance

`tools/conformance.py <luau> <luau-compile> <level>` runs `tests/conformance` through the interpreter, one process per
test. Tests that fail natively in the CLI runner are skipped. These include tests that need a writable global table,
the C test API, or a top-level yield. At O0, O1 and O2, 25 tests pass and these 4 fail:

* `events` and `locals` use `getfenv`/`setfenv` on interpreted functions.
* `tmerror` expects a position on an error raised by the host itself ("attempt to call a nil value").
* `calls` overflows memory instead of reporting "too many results to unpack" for 19000 nested calls with 4000
  arguments each.

## Limitations

* `getfenv`/`setfenv` on interpreted functions do not affect the environment they captured at load.
* Errors raised by the host inside handlers, such as arithmetic on nil or calling a nil value, carry the handler's
  position rather than the guest line. Guest `error()` (level 1), `assert()` and missing methods are positioned when a
  `ChunkName` is given and the call site can be traced to an import, which covers O1 and O2 bytecode. At O0 the
  compiler loads `error` and `assert` with `GETGLOBAL`, and those calls are unpositioned.
* `error(message, 2)` and higher levels raise the message without a position.
* Bytecode classes (`NEWCLASSMEMBER`) are rejected at load time.
* With `SafeEnv` (the default), imports that resolve at load time are fixed. Turn `SafeEnv` off when globals are
  replaced after loading.
* Each proto keeps up to 17 frames for reuse, which can hold stale register values until they are reused.

## Tools

* `tools/embed.py` compiles sources and embeds them as Luau modules for the drivers.
* `tools/gen_fused.py` regenerates `src/Ops/Fused.luau`.
* `tools/bench.luau` is the benchmark driver.
* `tools/conformance.py` and `tools/conformance.luau` are the conformance runner.
