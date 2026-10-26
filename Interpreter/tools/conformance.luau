-- Runs one embedded conformance test natively and on the interpreter; prints PASS, FAIL or SKIP.
-- Each run gets the environment tests/Conformance.test.cpp gives a test: a fresh writable global table over the
-- standard libraries, _G pointing at it, and loadstring producing functions in that table.
-- A test that still fails natively needs C++ host features (see README) and is skipped.
--
-- Interpreter tests (tests/unit) may carry markers in their source:
--   "-- interpreter: unsafe-env"  load with SafeEnv off (the test replaces globals after loading)
--   "-- interpreter: debug-only"  only meaningful with the Debug option (the driver script skips it in fast mode)
--
-- Usage: luau tools/conformance.luau -a <embedded-dir> <name> <fast|debug> [verbose]

local Interpreter = require("../src")

local dir, name, mode, verbose = ...
local w = (require :: any)("../" .. dir .. "/" .. name)
local chunkName = name .. ".luau"
local hostLoadstring = loadstring
local hostGlobals = getfenv()

-- Fresh global table for one run, like luaL_sandboxthread.
local function Env(): { [any]: any }
	local env = setmetatable({}, { __index = hostGlobals })
	env._G = env
	env.print = if verbose then print else function() end
	-- codegen probes: neither run here compiles natively, so the tests' semantic checks run as plain bytecode
	env.is_native = function()
		return true
	end
	env.is_native_if_supported = function()
		return true
	end
	env.loadstring = function(source: string, chunk: string?)
		local fn, err = hostLoadstring(source, chunk)
		if fn then
			setfenv(fn, getfenv(0)) -- luau_load with env 0: the calling thread's globals
		end
		return fn, err
	end
	return env
end

-- Runs a test body on its own thread whose globals are env, as luaL_sandboxthread gives each test.
local function RunSandboxed(fn: () -> any, env: { [any]: any }): (boolean, any)
	local co = coroutine.create(function()
		setfenv(0, env)
		return fn()
	end)
	local ok, result = coroutine.resume(co)
	if ok and coroutine.status(co) ~= "dead" then
		return false, "test yielded at top level"
	end
	return ok, result
end

local nativeEnv = Env()
local native = hostLoadstring(w.Source, "=" .. chunkName)
setfenv(native :: any, nativeEnv)
local okN, rN = RunSandboxed(native :: any, nativeEnv)
if not okN or rN ~= "OK" then
	print("SKIP", name, (tostring(rN):gsub("\n", " ")):sub(1, 120))
	return
end

-- Tests touching environments run with DynamicEnv, the opt-in getfenv/setfenv support.
local dynamic = string.find(w.Source, "fenv", 1, true) ~= nil
-- Interpreted calls use heap frames, so memory-exhaustion stress runs out of memory, not stack: the test suite's
-- limitedstack flag (set natively for ASAN/debug builds) covers exactly this.
local guestEnv = Env()
guestEnv.limitedstack = true
local safeEnv = string.find(w.Source, "-- interpreter: unsafe-env", 1, true) == nil
local okL, f = pcall(Interpreter.Load, w.Bytecode, guestEnv, {
	ChunkName = chunkName,
	SafeEnv = safeEnv,
	DynamicEnv = dynamic,
	Debug = mode == "debug",
})
if not okL then
	print("FAIL", name, "load: " .. tostring(f):sub(1, 200))
	return
end
local okV, rV = RunSandboxed(f, guestEnv)
if okV and rV == "OK" then
	print("PASS", name)
else
	print("FAIL", name, (tostring(rV):gsub("\n", " ")):sub(1, 200))
end
