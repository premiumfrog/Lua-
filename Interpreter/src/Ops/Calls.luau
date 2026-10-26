--!optimize 2
--!strict

-- Call, method-call and return handlers.
-- Callees are invoked as ordinary host calls, so VM closures, host functions, coroutines and pcall all interoperate natively.
-- Operands are frame indices chosen by Analysis: a callee or argument load folded into the call is read straight
-- from its source register or constant slot.
-- @param A number – frame index results are written from
-- @param Next Handler – successor, or a loop token in returning mode
-- @param Chain boolean – whether to call Next directly

local Types = require("../Types")
local Runtime = require("../Runtime")

type Handler = Types.Handler

local unpack = table.unpack
local move = table.move
local select = select
local TOP, COUNT = Runtime.TOP, Runtime.COUNT
local RET_NONE, RET_ONE, RET_TWO, RET_RANGE, RET_TAIL = Runtime.RET_NONE, Runtime.RET_ONE, Runtime.RET_TWO, Runtime.RET_RANGE, Runtime.RET_TAIL

local Calls = {}

-- Stores call results at A: Want of them (nil-padded), or all of them with top set when Want is -1.
-- Up to three values are stored without packing them into a table.
local function Spill(S: { any }, A: number, Want: number, ...: any)
	if Want < 0 then
		local n = select("#", ...)
		if n == 1 then
			S[A] = (...)
		elseif n == 2 then
			S[A], S[A + 1] = ...
		elseif n == 3 then
			S[A], S[A + 1], S[A + 2] = ...
		elseif n > 0 then
			move({ ... }, 1, n, A, S)
		end
		S[TOP] = A + n - 1
	elseif Want == 1 then
		S[A] = (...)
	elseif Want == 2 then
		S[A], S[A + 1] = ...
	elseif Want == 3 then
		S[A], S[A + 1], S[A + 2] = ...
	elseif Want > 0 then
		local values = { ... }
		for i = 1, Want do
			S[A + i - 1] = values[i]
		end
	end
end

-- Raises the host's error for a method lookup that found nothing.
-- @param where string – "chunk:line: " prefix of the call site
local function MissingMethod(object: any, key: string, where: string): never
	error(`{where}attempt to call missing method '{key}' of {typeof(object)}`, 0)
end

-- Calls through a callee held in a frame slot (register or constant slot).
local function ViaFrame(A: number, F: number, Args: { number }, Results: number, Next: Handler, Chain: boolean): Handler?
	local X, Y, Z = Args[1], Args[2], Args[3]
	local n = #Args
	if Results == 1 then
		if n == 0 then
			if Chain then
				return function(S)
					S[A] = S[F]()
					return Next(S)
				end
			end
			return function(S)
				S[A] = S[F]()
				return Next
			end
		elseif n == 1 then
			if Chain then
				return function(S)
					S[A] = S[F](S[X])
					return Next(S)
				end
			end
			return function(S)
				S[A] = S[F](S[X])
				return Next
			end
		elseif n == 2 then
			if Chain then
				return function(S)
					S[A] = S[F](S[X], S[Y])
					return Next(S)
				end
			end
			return function(S)
				S[A] = S[F](S[X], S[Y])
				return Next
			end
		elseif n == 3 then
			if Chain then
				return function(S)
					S[A] = S[F](S[X], S[Y], S[Z])
					return Next(S)
				end
			end
			return function(S)
				S[A] = S[F](S[X], S[Y], S[Z])
				return Next
			end
		end
	elseif Results == 0 then
		if n == 0 then
			if Chain then
				return function(S)
					S[F]()
					return Next(S)
				end
			end
			return function(S)
				S[F]()
				return Next
			end
		elseif n == 1 then
			if Chain then
				return function(S)
					S[F](S[X])
					return Next(S)
				end
			end
			return function(S)
				S[F](S[X])
				return Next
			end
		elseif n == 2 then
			if Chain then
				return function(S)
					S[F](S[X], S[Y])
					return Next(S)
				end
			end
			return function(S)
				S[F](S[X], S[Y])
				return Next
			end
		elseif n == 3 then
			return function(S)
				S[F](S[X], S[Y], S[Z])
				return if Chain then Next(S) else Next
			end
		end
	elseif Results == 2 then
		local A1 = A + 1
		if n == 0 then
			return function(S)
				S[A], S[A1] = S[F]()
				return if Chain then Next(S) else Next
			end
		elseif n == 1 then
			return function(S)
				S[A], S[A1] = S[F](S[X])
				return if Chain then Next(S) else Next
			end
		elseif n == 2 then
			return function(S)
				S[A], S[A1] = S[F](S[X], S[Y])
				return if Chain then Next(S) else Next
			end
		end
	end
	return nil
end

