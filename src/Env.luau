--!strict

-- Dynamic environments and the guest view of the host stack.
--
-- getfenv/setfenv with the host's semantics, enabled by the DynamicEnv load option.
-- Why: by default globals bind to one environment at load time, which is fastest; code that swaps environments
-- needs every closure to carry its own environment and imports to re-resolve once an environment is exposed.
--
-- Each VM closure's upvalue table holds its environment under ENV and the closure itself under FN. Numeric levels
-- walk the host call stack: VM closures are real host functions there, interpreter internals are skipped, and
-- other functions (pcall, host callbacks) count as levels, as they do on the host.
--
-- Stack view: every handler is registered with its instruction, and factory closures (the guest functions) are
-- recognisable by their definition site, so a host stack walk recovers the guest frames and the instruction each is
-- running. Errors, error levels, debug.info and debug.traceback use it to report guest positions without any
-- per-instruction tracking: the walk only happens when one of them asks.

local Types = require("./Types")

type Proto = Types.Proto

export type State = {
	Unsafe: { [any]: boolean }, -- environments exposed through getfenv/setfenv; their imports resolve per access
	Owners: { [any]: { any } }, -- VM closure -> its upvalue table
	getfenv: (any?) -> any,
	setfenv: (any, any) -> any,
}

local hostGetfenv = getfenv
local hostSetfenv = setfenv
local info = debug.info

-- Upvalue-table keys of a closure's environment and of the closure itself
local ENV, FN = "\0env", "\0fn"

-- Sources of interpreter modules; their frames are invisible to guest levels
local internal: { [string]: boolean } = {}
-- Interpreter functions run through a host pcall; that pcall's frame is invisible too
local guarded: { [any]: boolean } = {}
-- Interpreter wrappers that call guest code through a host xpcall; that xpcall's frame is invisible too
local wrappers: { [any]: boolean } = {}

-- Proto-wide position data shared by its handlers
export type Site = {
	Name: string?, -- chunk name used as the source of positions
	Proto: Proto,
}

-- A guest-visible stack level: a guest function (Site and Pc of its running instruction) or a host function
export type StackFrame = {
	Fn: any,
	Site: Site?,
	Pc: number?,
	Source: string?,
	Line: number?,
	Name: string?,
	Params: number?,
	Vararg: boolean?,
	C: boolean,
}

-- Handler closure -> its instruction and its proto's site
local Pcs: { [any]: number } = setmetatable({}, { __mode = "k" }) :: any
local Sites: { [any]: Site } = setmetatable({}, { __mode = "k" }) :: any
-- Definition site of the factory closures that run guest functions
local entrySource: string? = nil
local entryLines: { [number]: boolean } = {}

local Env = {}

Env.ENV = ENV
Env.FN = FN
Env.HostGetfenv = hostGetfenv
Env.HostSetfenv = hostSetfenv

-- Marks the module defining a function as interpreter-internal.
-- @param fn function – any function defined in that module
function Env.MarkInternal(fn: (...any) -> ...any)
	internal[info(fn, "s")] = true
end

-- Marks an interpreter function the interpreter itself calls through pcall (Debug mode).
-- @param fn function – function passed to pcall
function Env.MarkGuarded(fn: (...any) -> ...any)
	guarded[fn] = true
end

-- Marks an interpreter wrapper that runs guest code through xpcall (its xpcall frame is not a guest level).
-- @param fn function – the wrapper
function Env.MarkWrapper(fn: (...any) -> ...any)
	wrappers[fn] = true
end

-- Records the definition site of a guest-function closure made by the runtime.
-- @param fn function – a closure returned by a factory
function Env.MarkEntry(fn: (...any) -> ...any)
	local source, line = info(fn, "sl")
	entrySource = source
	entryLines[line] = true
end

-- Registers a handler so stack walks can map its frame to a guest instruction.
-- @param h function – handler closure
-- @param site Site – its proto's site
-- @param pc number – its instruction
function Env.Register(h: any, site: Site, pc: number)
	Pcs[h] = pc
	Sites[h] = site
end

-- Whether a function is a guest function made by the runtime.
local function IsEntry(fn: any): boolean
	local source, line = info(fn, "sl")
	return source == entrySource and entryLines[line] == true
end
Env.IsEntry = IsEntry

