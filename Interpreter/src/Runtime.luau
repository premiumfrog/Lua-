--!optimize 2
--!strict

-- Activation runtime: frame pooling, the function trampoline, the return protocol and upvalue cells.
-- Exists so handlers stay tiny: everything that happens once per call or once per capture lives here.

local Types = require("./Types")

type Frame = Types.Frame
type Handler = Types.Handler
type Factory = Types.Factory

local create = table.create
local unpack = table.unpack
local select = select

-- Frame slots
local UPVALUES, VARARGS, COUNT, CELLS, TOP = 1, 2, 3, 4, 5
local BASE = 6 -- register 0

-- Result kinds a RETURN handler leaves in slot COUNT
local RET_NONE, RET_ONE, RET_TWO, RET_RANGE, RET_TAIL = 0, 1, 2, 3, 4

-- Frames kept per proto for reuse; bounds how many stale register values a pool can pin.
local POOL_LIMIT = 16

local EMPTY = table.freeze({})

local Runtime = {}

Runtime.BASE = BASE
Runtime.UPVALUES = UPVALUES
Runtime.VARARGS = VARARGS
Runtime.COUNT = COUNT
Runtime.CELLS = CELLS
Runtime.TOP = TOP
Runtime.RET_NONE = RET_NONE
Runtime.RET_ONE = RET_ONE
Runtime.RET_TWO = RET_TWO
Runtime.RET_RANGE = RET_RANGE
Runtime.RET_TAIL = RET_TAIL

-- Returns the open cell for a register, creating it on first capture.
-- Cells are shared so every closure capturing the same local sees the same variable.
-- @param S Frame – frame owning the register
-- @param slot number – frame index of the register
function Runtime.Capture(S: Frame, slot: number): { any }
	local open = S[CELLS]
	if open == nil then
		open = {}
		S[CELLS] = open
	end
	local cell = open[slot]
	if cell == nil then
		-- [1] container, [2] key, [3] value once closed; slot 3 exists up front so closing never resizes
		cell = { S, slot, false }
		open[slot] = cell
	end
	return cell
end

-- Closes every open cell at or above a register (CLOSEUPVALS and function exit).
-- @param S Frame – frame owning the cells
-- @param from number – lowest frame index to close
function Runtime.Close(S: Frame, from: number)
	local open = S[CELLS]
	if open == nil then
		return
	end
	local remaining = false
	for slot, cell in open do
		if slot >= from then
			cell[3] = S[slot]
			cell[1] = cell
			cell[2] = 3
			open[slot] = nil
		else
			remaining = true
		end
	end
	if not remaining then
		S[CELLS] = nil
	end
end

local Close = Runtime.Close

-- Returns an empty table whose hash part has the size the host gives luaH_new(L, 0, count).
-- Why: insertion order into a presized hash decides traversal order, and scripts rely on matching the host.
-- Growing through inserts leaves the same node count but different collision chains, so the dummy keys are
-- cleared (table.clear also resets the free-slot cursor), leaving a fresh presized hash.
-- @param count number – number of hash keys the table is sized for
function Runtime.PresizedHash(count: number): { [any]: any }
	local t = {}
	if count > 0 then
		for i = 1, count do
			t[i + 0.5] = true
		end
		table.clear(t)
	end
	return t
end

