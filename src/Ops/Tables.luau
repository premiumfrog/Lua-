--!optimize 2
--!strict

-- Table construction and indexing handlers.
-- Indexing is native so __index/__newindex and userdata (e.g. Instances) behave exactly as in host code.
-- @param Next Handler – successor, or a loop token in returning mode
-- @param Chain boolean – whether to call Next directly

local Types = require("../Types")
local Runtime = require("../Runtime")

type Handler = Types.Handler

local create = table.create
local clone = table.clone
local move = table.move
local TOP = Runtime.TOP

local Tables = {}

-- GETTABLE: A = B[C] with a register key.
function Tables.Get(A: number, B: number, C: number, Next: Handler, Chain: boolean): Handler
	if Chain then
		return function(S)
			S[A] = S[B][S[C]]
			return Next(S)
		end
	end
	return function(S)
		S[A] = S[B][S[C]]
		return Next
	end
end

-- SETTABLE: B[C] = A with a register key.
function Tables.Set(A: number, B: number, C: number, Next: Handler, Chain: boolean): Handler
	if Chain then
		return function(S)
			S[B][S[C]] = S[A]
			return Next(S)
		end
	end
	return function(S)
		S[B][S[C]] = S[A]
		return Next
	end
end

-- GETTABLEKS / GETTABLEN: A = B[K] with a constant key.
-- @param K any – string or small integer key
function Tables.GetK(A: number, B: number, K: any, Next: Handler, Chain: boolean): Handler
	if Chain then
		return function(S)
			S[A] = S[B][K]
			return Next(S)
		end
	end
	return function(S)
		S[A] = S[B][K]
		return Next
	end
end

-- SETTABLEKS / SETTABLEN: B[K] = A with a constant key.
function Tables.SetK(A: number, B: number, K: any, Next: Handler, Chain: boolean): Handler
	if Chain then
		return function(S)
			S[B][K] = S[A]
			return Next(S)
		end
	end
	return function(S)
		S[B][K] = S[A]
		return Next
	end
end

-- NEWTABLE: presizes the table like the host's luaH_new.
-- A hash-only constructor clones an empty presized template, so keys inserted by the constructor land in the
-- same nodes (and iterate in the same order) as on the host.
-- @param Size number – array size hint
-- @param HashSize number – hash size hint (0 when none)
-- Allocating handlers clear A first: the host collects after the instruction, once A holds the new value, while
-- here the collection step runs before the store, and the old value must not survive it.
function Tables.New(A: number, Size: number, HashSize: number, Next: Handler, Chain: boolean): Handler
	if HashSize > 0 and Size == 0 then
		local template = Runtime.PresizedHash(HashSize)
		return function(S)
			S[A] = nil
			S[A] = clone(template)
			return if Chain then Next(S) else Next
		end
	elseif Size > 0 then
		return function(S)
			S[A] = nil
			S[A] = create(Size)
			return if Chain then Next(S) else Next
		end
	end
	if Chain then
		return function(S)
			S[A] = nil
			S[A] = {}
			return Next(S)
		end
	end
	return function(S)
		S[A] = nil
		S[A] = {}
		return Next
	end
end

-- DUPTABLE: clones a constructor template so field slots are presized and constant fields prefilled.
-- @param Template table – shape built by the deserializer
function Tables.Dup(A: number, Template: any, Next: Handler, Chain: boolean): Handler
	if Chain then
		return function(S)
			S[A] = nil
			S[A] = clone(Template)
			return Next(S)
		end
	end
	return function(S)
		S[A] = nil
		S[A] = clone(Template)
		return Next
	end
end

-- SETLIST with a fixed count: stores B..B+Count-1 into A starting at Index.
-- @param Index number – first array index
function Tables.SetList(A: number, B: number, Count: number, Index: number, Next: Handler, Chain: boolean): Handler
	local last = B + Count - 1
	return function(S)
		move(S, B, last, Index, S[A])
		return if Chain then Next(S) else Next
	end
end

-- SETLIST with MULTRET: stores B..top into A.
function Tables.SetListAll(A: number, B: number, Index: number, Next: Handler, Chain: boolean): Handler
	return function(S)
		move(S, B, S[TOP], Index, S[A])
		return if Chain then Next(S) else Next
	end
end

return Tables