-- Source line of an instruction, or -1 without line info.
local function LineOf(site: Site, pc: number): number
	local lines = site.Proto.Lines
	return if lines and lines[pc] then lines[pc] else -1
end
Env.LineOf = LineOf

-- "chunk:line: " of an instruction, or "" without a chunk name or line info.
local function SiteWhere(site: Site, pc: number): string
	local line = LineOf(site, pc)
	if site.Name and line > 0 then
		return `{site.Name}:{line}: `
	end
	return ""
end

-- Whether the frame at a level of the caller's stack is the host xpcall of an interpreter wrapper.
local function WrapperCall(thread: thread?, i: number, source: string): boolean
	if source ~= "[C]" then
		return false
	end
	-- on the running thread, levels here are one deeper than the caller's
	local outer = if thread then info(thread, i + 1, "f") else info(i + 2, "f")
	return outer ~= nil and wrappers[outer] == true
end

-- Guest-visible frames of a stack, innermost first: guest functions with their running instruction, and host
-- functions as the host reports them. Interpreter frames are left out.
-- @param thread thread? – another coroutine, or nil for the running one
-- @param from number – first host level to inspect (1 is the walker itself on the running thread)
function Env.Frames(thread: thread?, from: number): { StackFrame }
	local frames: { StackFrame } = {}
	local site: Site?, pc: number? = nil, nil
	local i = from
	local skip = false
	while true do
		local fn = if thread then info(thread, i, "f") else info(i, "f")
		if fn == nil then
			break
		end
		if skip then
			skip = false
		elseif guarded[fn] then
			skip = true
		elseif Pcs[fn] ~= nil then
			-- handlers nest inside their function's frame; the innermost one is the running instruction
			if pc == nil then
				pc, site = Pcs[fn], Sites[fn]
			end
		elseif IsEntry(fn) then
			table.insert(frames, { Fn = fn, Site = site, Pc = pc, C = false })
			site, pc = nil, nil
		else
			local source = info(fn, "s")
			if not internal[source] and not WrapperCall(thread, i, source) then
				local src, line, name, params, vararg
				if thread then
					src, line, name, params, vararg = info(thread, i, "slna")
				else
					src, line, name, params, vararg = info(i, "slna")
				end
				table.insert(frames, {
					Fn = fn, Source = src, Line = line, Name = name, Params = params, Vararg = vararg, C = src == "[C]",
				})
			end
		end
		i += 1
	end
	return frames
end

-- "source:line: " of a stack frame, as luaL_where reports it ("" for C functions and unknown lines).
function Env.Where(frame: StackFrame): string
	local site = frame.Site
	if site then
		return SiteWhere(site, frame.Pc :: number)
	elseif frame.C or frame.Source == nil or (frame.Line :: number) <= 0 then
		return ""
	end
	return `{frame.Source}:{frame.Line}: `
end

-- Position of the innermost guest instruction on a stack.
-- @param thread thread? – another coroutine, or nil for the running one
function Env.Current(thread: thread?): string
	local i = if thread then 0 else 1
	while true do
		local fn = if thread then info(thread, i, "f") else info(i, "f")
		if fn == nil then
			return ""
		end
		local pc = Pcs[fn]
		if pc then
			return SiteWhere(Sites[fn], pc)
		end
		i += 1
	end
end

-- Replaces the position an interpreter module put on an error message with the guest's.
-- Why: Debug mode reports host-raised errors (calling nil, arithmetic on nil) at the guest line, as the host VM does.
-- @param message any – caught error value; non-strings and guest-positioned messages pass through
-- @param where string – guest "chunk:line: " prefix, or "" to drop the internal one
function Env.Reposition(message: any, where: string): any
	if type(message) ~= "string" then
		return message
	end
	local src, rest = string.match(message, "^(.-):%d+: (.*)$")
	if src and internal[src] then
		return where .. rest
	end
	return message
end

-- Error handler giving an error raised inside a handler the position of the guest instruction, found on the stack.
-- Why: without Debug nothing tracks the running instruction, but at the moment of the error the handler is still on
-- the stack, so catch points (pcall, xpcall, resume, the main function) can recover it.
-- @param message any – error value; only strings an interpreter module positioned change
-- @param thread thread? – the coroutine that raised it, when it is not the running one
function Env.Relocate(message: any, thread: thread?): any
	if type(message) ~= "string" then
		return message
	end
	local src = string.match(message, "^(.-):%d+: ")
	if src and internal[src] then
		return Env.Reposition(message, Env.Current(thread))
	end
	return message