-- Creates the host-closure factory of a compiled proto.
-- The call path is written out in full in each arity variant: a VM call costs one host frame (two with the
-- handler that made it) and a tail call reuses the factory's frame position, matching host recursion depth.
-- @param entry Handler – first handler of the proto
-- @param maxStack number – register count
-- @param params number – fixed parameter count
-- @param isVararg boolean – whether the proto takes ...
-- @param constants { any } – values preloaded into the constant slots in front of the registers
-- @param constCount number – constant slot count (constants may hold nils)
function Runtime.Factory(entry: Handler, maxStack: number, params: number, isVararg: boolean, constants: { any }, constCount: number): Factory
	local base = BASE + constCount
	-- at least three registers: the fixed-arity entry stores three arguments, and storing even nil into a slot
	-- outside the array part inserts a hash key (and rehashes) on every call
	local size = base + math.max(maxStack, 3)
	local spare: Frame? = nil
	local head: Frame? = nil
	local pooled = 0

	-- Allocates a frame with its constant slots filled; pooled frames keep them.
	local function Fresh(): Frame
		local S = create(size)
		for i = 1, constCount do
			S[BASE - 1 + i] = constants[i]
		end
		return S
	end

	if not isVararg and params <= 3 then
		local p1, p2 = base + 1, base + 2
		return function(upvalues: { any }): (...any) -> ...any
			-- extra parameters land in registers the proto never reads before writing
			return function(a: any, b: any, c: any): ...any
				local S = spare
				if S ~= nil then
					spare = nil
				else
					S = head
					if S ~= nil then
						head = S[TOP]
						pooled -= 1
					else
						S = Fresh()
					end
				end
				S[UPVALUES] = upvalues
				S[base], S[p1], S[p2] = a, b, c

				local f = entry(S)
				while f do
					f = f(S)
				end

				if S[CELLS] ~= nil then
					Close(S, BASE)
				end
				-- released before results are read: nothing can acquire it in between
				if spare == nil then
					spare = S
				elseif pooled < POOL_LIMIT then
					S[TOP] = head
					head = S
					pooled += 1
				end

				local kind = S[COUNT]
				if kind == RET_ONE then
					return S[1]
				elseif kind == RET_NONE then
					return
				elseif kind == RET_TWO then
					return S[1], S[2]
				elseif kind == RET_RANGE then
					return unpack(S, S[1], S[2])
				end
				-- RET_TAIL: callee index in S[1], argument count in S[2]
				local t, n = S[1], S[2]
				if n == 1 then
					return S[t](S[t + 1])
				elseif n == 2 then
					return S[t](S[t + 1], S[t + 2])
				elseif n == 0 then
					return S[t]()
				end
				return S[t](unpack(S, t + 1, t + n))
			end
		end
	end

	return function(upvalues: { any }): (...any) -> ...any
		return function(...: any): ...any
			local S = spare
			if S ~= nil then
				spare = nil
			else
				S = head
				if S ~= nil then
					head = S[TOP]
					pooled -= 1
				else
					S = Fresh()
				end
			end
			S[UPVALUES] = upvalues

			local n = select("#", ...)
			if n > 0 then
				local all = { ... }
				for i = 1, params do
					S[base - 1 + i] = all[i]
				end
				if isVararg and n > params then
					S[VARARGS] = table.move(all, params + 1, n, 1, create(n - params))
					S[COUNT] = n - params
				else
					S[VARARGS] = EMPTY
					S[COUNT] = 0
				end
			else
				for i = 1, params do
					S[base - 1 + i] = nil
				end
				S[VARARGS] = EMPTY
				S[COUNT] = 0
			end

			local f = entry(S)
			while f do
				f = f(S)
			end

			if S[CELLS] ~= nil then
				Close(S, BASE)
			end
			if spare == nil then
				spare = S
			elseif pooled < POOL_LIMIT then
				S[TOP] = head
				head = S
				pooled += 1
			end

			local kind = S[COUNT]
			if kind == RET_ONE then
				return S[1]
			elseif kind == RET_NONE then
				return
			elseif kind == RET_TWO then
				return S[1], S[2]
			elseif kind == RET_RANGE then
				return unpack(S, S[1], S[2])
			end
			local t, c = S[1], S[2]
			if c == 1 then
				return S[t](S[t + 1])
			elseif c == 2 then
				return S[t](S[t + 1], S[t + 2])
			elseif c == 0 then
				return S[t]()
			end
			return S[t](unpack(S, t + 1, t + c))
		end
	end
end

return Runtime
