--!strict

-- Guest-facing replacements for host builtins that observe the call stack: pcall, xpcall, coroutine.create,
-- coroutine.wrap, task.spawn/defer/delay (Roblox), debug.info and debug.traceback.
-- Why: on the host stack a guest function is an interpreter closure running handlers, so these builtins would report
-- interpreter positions and frames. The replacements walk the stack through Env, which maps handler frames back to
-- guest instructions, so guest code sees the positions, levels and tracebacks the host VM would give it. Nothing is
-- tracked while code runs: the work happens only when an error is caught or the stack is inspected.

local Env = require("./Env")

local hostXpcall = xpcall
local hostDebug: any = debug
local hostCoroutine: any = coroutine
local hostInfo = debug.info
local hostTraceback = debug.traceback
local hostWrap = coroutine.wrap
local hostCreate = coroutine.create
local hostRunning = coroutine.running

local Relocate = Env.Relocate
local Frames, Where = Env.Frames, Env.Where

local Builtins = {}

-- Returns the results of a successful protected call, or raises its error unchanged.
local function Rethrow(ok: boolean, ...: any): ...any
	if ok then
		return ...
	end
	error((...), 0)
end

-- pcall whose caught errors carry the guest position of the instruction that raised them.
local function Pcall(f: any, ...: any): ...any
	return hostXpcall(f, Relocate, ...)
end

-- xpcall whose handler receives guest-positioned errors; the handler still runs where the error was raised.
local function Xpcall(f: any, handler: any, ...: any): ...any
	if type(handler) ~= "function" then
		return hostXpcall(f, handler, ...) -- the host's own argument error
	end
	return hostXpcall(f, function(message: any): ...any
		return handler(Relocate(message))
	end, ...)
end

-- Wraps a function so errors escaping it carry guest positions: its xpcall handler runs while the faulting handler
-- is still on the stack. Used for the chunk's main function and for coroutine bodies, so a coroutine pays once when
-- it starts rather than on every resume.
-- @param f function – guest function
local function Guarded(f: (...any) -> ...any): (...any) -> ...any
	local function Guard(...: any): ...any
		return Rethrow(hostXpcall(f, Relocate, ...))
	end
	Env.MarkWrapper(Guard)
	return Guard
end