end

-- Function at a guest-visible stack level (1 = the function calling getfenv/setfenv); nil past the stack.
-- @param owners { [any]: any } – VM closures (defined in an internal module, yet guest-visible)
local function AtLevel(owners: { [any]: any }, level: number): any
	local seen = 0
	local i = 2 -- 1 is AtLevel's caller in this module
	local skip = false
	while true do
		local fn = info(i, "f")
		if fn == nil then
			return nil
		end
		local source = info(i, "s")
		if skip then
			skip = false
		elseif guarded[fn] then
			skip = true
		elseif owners[fn] ~= nil or not (internal[source] or WrapperCall(nil, i, source)) then
			seen += 1
			if seen == level then
				return fn
			end
		end
		i += 1
	end
end

-- Creates a dynamic environment state. Level 0 is the running thread's globals, as on the host.
function Env.New(): State
	local state: State
	state = {
		Unsafe = setmetatable({}, { __mode = "k" }) :: any,
		Owners = setmetatable({}, { __mode = "k" }) :: any,
		getfenv = nil :: any,
		setfenv = nil :: any,
	}

	-- Environment of a function: its upvalue table's for VM closures; the thread's globals for C functions (the
	-- VM-aware getfenv/setfenv stand in for C functions); the host's otherwise.
	local function EnvOf(fn: any): any
		local U = state.Owners[fn]
		if U then
			return U[ENV]
		end
		local src = info(fn, "s")
		if src == "[C]" or internal[src] then
			return hostGetfenv(0)
		end
		return hostGetfenv(fn)
	end

	-- Function at a level argument, with the host's argument errors (raised without a position, as by C).
	-- @param name string – "getfenv" or "setfenv", for messages
	-- @param target any – level argument
	local function Resolve(name: string, target: any): (number, any)
		local level = tonumber(target)
		if level == nil then
			error(`invalid argument #1 to '{name}' (number expected, got {typeof(target)})`, 0)
		end
		level = if level >= 0 then math.floor(level) else math.ceil(level)
		if level < 0 then
			error(`invalid argument #1 to '{name}' (level must be non-negative)`, 0)
		elseif level == 0 then
			return 0, nil
		end
		local fn = AtLevel(state.Owners, level)
		if fn == nil then
			error(`invalid argument #1 to '{name}' (invalid level)`, 0)
		end
		return level, fn
	end

	-- getfenv for guest code.
	-- @param target any – level (default 1) or function
	state.getfenv = function(target: any?): any
		local env
		if type(target) == "function" then
			env = EnvOf(target)
		else
			local level, fn = Resolve("getfenv", if target == nil then 1 else target)
			env = if level == 0 then hostGetfenv(0) else EnvOf(fn)
		end
		if type(env) == "table" then
			state.Unsafe[env] = true
		end
		return env
	end

	-- setfenv for guest code; returns the function whose environment changed, as the host does.
	state.setfenv = function(target: any, env: any): any
		if type(env) ~= "table" then
			error(`invalid argument #2 to 'setfenv' (table expected, got {typeof(env)})`, 0)
		end
		local fn = target
		if type(target) ~= "function" then
			local level
			level, fn = Resolve("setfenv", target)
			if level == 0 then
				state.Unsafe[env] = true
				hostSetfenv(0, env)
				return nil
			end
		end
		state.Unsafe[env] = true
		local U = state.Owners[fn]
		if U then
			U[ENV] = env
			return fn
		end
		local src = info(fn, "s")
		if src == "[C]" or internal[src] then
			error("'setfenv' cannot change environment of given object", 0)
		end
		return hostSetfenv(fn, env)
	end

	return state
end

-- Swaps the host getfenv/setfenv for the state's versions when guest code reads them.
function Env.Swap(state: State, value: any): any
	if rawequal(value, hostGetfenv) then
		return state.getfenv
	elseif rawequal(value, hostSetfenv) then
		return state.setfenv
	end
	return value
end

Env.MarkInternal(Env.Swap)

return Env