-- Calls through a by-value upvalue (local functions called from nested functions, recursion).
local function ViaUpvalue(A: number, U: number, Args: { number }, Results: number, Next: Handler, Chain: boolean): Handler?
	local X, Y, Z = Args[1], Args[2], Args[3]
	local n = #Args
	if Results == 1 then
		if n == 0 then
			if Chain then
				return function(S)
					S[A] = S[1][U]()
					return Next(S)
				end
			end
			return function(S)
				S[A] = S[1][U]()
				return Next
			end
		elseif n == 1 then
			if Chain then
				return function(S)
					S[A] = S[1][U](S[X])
					return Next(S)
				end
			end
			return function(S)
				S[A] = S[1][U](S[X])
				return Next
			end
		elseif n == 2 then
			if Chain then
				return function(S)
					S[A] = S[1][U](S[X], S[Y])
					return Next(S)
				end
			end
			return function(S)
				S[A] = S[1][U](S[X], S[Y])
				return Next
			end
		elseif n == 3 then
			return function(S)
				S[A] = S[1][U](S[X], S[Y], S[Z])
				return if Chain then Next(S) else Next
			end
		end
	elseif Results == 0 then
		if n == 0 then
			return function(S)
				S[1][U]()
				return if Chain then Next(S) else Next
			end
		elseif n == 1 then
			return function(S)
				S[1][U](S[X])
				return if Chain then Next(S) else Next
			end
		elseif n == 2 then
			return function(S)
				S[1][U](S[X], S[Y])
				return if Chain then Next(S) else Next
			end
		end
	end
	return nil
end

-- CALL / CALLFB.
-- @param F number? – frame index of the callee, or nil when U is given
-- @param U number? – upvalue index of the callee
-- @param Args { number }? – frame indices of the arguments; nil means A+1.. up to top (MULTRET)
-- @param Results number – result count, or -1 to keep all and set top
function Calls.Call(A: number, F: number?, U: number?, Args: { number }?, Results: number, Next: Handler, Chain: boolean): Handler
	if Args and Results >= 0 then
		local fast = if F then ViaFrame(A, F, Args, Results, Next, Chain) else ViaUpvalue(A, U :: number, Args, Results, Next, Chain)
		if fast then
			return fast
		end
	end
	if Args then
		local list = Args
		local count = #list
		local X, Y, Z = list[1], list[2], list[3]
		if count <= 3 and F then
			-- multiple or all results: no argument table, results spilled directly
			if count == 0 then
				return function(S)
					Spill(S, A, Results, S[F]())
					return if Chain then Next(S) else Next
				end
			elseif count == 1 then
				return function(S)
					Spill(S, A, Results, S[F](S[X]))
					return if Chain then Next(S) else Next
				end
			elseif count == 2 then
				return function(S)
					Spill(S, A, Results, S[F](S[X], S[Y]))
					return if Chain then Next(S) else Next
				end
			end
			return function(S)
				Spill(S, A, Results, S[F](S[X], S[Y], S[Z]))
				return if Chain then Next(S) else Next
			end
		end
		return function(S)
			local fn = if F then S[F] else S[1][U :: number]
			local values = table.create(count)
			for i = 1, count do
				values[i] = S[list[i]]
			end
			Spill(S, A, Results, fn(unpack(values, 1, count)))
			return if Chain then Next(S) else Next
		end
	end
	return function(S)
		local fn = if F then S[F] else S[1][U :: number]
		Spill(S, A, Results, fn(unpack(S, A + 1, S[TOP])))
		return if Chain then Next(S) else Next
	end
end

-- Calls a function fixed at load time (call-site wrappers such as positioned error/assert).
-- @param Fn function – callee
-- @param Args { number } – frame indices of the arguments
function Calls.Direct(A: number, Fn: (...any) -> ...any, Args: { number }, Results: number, Next: Handler, Chain: boolean): Handler
	local X, Y = Args[1], Args[2]
	local n = #Args
	if Results == 0 and n == 2 then
		return function(S)
			Fn(S[X], S[Y])
			return if Chain then Next(S) else Next
		end
	elseif Results == 0 and n == 1 then
		return function(S)
			Fn(S[X])
			return if Chain then Next(S) else Next
		end
	end
	return function(S)
		local values = table.create(n)
		for i = 1, n do
			values[i] = S[Args[i]]
		end
		Spill(S, A, Results, Fn(unpack(values, 1, n)))
		return if Chain then Next(S) else Next
	end
end

-- CALL followed by RETURN of all its results: the factory performs the call in host tail position,
-- so results are never packed and the frame is already back in its pool.
-- @param Args number – argument count, or -1 for arguments up to top
function Calls.TailCall(A: number, Args: number): Handler
	return function(S)
		S[COUNT] = RET_TAIL
		S[2] = if Args < 0 then S[TOP] - A else Args
		S[1] = A
		return nil
	end
end

-- NAMECALL left standalone: loads the method and the self argument for the CALL that follows.
-- @param B number – frame index of the object
-- @param K string – method name
-- @param Where string – error position prefix
function Calls.NameCall(A: number, B: number, K: string, Where: string, Next: Handler, Chain: boolean): Handler
	local A1 = A + 1
	return function(S)
		local self = S[B]
		local fn = self[K]
		if fn == nil then
			MissingMethod(self, K, Where)
		end
		S[A1] = self
		S[A] = fn
		return if Chain then Next(S) else Next
	end
