--!optimize 2
--!strict

-- Conditional branch handlers.
-- Negated opcodes are built by swapping successors, so each condition is written once.
-- Each successor is either chained (called) or returned to a trampoline, giving four variants per condition.
-- @param N Handler – fallthrough successor (or loop token)
-- @param NC boolean – whether N is chained
-- @param T Handler – branch target (or loop token)
-- @param TC boolean – whether T is chained

local Types = require("../Types")
local Runtime = require("../Runtime")

type Handler = Types.Handler

local COUNT, RET_ONE = Runtime.COUNT, Runtime.RET_ONE

local Branches = {}

-- JUMPIF: branch when A is truthy.
function Branches.Truthy(A: number, N: Handler, NC: boolean, T: Handler, TC: boolean): Handler
	if NC and TC then
		return function(S)
			if S[A] then
				return T(S)
			end
			return N(S)
		end
	elseif NC then
		return function(S)
			if S[A] then
				return T
			end
			return N(S)
		end
	elseif TC then
		return function(S)
			if S[A] then
				return T(S)
			end
			return N
		end
	end
	return function(S)
		if S[A] then
			return T
		end
		return N
	end
end

-- JUMPIFEQ: branch when A == B (native equality, so __eq applies).
function Branches.Eq(A: number, B: number, N: Handler, NC: boolean, T: Handler, TC: boolean): Handler
	if NC and TC then
		return function(S)
			if S[A] == S[B] then
				return T(S)
			end
			return N(S)
		end
	elseif NC then
		return function(S)
			if S[A] == S[B] then
				return T
			end
			return N(S)
		end
	elseif TC then
		return function(S)
			if S[A] == S[B] then
				return T(S)
			end
			return N
		end
	end
	return function(S)
		if S[A] == S[B] then
			return T
		end
		return N
	end
end

-- JUMPIFLE: branch when A <= B.
function Branches.Le(A: number, B: number, N: Handler, NC: boolean, T: Handler, TC: boolean): Handler
	if NC and TC then
		return function(S)
			if S[A] <= S[B] then
				return T(S)
			end
			return N(S)
		end
	elseif NC then
		return function(S)
			if S[A] <= S[B] then
				return T
			end
			return N(S)
		end
	elseif TC then
		return function(S)
			if S[A] <= S[B] then
				return T(S)
			end
			return N
		end
	end
	return function(S)
		if S[A] <= S[B] then
			return T
		end
		return N
	end
end

-- JUMPIFLT: branch when A < B.
function Branches.Lt(A: number, B: number, N: Handler, NC: boolean, T: Handler, TC: boolean): Handler
	if NC and TC then
		return function(S)
			if S[A] < S[B] then
				return T(S)
			end
			return N(S)
		end
	elseif NC then
		return function(S)
			if S[A] < S[B] then
				return T
			end
			return N(S)
		end
	elseif TC then
		return function(S)
			if S[A] < S[B] then
				return T(S)
			end
			return N
		end
	end
	return function(S)
		if S[A] < S[B] then
			return T
		end
		return N
	end
end

-- JUMPXEQK*: branch when A equals a constant (nil, boolean, number or string).
-- @param K any – constant compared with raw-equivalent native ==
function Branches.EqK(A: number, K: any, N: Handler, NC: boolean, T: Handler, TC: boolean): Handler
	if NC and TC then
		return function(S)
			if S[A] == K then
				return T(S)
			end
			return N(S)
		end
	elseif NC then
		return function(S)
			if S[A] == K then
				return T
			end
			return N(S)
		end
	elseif TC then
		return function(S)
			if S[A] == K then
				return T(S)
			end
			return N
		end
	end
	return function(S)
		if S[A] == K then
			return T
		end
		return N
	end
end

-- Builds the condition of a boolean-materializing branch as a function of the frame.
local function Test(Kind: string, A: number, B: any, Negate: boolean): (any) -> boolean
	if Kind == "truthy" then
		return if Negate then function(S) return not S[A] end else function(S) return not not S[A] end
	elseif Kind == "eq" then
		return if Negate then function(S) return S[A] ~= S[B] end else function(S) return S[A] == S[B] end
	elseif Kind == "le" then
		return if Negate then function(S) return not (S[A] <= S[B]) end else function(S) return S[A] <= S[B] end
	elseif Kind == "lt" then
		return if Negate then function(S) return not (S[A] < S[B]) end else function(S) return S[A] < S[B] end
	end
	return if Negate then function(S) return S[A] ~= B end else function(S) return S[A] == B end
end

-- A branch whose successors only load opposite booleans into R (`x = a < b`): stores the condition instead.
-- @param Kind string – "truthy", "eq", "le", "lt" or "eqk"
-- @param R number – frame index receiving the boolean
-- @param B any – right operand frame index, or the constant for "eqk"
-- @param Negate boolean – whether the stored value is the condition's negation
function Branches.Store(Kind: string, R: number, A: number, B: any, Negate: boolean, Next: Handler, Chain: boolean): Handler
	local test = Test(Kind, A, B, Negate)
	-- the comparison itself is the expensive part; one extra call keeps this table of variants small
	if Chain then
		return function(S)
			S[R] = test(S)
			return Next(S)
		end
	end
	return function(S)
		S[R] = test(S)
		return Next
	end
end

-- Store followed by `return R`: ends the function with the condition as its single result.
function Branches.StoreReturn(Kind: string, A: number, B: any, Negate: boolean): Handler
	if Kind == "lt" and not Negate then
		return function(S)
			S[1] = S[A] < S[B]
			S[COUNT] = RET_ONE
			return nil
		end
	elseif Kind == "le" and not Negate then
		return function(S)
			S[1] = S[A] <= S[B]
			S[COUNT] = RET_ONE
			return nil
		end
	elseif Kind == "eq" then
		if Negate then
			return function(S)
				S[1] = S[A] ~= S[B]
				S[COUNT] = RET_ONE
				return nil
			end
		end
		return function(S)
			S[1] = S[A] == S[B]
			S[COUNT] = RET_ONE
			return nil
		end
	end
	local test = Test(Kind, A, B, Negate)
	return function(S)
		S[1] = test(S)
		S[COUNT] = RET_ONE
		return nil
	end
end

return Branches
