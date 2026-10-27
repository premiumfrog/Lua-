--!optimize 2
--!strict

-- Handlers that move values: constants, registers, globals, upvalues and varargs.
-- Each maker returns a chained handler (calls its successor) or a returning one (hands the successor back to a trampoline).
-- @param Next Handler – successor, or a loop token in returning mode
-- @param Chain boolean – whether to call Next directly

local Types = require("../Types")
local Runtime = require("../Runtime")

type Handler = Types.Handler

local move = table.move
local TOP = Runtime.TOP

local Values = {}

-- LOADNIL/LOADB/LOADN/LOADK/LOADKX and pre-resolved GETIMPORT: stores a value known at load time.
-- @param A number – target frame index
-- @param K any – value to store
function Values.LoadK(A: number, K: any, Next: Handler, Chain: boolean): Handler
	if Chain then
		return function(S)
			S[A] = K
			return Next(S)
		end
	end
	return function(S)
		S[A] = K
		return Next
	end
end

-- MOVE: copies a register.
-- @param A number – target frame index
-- @param B number – source frame index
function Values.Move(A: number, B: number, Next: Handler, Chain: boolean): Handler
	if Chain then
		return function(S)
			S[A] = S[B]
			return Next(S)
		end
	end
	return function(S)
		S[A] = S[B]
		return Next
	end
end

-- GETGLOBAL: reads a global from the chunk environment.
-- @param Env table – chunk environment
-- @param K string – global name
function Values.GetGlobal(A: number, Env: any, K: string, Next: Handler, Chain: boolean): Handler
	if Chain then
		return function(S)
			S[A] = Env[K]
			return Next(S)
		end
	end
	return function(S)
		S[A] = Env[K]
		return Next
	end
end

-- GETGLOBAL of error/assert feeding a call: substitutes the call site's positioned wrapper for the real function.
-- @param Swaps { [any]: any } – real function -> wrapper
function Values.GetGlobalSwapped(A: number, Env: any, K: string, Swaps: { [any]: any }, Next: Handler, Chain: boolean): Handler
	return function(S)
		local v = Env[K]
		S[A] = if v ~= nil and Swaps[v] ~= nil then Swaps[v] else v
		return if Chain then Next(S) else Next
	end
end

-- SETGLOBAL: writes a global into the chunk environment.
function Values.SetGlobal(A: number, Env: any, K: string, Next: Handler, Chain: boolean): Handler
	if Chain then
		return function(S)
			Env[K] = S[A]
			return Next(S)
		end
	end
	return function(S)
		Env[K] = S[A]
		return Next
	end
end

-- GETIMPORT that could not be resolved at load: walks the path on every execution.
-- Indexing a missing step raises, as the host's run-time import fallback does.
-- @param Path { string } – one to three keys
function Values.GetImport(A: number, Env: any, Path: { string }, Next: Handler, Chain: boolean): Handler
	local count, k1, k2, k3 = #Path, Path[1], Path[2], Path[3]
	local function Resolve(): any
		local v = Env[k1]
		if count > 1 then
			v = v[k2]
			if count > 2 then
				v = v[k3]
			end
		end
		return v
	end
	if Chain then
		return function(S)
			S[A] = Resolve()
			return Next(S)
		end
	end
	return function(S)
		S[A] = Resolve()
		return Next
	end
end

-- GETIMPORT walked per access, with values replaced when read (class-aware builtins).
-- @param Swaps { [any]: any } – host value -> replacement
function Values.GetImportSwapped(A: number, Env: any, Path: { string }, Swaps: { [any]: any }, Next: Handler, Chain: boolean): Handler
	local count, k1, k2, k3 = #Path, Path[1], Path[2], Path[3]
	return function(S)
		local v = Env[k1]
		if count > 1 then
			v = v[k2]
			if count > 2 then
				v = v[k3]
			end
		end
		if v ~= nil and Swaps[v] ~= nil then
			v = Swaps[v]
		end
		S[A] = v
		return if Chain then Next(S) else Next
	end
end

-- DynamicEnv GETGLOBAL: reads the running closure's environment.
-- @param ENV string – upvalue-table key of the environment
-- @param Swaps { [any]: any }? – values replaced when read (host getfenv/setfenv, positioned error/assert)
function Values.GetGlobalDyn(A: number, ENV: string, K: string, Swaps: { [any]: any }?, Next: Handler, Chain: boolean): Handler
	if Swaps then
		return function(S)
			local v = S[1][ENV][K]
			S[A] = if v ~= nil and Swaps[v] ~= nil then Swaps[v] else v
			return if Chain then Next(S) else Next
		end
	end
	return function(S)
		S[A] = S[1][ENV][K]
		return if Chain then Next(S) else Next
	end
end