-- coroutine.create, coroutine.wrap and Roblox's task.spawn/task.defer/task.delay with guarded bodies.
-- Non-function arguments go to the host unchanged, for its own errors (and for task's thread arguments).
local function Create(f: any): any
	return hostCreate(if type(f) == "function" then Guarded(f) else f)
end
local function Wrap(f: any): any
	return hostWrap(if type(f) == "function" then Guarded(f) else f)
end
local hostTask: any = task -- Roblox only; nil elsewhere
local Spawn, Defer, Delay
if type(hostTask) == "table" then
	local spawn, defer, delay = hostTask.spawn, hostTask.defer, hostTask.delay
	Spawn = function(f: any, ...: any): any
		return spawn(if type(f) == "function" then Guarded(f) else f, ...)
	end
	Defer = function(f: any, ...: any): any
		return defer(if type(f) == "function" then Guarded(f) else f, ...)
	end
	Delay = function(t: any, f: any, ...: any): any
		return delay(t, if type(f) == "function" then Guarded(f) else f, ...)
	end
end

-- Splits debug.info/debug.traceback arguments into thread (nil for the running one) and the rest.
local function ThreadArg(first: any): thread?
	if type(first) == "thread" and first ~= hostRunning() then
		return first
	end
	return nil
end

-- debug.traceback over guest frames, in the host's format ("source:line function name" per Luau frame).
local function Traceback(...: any): any
	local first = ...
	local isThread = type(first) == "thread"
	local thread = ThreadArg(first)
	local message, level
	if isThread then
		message, level = select(2, ...)
	else
		message, level = ...
	end
	local kind = type(message)
	if (message ~= nil and kind ~= "string" and kind ~= "number") or (level ~= nil and type(level) ~= "number") then
		return hostTraceback(...) -- the host's own argument errors
	end
	level = if level then math.floor(level) else if isThread then 0 else 1
	if level < 0 then
		return hostTraceback(...)
	end
	local lines = {}
	if message ~= nil then
		table.insert(lines, tostring(message) .. "\n")
	end
	-- the running thread's level 1 is the caller; another thread's level 0 is its innermost frame
	local frames = Frames(thread, if thread then 0 else 1)
	for i = if thread then level + 1 else level, #frames do
		local frame = frames[i]
		if frame.C then
			continue
		end
		local source, line, name
		local site = frame.Site
		if site then
			source, line, name = site.Name or "?", Env.LineOf(site, frame.Pc :: number), site.Proto.Name
		else
			source, line, name = frame.Source, frame.Line, frame.Name
			name = if name == "" then nil else name
		end
		table.insert(lines, `{source}{if (line :: number) > 0 then ":" .. line else ""}{if name then " function " .. name else ""}\n`)
	end
	return table.concat(lines)
end

local OPTIONS = { s = true, l = true, n = true, f = true, a = true }

-- debug.info over guest frames: levels count guest functions, and a guest level reports its source, current line,
-- name, function and arity as the host would.
local function Info(...: any): ...any
	local first = ...
	local isThread = type(first) == "thread"
	local thread = ThreadArg(first)
	local target, options
	if isThread then
		target, options = select(2, ...)
	else
		target, options = ...
	end
	local level = if type(target) == "number" or type(target) == "string" then tonumber(target) else nil
	if level == nil or level < 0 or type(options) ~= "string" then
		return hostInfo(...) -- functions, and the host's own argument errors
	end
	local seen = {}
	for i = 1, #options do
		local c = string.sub(options, i, i)
		if not OPTIONS[c] or seen[c] then
			return hostInfo(...) -- invalid or duplicate option
		end
		seen[c] = true
	end
	level = math.floor(level)
	if level == 0 and not isThread then
		return hostInfo(0, options) -- level 0 is debug.info itself
	end
	local frames = Frames(thread, if thread then 0 else 1)
	local frame = frames[if thread then level + 1 else level]
	if frame == nil then
		return
	end
	local site = frame.Site
	local results = {}
	for i = 1, #options do
		local c = string.sub(options, i, i)
		if c == "s" then
			table.insert(results, if site then site.Name or "?" else frame.Source)
		elseif c == "l" then
			table.insert(results, if site then Env.LineOf(site, frame.Pc :: number) else frame.Line)
		elseif c == "n" then
			table.insert(results, if site then site.Proto.Name or "" else frame.Name)
		elseif c == "f" then
			table.insert(results, frame.Fn)
		else
			table.insert(results, if site then site.Proto.Params else frame.Params)
			table.insert(results, if site then site.Proto.IsVararg else frame.Vararg)
		end
	end
	return table.unpack(results, 1, #results)
end

-- error() at level 2 and above: the position of that guest-visible level, as luaL_where gives it.
-- @param level number – error level, 2 or more
function Builtins.LevelWhere(level: number): string
	local frame = Frames(nil, 1)[math.floor(level)]
	return if frame then Where(frame) else ""
end

-- Host value -> guest replacement
Builtins.Swaps = {
	[pcall] = Pcall,
	[xpcall] = Xpcall,
	[hostCreate] = Create,
	[hostWrap] = Wrap,
	[hostInfo] = Info,
	[hostTraceback] = Traceback,
} :: { [any]: any }

if type(hostTask) == "table" then
	Builtins.Swaps[hostTask.spawn] = Spawn
	Builtins.Swaps[hostTask.defer] = Defer
	Builtins.Swaps[hostTask.delay] = Delay
end

-- Library tables guest code reads fields from at run time get copies holding the replacements.
for _, lib in { hostDebug, hostCoroutine, hostTask } do
	if type(lib) == "table" then
		local copy = table.clone(lib)
		for key, value in copy do
			local swap = Builtins.Swaps[value]
			if swap then
				copy[key] = swap
			end
		end
		Builtins.Swaps[lib] = table.freeze(copy)
	end
end

-- The subset Debug mode uses: there every guest function already positions the errors leaving it, so protected
-- calls and coroutine bodies need no handler of their own.
Builtins.DebugSwaps = { [hostInfo] = Info, [hostTraceback] = Traceback } :: { [any]: any }
if type(hostDebug) == "table" then
	Builtins.DebugSwaps[hostDebug] = Builtins.Swaps[hostDebug]
end

-- Global names whose reads may need a swap
Builtins.Names = { pcall = true, xpcall = true, debug = true, coroutine = true, task = true } :: { [string]: boolean }

-- Wraps a chunk's main function so errors escaping to the host carry guest positions.
Builtins.Main = Guarded

Env.MarkInternal(Pcall)

return Builtins
