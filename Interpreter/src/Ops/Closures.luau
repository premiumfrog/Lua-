--!optimize 2
--!strict

-- Closure creation handlers (NEWCLOSURE, DUPCLOSURE).
-- A VM closure is a plain host function whose upvalues live in a table: by-value captures are stored directly,
-- by-reference captures as shared cells (see Runtime.Capture).
-- @param A number – target frame index
-- @param Make Factory – builds the host function for the child proto
-- @param Kinds { number } – capture kind per upvalue (see constants below)
-- @param Sources { number } – frame index or parent upvalue index per upvalue
-- @param Next Handler – successor, or a loop token in returning mode
-- @param Chain boolean – whether to call Next directly

local Types = require("../Types")
local Runtime = require("../Runtime")

type Handler = Types.Handler
type Factory = Types.Factory

local create = table.create
local rawequal = rawequal
local Capture = Runtime.Capture

-- Capture kinds after resolving the child's cell layout
local VALUE = 0 -- register copied by value
local CELL = 1 -- register shared through a cell
local UPVALUE = 2 -- parent upvalue passed through as is
local VALUE_BOXED = 3 -- register copied into a fresh closed cell (child expects a cell)
local UPVALUE_BOXED = 4 -- parent by-value upvalue copied into a fresh closed cell

local Closures = {}

Closures.VALUE = VALUE
Closures.CELL = CELL
Closures.UPVALUE = UPVALUE
Closures.VALUE_BOXED = VALUE_BOXED
Closures.UPVALUE_BOXED = UPVALUE_BOXED

local NO_UPVALUES = table.freeze({})

-- Reads one capture of a closure being created (any kind).
local function Captured(S: { any }, kind: number, source: number): any
	if kind == VALUE then
		return S[source]
	elseif kind == CELL then
		return Capture(S, source)
	elseif kind == UPVALUE then
		return S[1][source]
	end
	local cell: { any } = { false, 3, if kind == VALUE_BOXED then S[source] else S[1][source] }
	cell[1] = cell
	return cell
end

-- NEWCLOSURE: always creates a fresh closure.
-- Single captures (the common case) are written out per kind; the closure is stored before its captures are read
-- so a function capturing itself by value sees the closure.
function Closures.New(A: number, Make: Factory, Kinds: { number }, Sources: { number }, Next: Handler, Chain: boolean): Handler
	local n = #Kinds
	if n == 0 then
		return function(S)
			S[A] = Make(NO_UPVALUES)
			return if Chain then Next(S) else Next
		end
	elseif n == 1 then
		local kind, X = Kinds[1], Sources[1]
		if kind == CELL then
			return function(S)
				local U = create(1)
				S[A] = Make(U)
				U[1] = Capture(S, X)
				return if Chain then Next(S) else Next
			end
		elseif kind == VALUE then
			return function(S)
				local U = create(1)
				S[A] = Make(U)
				U[1] = S[X]
				return if Chain then Next(S) else Next
			end
		elseif kind == UPVALUE then
			return function(S)
				local U = create(1)
				S[A] = Make(U)
				U[1] = S[1][X]
				return if Chain then Next(S) else Next
			end
		end
	end
	return function(S)
		local U = create(n)
		S[A] = Make(U)
		for i = 1, n do
			U[i] = Captured(S, Kinds[i], Sources[i])
		end
		return if Chain then Next(S) else Next
	end
end

-- DUPCLOSURE: reuses the previous closure while its captured values are unchanged, like the host does.
function Closures.Dup(A: number, Make: Factory, Kinds: { number }, Sources: { number }, Next: Handler, Chain: boolean): Handler
	local n = #Kinds
	local cached: any = nil
	local cachedU: { any } = NO_UPVALUES

	if n == 0 then
		return function(S)
			local fn = cached
			if fn == nil then
				fn = Make(NO_UPVALUES)
				cached = fn
			end
			S[A] = fn
			return if Chain then Next(S) else Next
		end
	end

	local reusable = true
	for i = 1, n do
		if Kinds[i] ~= VALUE and Kinds[i] ~= UPVALUE then
			reusable = false
		end
	end

	return function(S)
		if reusable and cached ~= nil then
			-- stored first so a self capture compares against the cached closure, as the host does
			S[A] = cached
			local same = true
			for i = 1, n do
				local source = Sources[i]
				local v = if Kinds[i] == VALUE then S[source] else S[1][source]
				if not rawequal(cachedU[i], v) then
					same = false
					break
				end
			end
			if same then
				return if Chain then Next(S) else Next
			end
		end
		local U = create(n)
		local fn = Make(U)
		S[A] = fn
		for i = 1, n do
			U[i] = Captured(S, Kinds[i], Sources[i])
		end
		cached, cachedU = fn, U
		return if Chain then Next(S) else Next
	end
end

return Closures