-- DynamicEnv SETGLOBAL.
function Values.SetGlobalDyn(A: number, ENV: string, K: string, Next: Handler, Chain: boolean): Handler
	return function(S)
		S[1][ENV][K] = S[A]
		return if Chain then Next(S) else Next
	end
end

-- DynamicEnv GETIMPORT: the load-time value while the closure's environment is the load environment and has
-- never been exposed through getfenv/setfenv; otherwise the path is walked, as the host's safe-env check does.
-- @param Resolved any – value resolved at load (nil when it was not resolvable)
-- @param LoadEnv table – environment the value was resolved in
-- @param Unsafe { [any]: boolean } – exposed environments
-- @param Swaps { [any]: any }? – values replaced when read
function Values.GetImportDyn(A: number, ENV: string, Path: { string }, Resolved: any, LoadEnv: any, Unsafe: { [any]: boolean }, Swaps: { [any]: any }?, Next: Handler, Chain: boolean): Handler
	local count, k1, k2, k3 = #Path, Path[1], Path[2], Path[3]
	return function(S)
		local env = S[1][ENV]
		local v
		if Resolved ~= nil and env == LoadEnv and not Unsafe[env] then
			v = Resolved
		else
			v = env[k1]
			if count > 1 then
				v = v[k2]
				if count > 2 then
					v = v[k3]
				end
			end
		end
		if Swaps and v ~= nil and Swaps[v] ~= nil then
			v = Swaps[v]
		end
		S[A] = v
		return if Chain then Next(S) else Next
	end
end

-- GETTABLEKS of "getfenv"/"setfenv" under DynamicEnv (e.g. _G.getfenv): hands out the VM-aware versions.
function Values.GetKSwapped(A: number, B: number, K: string, Swaps: { [any]: any }, Next: Handler, Chain: boolean): Handler
	return function(S)
		local v = S[B][K]
		S[A] = if v ~= nil and Swaps[v] ~= nil then Swaps[v] else v
		return if Chain then Next(S) else Next
	end
end

-- GETUPVAL for an upvalue captured by value.
-- @param B number – upvalue index (1-based)
function Values.GetUpval(A: number, B: number, Next: Handler, Chain: boolean): Handler
	if Chain then
		return function(S)
			S[A] = S[1][B]
			return Next(S)
		end
	end
	return function(S)
		S[A] = S[1][B]
		return Next
	end
end

-- GETUPVAL for an upvalue held in a shared cell.
function Values.GetUpvalCell(A: number, B: number, Next: Handler, Chain: boolean): Handler
	if Chain then
		return function(S)
			local cell = S[1][B]
			S[A] = cell[1][cell[2]]
			return Next(S)
		end
	end
	return function(S)
		local cell = S[1][B]
		S[A] = cell[1][cell[2]]
		return Next
	end
end

-- SETUPVAL for a cell; a by-value upvalue is never written by compiled code but is handled for safety.
-- @param IsCell boolean – whether upvalue B is a cell
function Values.SetUpval(A: number, B: number, IsCell: boolean, Next: Handler, Chain: boolean): Handler
	if not IsCell then
		return function(S)
			S[1][B] = S[A]
			return if Chain then Next(S) else Next
		end
	end
	if Chain then
		return function(S)
			local cell = S[1][B]
			cell[1][cell[2]] = S[A]
			return Next(S)
		end
	end
	return function(S)
		local cell = S[1][B]
		cell[1][cell[2]] = S[A]
		return Next
	end
end

-- CLOSEUPVALS: detaches cells of registers leaving scope so later iterations get fresh variables.
function Values.CloseUpvals(A: number, Next: Handler, Chain: boolean): Handler
	local Close = Runtime.Close
	return function(S)
		if S[4] ~= nil then
			Close(S, A)
		end
		return if Chain then Next(S) else Next
	end
end

-- GETVARARGS with a fixed count: copies varargs, padding with nil.
-- @param Count number – values to copy
function Values.GetVarargs(A: number, Count: number, Next: Handler, Chain: boolean): Handler
	if Count == 1 then
		if Chain then
			return function(S)
				S[A] = S[2][1]
				return Next(S)
			end
		end
		return function(S)
			S[A] = S[2][1]
			return Next
		end
	end
	return function(S)
		local v = S[2]
		for i = 1, Count do
			S[A + i - 1] = v[i]
		end
		return if Chain then Next(S) else Next
	end
end

-- GETVARARGS with MULTRET: copies every vararg and sets top.
function Values.GetVarargsAll(A: number, Next: Handler, Chain: boolean): Handler
	return function(S)
		local n = S[3]
		move(S[2], 1, n, A, S)
		S[TOP] = A + n - 1
		return if Chain then Next(S) else Next
	end
end

return Values