end

-- NAMECALL folded into its CALL: looks the method up and calls it in one handler.
-- @param O number – frame index of the object
-- @param Args { number } – frame indices of the arguments after self
function Calls.Method(A: number, O: number, K: string, Args: { number }, Results: number, Where: string, Next: Handler, Chain: boolean): Handler
	local X, Y = Args[1], Args[2]
	local n = #Args
	if Results == 1 then
		if n == 0 then
			if Chain then
				return function(S)
					local o = S[O]
					local fn = o[K]
					if fn == nil then
						MissingMethod(o, K, Where)
					end
					S[A] = fn(o)
					return Next(S)
				end
			end
			return function(S)
				local o = S[O]
				local fn = o[K]
				if fn == nil then
					MissingMethod(o, K, Where)
				end
				S[A] = fn(o)
				return Next
			end
		elseif n == 1 then
			if Chain then
				return function(S)
					local o = S[O]
					local fn = o[K]
					if fn == nil then
						MissingMethod(o, K, Where)
					end
					S[A] = fn(o, S[X])
					return Next(S)
				end
			end
			return function(S)
				local o = S[O]
				local fn = o[K]
				if fn == nil then
					MissingMethod(o, K, Where)
				end
				S[A] = fn(o, S[X])
				return Next
			end
		elseif n == 2 then
			return function(S)
				local o = S[O]
				local fn = o[K]
				if fn == nil then
					MissingMethod(o, K, Where)
				end
				S[A] = fn(o, S[X], S[Y])
				return if Chain then Next(S) else Next
			end
		end
	elseif Results == 0 then
		if n == 0 then
			return function(S)
				local o = S[O]
				local fn = o[K]
				if fn == nil then
					MissingMethod(o, K, Where)
				end
				fn(o)
				return if Chain then Next(S) else Next
			end
		elseif n == 1 then
			if Chain then
				return function(S)
					local o = S[O]
					local fn = o[K]
					if fn == nil then
						MissingMethod(o, K, Where)
					end
					fn(o, S[X])
					return Next(S)
				end
			end
			return function(S)
				local o = S[O]
				local fn = o[K]
				if fn == nil then
					MissingMethod(o, K, Where)
				end
				fn(o, S[X])
				return Next
			end
		elseif n == 2 then
			return function(S)
				local o = S[O]
				local fn = o[K]
				if fn == nil then
					MissingMethod(o, K, Where)
				end
				fn(o, S[X], S[Y])
				return if Chain then Next(S) else Next
			end
		end
	end

	if n <= 1 then
		return function(S)
			local o = S[O]
			local fn = o[K]
			if fn == nil then
				MissingMethod(o, K, Where)
			end
			if n == 0 then
				Spill(S, A, Results, fn(o))
			else
				Spill(S, A, Results, fn(o, S[X]))
			end
			return if Chain then Next(S) else Next
		end
	end

	local count = n
	return function(S)
		local o = S[O]
		local fn = o[K]
		if fn == nil then
			MissingMethod(o, K, Where)
		end
		local values = table.create(count)
		for i = 1, count do
			values[i] = S[Args[i]]
		end
		Spill(S, A, Results, fn(o, unpack(values, 1, count)))
		return if Chain then Next(S) else Next
	end
end

-- select(i, ...) on the function's own varargs: indexes the vararg table instead of spreading it.
-- @param X number – frame index of i
function Calls.SelectVararg(A: number, X: number, Next: Handler, Chain: boolean): Handler
	return function(S)
		local i = S[X]
		if i == "#" then
			S[A] = S[COUNT]
		elseif type(i) == "number" and i >= 1 and i % 1 == 0 then
			S[A] = S[2][i]
		else
			S[A] = select(i, unpack(S[2], 1, S[COUNT]))
		end
		return if Chain then Next(S) else Next
	end
end

-- RETURN: leaves results in the frame and ends the function (returns nil to every trampoline).
-- @param Count number – value count, or -1 for values up to top
function Calls.Return(A: number, Count: number): Handler
	if Count == 1 then
		return function(S)
			S[1] = S[A]
			S[COUNT] = RET_ONE
			return nil
		end
	elseif Count == 0 then
		return function(S)
			S[COUNT] = RET_NONE
			return nil
		end
	elseif Count == 2 then
		return function(S)
			S[1], S[2] = S[A], S[A + 1]
			S[COUNT] = RET_TWO
			return nil
		end
	elseif Count < 0 then
		return function(S)
			S[1], S[2] = A, S[TOP]
			S[COUNT] = RET_RANGE
			return nil
		end
	end
	local last = A + Count - 1
	return function(S)
		S[1], S[2] = A, last
		S[COUNT] = RET_RANGE
		return nil
	end
end

return Calls
