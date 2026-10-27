--!optimize 2
--!strict

-- Arithmetic, logical and unary handlers.
-- Operators are executed natively, so metamethods, coercions and error messages match the host exactly.
-- @param A number – target frame index
-- @param B number – left operand frame index
-- @param C number – right operand frame index (or constant value for K forms)
-- @param Next Handler – successor, or a loop token in returning mode
-- @param Chain boolean – whether to call Next directly

local Types = require("../Types")

type Handler = Types.Handler

local Arith = {}

-- Register-register binary operators, keyed by opcode name.
local RR: { [string]: (number, number, number, Handler, boolean) -> Handler } = {}
-- Register-constant binary operators.
local RK: { [string]: (number, number, any, Handler, boolean) -> Handler } = {}

function RR.ADD(A, B, C, Next, Chain)
	if Chain then
		return function(S)
			S[A] = S[B] + S[C]
			return Next(S)
		end
	end
	return function(S)
		S[A] = S[B] + S[C]
		return Next
	end
end

function RR.SUB(A, B, C, Next, Chain)
	if Chain then
		return function(S)
			S[A] = S[B] - S[C]
			return Next(S)
		end
	end
	return function(S)
		S[A] = S[B] - S[C]
		return Next
	end
end

function RR.MUL(A, B, C, Next, Chain)
	if Chain then
		return function(S)
			S[A] = S[B] * S[C]
			return Next(S)
		end
	end
	return function(S)
		S[A] = S[B] * S[C]
		return Next
	end
end

function RR.DIV(A, B, C, Next, Chain)
	if Chain then
		return function(S)
			S[A] = S[B] / S[C]
			return Next(S)
		end
	end
	return function(S)
		S[A] = S[B] / S[C]
		return Next
	end
end

function RR.MOD(A, B, C, Next, Chain)
	if Chain then
		return function(S)
			S[A] = S[B] % S[C]
			return Next(S)
		end
	end
	return function(S)
		S[A] = S[B] % S[C]
		return Next
	end
end

function RR.POW(A, B, C, Next, Chain)
	return function(S)
		S[A] = S[B] ^ S[C]
		return if Chain then Next(S) else Next
	end
end

function RR.IDIV(A, B, C, Next, Chain)
	return function(S)
		S[A] = S[B] // S[C]
		return if Chain then Next(S) else Next
	end
end

-- AND/OR select an operand without coercing it to boolean.
function RR.AND(A, B, C, Next, Chain)
	return function(S)
		S[A] = S[B] and S[C]
		return if Chain then Next(S) else Next
	end
end

function RR.OR(A, B, C, Next, Chain)
	return function(S)
		S[A] = S[B] or S[C]
		return if Chain then Next(S) else Next
	end
end

function RK.ADD(A, B, K, Next, Chain)
	if Chain then
		return function(S)
			S[A] = S[B] + K
			return Next(S)
		end
	end
	return function(S)
		S[A] = S[B] + K
		return Next
	end
end

function RK.SUB(A, B, K, Next, Chain)
	if Chain then
		return function(S)
			S[A] = S[B] - K
			return Next(S)
		end
	end
	return function(S)
		S[A] = S[B] - K
		return Next
	end
end

function RK.MUL(A, B, K, Next, Chain)
	if Chain then
		return function(S)
			S[A] = S[B] * K
			return Next(S)
		end
	end
	return function(S)
		S[A] = S[B] * K
		return Next
	end
end

function RK.DIV(A, B, K, Next, Chain)
	if Chain then
		return function(S)
			S[A] = S[B] / K
			return Next(S)
		end
	end
	return function(S)
		S[A] = S[B] / K
		return Next
	end
end

function RK.MOD(A, B, K, Next, Chain)
	if Chain then
		return function(S)
			S[A] = S[B] % K
			return Next(S)
		end
	end
	return function(S)
		S[A] = S[B] % K
		return Next
	end
end

function RK.POW(A, B, K, Next, Chain)
	return function(S)
		S[A] = S[B] ^ K
		return if Chain then Next(S) else Next
	end
end

function RK.IDIV(A, B, K, Next, Chain)
	return function(S)
		S[A] = S[B] // K
		return if Chain then Next(S) else Next
	end
end

function RK.AND(A, B, K, Next, Chain)
	return function(S)
		S[A] = S[B] and K
		return if Chain then Next(S) else Next
	end
end

function RK.OR(A, B, K, Next, Chain)
	return function(S)
		S[A] = S[B] or K
		return if Chain then Next(S) else Next
	end
end

Arith.RR = RR
Arith.RK = RK

-- SUBRK: constant minus register.
function Arith.SubRK(A: number, K: any, C: number, Next: Handler, Chain: boolean): Handler
	return function(S)
		S[A] = K - S[C]
		return if Chain then Next(S) else Next
	end
end

-- DIVRK: constant divided by register.
function Arith.DivRK(A: number, K: any, C: number, Next: Handler, Chain: boolean): Handler
	return function(S)
		S[A] = K / S[C]
		return if Chain then Next(S) else Next
	end
end

function Arith.Not(A: number, B: number, Next: Handler, Chain: boolean): Handler
	if Chain then
		return function(S)
			S[A] = not S[B]
			return Next(S)
		end
	end
	return function(S)
		S[A] = not S[B]
		return Next
	end
end

function Arith.Minus(A: number, B: number, Next: Handler, Chain: boolean): Handler
	if Chain then
		return function(S)
			S[A] = -S[B]
			return Next(S)
		end
	end
	return function(S)
		S[A] = -S[B]
		return Next
	end
end

function Arith.Length(A: number, B: number, Next: Handler, Chain: boolean): Handler
	if Chain then
		return function(S)
			S[A] = #S[B]
			return Next(S)
		end
	end
	return function(S)
		S[A] = #S[B]
		return Next
	end
end

-- CONCAT B..C into A; right associative like the host so __concat sees the same operand pairs.
-- @param B number – first source frame index
-- @param C number – last source frame index
function Arith.Concat(A: number, B: number, C: number, Next: Handler, Chain: boolean): Handler
	if A >= B and A <= C then
		if C == B + 1 then
			return function(S)
				S[A] = S[B] .. S[C]
				return if Chain then Next(S) else Next
			end
		elseif C == B + 2 then
			return function(S)
				S[A] = S[B] .. S[B + 1] .. S[C]
				return if Chain then Next(S) else Next
			end
		end
	end
	-- A outside the operands: its old value is dropped first. The host collects after the instruction, once A
	-- holds the result; here the collection step runs inside the expression, before the store.
	if C == B + 1 then
		return function(S)
			S[A] = nil
			S[A] = S[B] .. S[C]
			return if Chain then Next(S) else Next
		end
	elseif C == B + 2 then
		return function(S)
			S[A] = nil
			S[A] = S[B] .. S[B + 1] .. S[C]
			return if Chain then Next(S) else Next
		end
	end
	return function(S)
		S[A] = nil
		local acc = S[C]
		for i = C - 1, B, -1 do
			acc = S[i] .. acc
		end
		S[A] = acc
		return if Chain then Next(S) else Next
	end
end

return Arith
