--!optimize 2
--!strict

-- Control-flow and dataflow analysis of one proto, producing the plan the Compiler turns into handlers.
--
-- Passes, in order:
--   1. decode words into operand arrays
--   2. successors: no-ops and unconditional jumps are threaded away; for loops are recognized
--   3. folding: inside a basic block, loads that only feed a CALL (callee, arguments, NAMECALL), a compare or a
--      numeric for loop's setup are folded into it and their handlers removed; error/assert loads get positions
--   4. fusion: branches over two LOADBs become boolean stores (or returns); hot adjacent pairs share one handler
--   5. loops: every remaining backward edge closes a "back loop"; regions must nest (structured code)
--   6. edge planning: each edge is chained (called), returned to a trampoline, or a loop's continue token

local Types = require("./Types")
local Runtime = require("./Runtime")

type Proto = Types.Proto

local band = bit32.band
local rshift = bit32.rshift

local BASE = Runtime.BASE

-- Longest run of directly chained handlers before one returns its successor to a trampoline.
local CHAIN_LIMIT = 32

-- Calls are entered from a trampoline so VM recursion costs a constant number of host frames per level.
local BOUNCE_CALLS = true

-- Most instructions a call's operand loads are searched back over.
local WINDOW = 10

local Op = {
	LOADNIL = 2, LOADB = 3, LOADN = 4, LOADK = 5, MOVE = 6, GETGLOBAL = 7, SETGLOBAL = 8, GETUPVAL = 9,
	SETUPVAL = 10, CLOSEUPVALS = 11, GETIMPORT = 12, GETTABLE = 13, SETTABLE = 14, GETTABLEKS = 15,
	SETTABLEKS = 16, GETTABLEN = 17, SETTABLEN = 18, NEWCLOSURE = 19, NAMECALL = 20, CALL = 21, RETURN = 22,
	JUMP = 23, JUMPBACK = 24, JUMPIF = 25, JUMPIFNOT = 26, JUMPIFEQ = 27, JUMPIFLE = 28, JUMPIFLT = 29,
	JUMPIFNOTEQ = 30, JUMPIFNOTLE = 31, JUMPIFNOTLT = 32, ADD = 33, SUB = 34, MUL = 35, DIV = 36, MOD = 37,
	POW = 38, ADDK = 39, SUBK = 40, MULK = 41, DIVK = 42, MODK = 43, POWK = 44, AND = 45, OR = 46, ANDK = 47,
	ORK = 48, CONCAT = 49, NOT = 50, MINUS = 51, LENGTH = 52, NEWTABLE = 53, DUPTABLE = 54, SETLIST = 55,
	FORNPREP = 56, FORNLOOP = 57, FORGLOOP = 58, FORGPREP_INEXT = 59, FASTCALL3 = 60, FORGPREP_NEXT = 61,
	NATIVECALL = 62, GETVARARGS = 63, DUPCLOSURE = 64, PREPVARARGS = 65, LOADKX = 66, JUMPX = 67, FASTCALL = 68,
	COVERAGE = 69, CAPTURE = 70, SUBRK = 71, DIVRK = 72, FASTCALL1 = 73, FASTCALL2 = 74, FASTCALL2K = 75,
	FORGPREP = 76, JUMPXEQKNIL = 77, JUMPXEQKB = 78, JUMPXEQKN = 79, JUMPXEQKS = 80, IDIV = 81, IDIVK = 82,
	GETUDATAKS = 83, SETUDATAKS = 84, NAMECALLUDATA = 85, NEWCLASSMEMBER = 86, CALLFB = 87, CMPPROTO = 88,
	FASTPCALL = 89,
}

local function Set(list: { number }): { [number]: boolean }
	local set = {}
	for _, v in list do
		set[v] = true
	end
	return set
end

-- Opcodes followed by an AUX word.
local HAS_AUX = Set({ 7, 8, 12, 15, 16, 20, 27, 28, 29, 30, 31, 32, 53, 55, 58, 60, 66, 74, 75, 77, 78, 79, 80, 83, 84, 85, 86, 87, 88, 90, 91, 93, 94 })

-- No runtime effect here. Fast calls are hints: the CALL they guard still runs (and is specialized on its own).
local REMOVED = Set({ 0, 1, 60, 62, 65, 68, 69, 70, 73, 74, 75, 89 })

-- Unconditional jumps; CMPPROTO never matches a host closure, so it always takes its jump.
local PURE_JUMP = Set({ Op.JUMP, Op.JUMPBACK, Op.JUMPX, Op.CMPPROTO })

local BRANCH = Set({ 25, 26, 27, 28, 29, 30, 31, 32, 77, 78, 79, 80 })

local FORG_PREP = Set({ Op.FORGPREP, Op.FORGPREP_INEXT, Op.FORGPREP_NEXT })

-- Loads whose only effect is writing register A from a value fixed for the rest of the block.
local CONST_LOAD = Set({ Op.LOADNIL, Op.LOADB, Op.LOADN, Op.LOADK, Op.LOADKX })

-- Instructions that cannot run guest code or metamethods; NAMECALL folding only crosses these.
local PURE = Set({ Op.LOADNIL, Op.LOADB, Op.LOADN, Op.LOADK, Op.LOADKX, Op.MOVE, Op.GETUPVAL, Op.GETIMPORT })

export type Loop = {
	Kind: "numeric" | "generic" | "back",
	Head: number, -- pc owning the loop handler
	Lo: number, -- region bounds (pcs), inclusive
	Hi: number,
	Cont: number, -- pc whose incoming edges from inside the region continue the loop
	Token: { any },
	Members: { [any]: boolean },
	MemberPcs: { number },
	Parent: Loop?,
}

export type Edge = {
	Pc: number,
	Chain: boolean,
	Loop: Loop?, -- set when the edge continues this loop (returns its token)
}

-- Operand of a folded call: register r >= 0, or -c for constant slot c.
export type CallPlan = {
	Kind: "call" | "namecall" | "select",
	Callee: number?, -- operand holding the function
	CalleeUp: number?, -- or upvalue index (1-based) of a by-value upvalue holding it
	Args: { number },
	Object: number?, -- namecall: register of the object
	Method: string?, -- namecall: method name
}

-- A branch over two LOADBs: stores the condition in Reg (negated when Invert), and returns it when Return is set.
export type Bool = { Reg: number, Invert: boolean, Return: boolean }

export type Program = {
	Op: { number },
	A: { number },
	B: { number },
	C: { number },
	D: { number },
	Aux: { number },
	Len: { number },
	Live: { number },
	Entry: number,
	EdgeN: { [number]: Edge },
	EdgeT: { [number]: Edge },
	BodyEdge: { [number]: Edge },
	LoopAt: { [number]: Loop },
	Wrappers: { [number]: { Loop } },
	Loops: { Loop },
	Tail: { [number]: boolean },
	Kept: { [number]: boolean },
	Calls: { [number]: CallPlan },
	Pairs: { [number]: number }, -- first pc of a fused pair -> second pc
	Bools: { [number]: Bool }, -- branches that only materialize a boolean
	ForOperands: { [number]: { number } }, -- FORNPREP: limit, step, start operands
	CompareK: { [number]: { Side: "A" | "B", Operand: number } }, -- compare operand replaced by a constant slot
	Imports: { [number]: any }, -- resolved GETIMPORT values by pc (safe environments only)
	Positioned: { [number]: number }, -- GETIMPORT of error/assert -> pc of the call it feeds
	Consts: { any },
	ConstCount: number,
	Base: number, -- frame index of register 0
}

local Analysis = {}

Analysis.Op = Op
Analysis.HAS_AUX = HAS_AUX

-- Resolves an import path against the environment; nil when any step is missing.
local function ResolveImport(env: any, path: { any }): any
	local v = env[path[1]]
	for i = 2, #path do
		if v == nil then
			return nil
		end
		v = v[path[i]]
	end
	return v
end

-- Decodes the key path of a GETIMPORT.
-- @param id number – AUX word: count in the top 2 bits, three 10-bit constant indices
function Analysis.ImportPath(K: { any }, id: number): { any }
	local path = { K[band(rshift(id, 20), 0x3FF) + 1] }
	local count = rshift(id, 30)
	if count > 1 then
		path[2] = K[band(rshift(id, 10), 0x3FF) + 1]
	end
	if count > 2 then
		path[3] = K[band(id, 0x3FF) + 1]
	end
	return path
end

-- Analyzes a proto.
-- @param proto Proto – deserialized proto
-- @param cells { boolean } – which upvalues of this proto are shared cells
-- @param env table – environment imports resolve against
-- @param safeEnv boolean – whether imports may be resolved once, here
function Analysis.Analyze(proto: Proto, cells: { boolean }, env: any, safeEnv: boolean): Program
	local code = proto.Code
	local K = proto.Constants
	local size = #code

	-- 1. decode
	local OpOf: { number } = {}
	local A: { number } = {}
	local B: { number } = {}
	local C: { number } = {}
	local D: { number } = {}
	local Aux: { number } = {}
	local Len: { number } = {}
	local order: { number } = {}

	do
		local pc = 1
		while pc <= size do
			local w = code[pc]
			local op = band(w, 0xFF)
			local d = rshift(w, 16)
			OpOf[pc] = op
			A[pc] = band(rshift(w, 8), 0xFF)
			B[pc] = band(d, 0xFF)
			C[pc] = rshift(w, 24)
			D[pc] = if d >= 0x8000 then d - 0x10000 else d
			local len = if HAS_AUX[op] then 2 else 1
			Len[pc] = len
			if len == 2 then
				Aux[pc] = code[pc + 1]
			end
			table.insert(order, pc)
			pc += len
		end
	end

	local function JumpTarget(pc: number): number
		if OpOf[pc] == Op.JUMPX then
			local e = rshift(code[pc], 8)
			return pc + 1 + (if e >= 0x800000 then e - 0x1000000 else e)
		end
		return pc + 1 + D[pc]
	end

	-- 2. successors
	local kept: { [number]: boolean } = {}
	local skip: { [number]: boolean } = {}

	-- The instruction control really reaches from pc once no-ops, folded loads and unconditional jumps are skipped.
	-- A jump to itself (while true do end) is kept as a live instruction.
	local function Resolve(pc: number): number
		local hops = 0
		while pc <= size do
			local op = OpOf[pc]
			if REMOVED[op] or skip[pc] then
				pc += Len[pc]
			elseif PURE_JUMP[op] and not kept[pc] then
				local target = JumpTarget(pc)
				if target == pc then
					kept[pc] = true
					return pc
				end
				hops += 1
				if hops > size then
					error("jump cycle in bytecode", 0)
				end
				pc = target
			else
				return pc
			end
		end
		error("control flow runs past the end of the function", 0)
	end

	local live: { number } = {}
	local NextPc: { [number]: number } = {}
	local TargetPc: { [number]: number } = {}
	local Tail: { [number]: boolean } = {}
	local loops: { Loop } = {}
	local LoopAt: { [number]: Loop } = {}

	local function NewLoop(kind: "numeric" | "generic" | "back", head: number, lo: number, hi: number, cont: number): Loop
		local loop: Loop = { Kind = kind, Head = head, Lo = lo, Hi = hi, Cont = cont, Token = {}, Members = {}, MemberPcs = {} }
		table.insert(loops, loop)
		return loop
	end

	for _, pc in order do
		local op = OpOf[pc]
		if REMOVED[op] or op == Op.FORNLOOP or op == Op.FORGLOOP or (PURE_JUMP[op] and not kept[pc]) then
			continue
		end
		table.insert(live, pc)

		if op == Op.RETURN then
			-- no successor
		elseif kept[pc] then
			NextPc[pc] = pc
		elseif BRANCH[op] then
			NextPc[pc] = Resolve(pc + Len[pc])
			TargetPc[pc] = Resolve(JumpTarget(pc))
		elseif op == Op.LOADB then
			NextPc[pc] = Resolve(pc + 1 + C[pc])
		elseif op == Op.FORNPREP then
			local last = pc + D[pc]
			assert(OpOf[last] == Op.FORNLOOP, "malformed numeric for loop")
			LoopAt[pc] = NewLoop("numeric", pc, pc + 1, last, last)
			NextPc[pc] = Resolve(last + 1)
			TargetPc[pc] = Resolve(pc + 1)
		elseif FORG_PREP[op] then
			local last = JumpTarget(pc)
			assert(OpOf[last] == Op.FORGLOOP, "malformed generic for loop")
			LoopAt[pc] = NewLoop("generic", pc, pc + 1, last, last)
			NextPc[pc] = Resolve(last + 2)
			TargetPc[pc] = Resolve(pc + 1)
		elseif (op == Op.CALL or op == Op.CALLFB) and C[pc] == 0 then
			local after = Resolve(pc + Len[pc])
			if OpOf[after] == Op.RETURN and A[after] == A[pc] and B[after] == 0 then
				Tail[pc] = true
			else
				NextPc[pc] = after
			end
		else
			NextPc[pc] = Resolve(pc + Len[pc])
		end
	end
	local entry = Resolve(1)

	-- CLOSEUPVALS right before RETURN is redundant: the factory closes every cell when the function exits
	local redundantCloses = {}
	for _, pc in live do
		if OpOf[pc] == Op.CLOSEUPVALS and OpOf[NextPc[pc]] == Op.RETURN then
			table.insert(redundantCloses, pc)
		end
	end

	-- 3. folding
	local preds: { [number]: number } = {}
	local predOf: { [number]: number } = {}
	local function AddPred(src: number?, dst: number?)
		if dst then
			preds[dst] = (preds[dst] or 0) + 1
			if src then
				predOf[dst] = src
			end
		end
	end
	AddPred(nil, entry)
	for _, pc in live do
		AddPred(pc, NextPc[pc])
		AddPred(pc, TargetPc[pc])
	end

	-- registers captured by reference can change behind a call, so their reads are never moved
	local refCaptured: { [number]: boolean } = {}
	for _, pc in order do
		if OpOf[pc] == Op.CAPTURE and A[pc] == 1 then
			refCaptured[B[pc]] = true
		end
	end

	-- Register effects of an instruction; nil when unknown (the window stops there).
	-- Returns the written range and a reads predicate.
	local INF = math.huge
	local calls: { [number]: CallPlan } = {}
	local function none(_r: number): boolean
		return false
	end
	local function Effects(pc: number): (number?, number, (number) -> boolean)
		local op, a, b, c = OpOf[pc], A[pc], B[pc], C[pc]
		if skip[pc] then
			-- folded into a later call: no longer runs
			return -1, -1, none
		end
		local plan = calls[pc]
		if plan then
			-- a folded call reads its operands where they live
			local hi = a + b - 1
			return a, if c == 0 then INF else a + c - 2, function(r)
				if r >= a and r <= hi then
					return true
				end
				if plan.Callee == r or plan.Object == r then
					return true
				end
				return table.find(plan.Args, r) ~= nil
			end
		end
		if CONST_LOAD[op] or op == Op.GETGLOBAL or op == Op.GETIMPORT or op == Op.GETUPVAL or op == Op.NEWTABLE or op == Op.DUPTABLE then
			return a, a, none
		elseif op == Op.MOVE or op == Op.GETTABLEKS or op == Op.GETTABLEN or op == Op.GETUDATAKS or op == Op.NOT or op == Op.MINUS or op == Op.LENGTH
			or (op >= Op.ADDK and op <= Op.POWK) or op == Op.IDIVK or op == Op.ANDK or op == Op.ORK
		then
			return a, a, function(r)
				return r == b
			end
		elseif (op >= Op.ADD and op <= Op.POW) or op == Op.IDIV or op == Op.AND or op == Op.OR or op == Op.GETTABLE then
			return a, a, function(r)
				return r == b or r == c
			end
		elseif op == Op.SUBRK or op == Op.DIVRK then
			return a, a, function(r)
				return r == c
			end
		elseif op == Op.CONCAT then
			return a, a, function(r)
				return r >= b and r <= c
			end
		elseif op == Op.NAMECALL or op == Op.NAMECALLUDATA then
			return a, a + 1, function(r)
				return r == b
			end
		elseif op == Op.SETTABLE then
			return -1, -1, function(r)
				return r == a or r == b or r == c
			end
		elseif op == Op.SETTABLEKS or op == Op.SETTABLEN or op == Op.SETUDATAKS then
			return -1, -1, function(r)
				return r == a or r == b
			end
		elseif op == Op.SETGLOBAL or op == Op.SETUPVAL then
			return -1, -1, function(r)
				return r == a
			end
		elseif (op == Op.CALL or op == Op.CALLFB) and not Tail[pc] then
			local readHi = if b == 0 then INF else a + b - 1
			return a, if c == 0 then INF else a + c - 2, function(r)
				return r >= a and r <= readHi
			end
		elseif op == Op.GETVARARGS then
			return a, if b == 0 then INF else a + b - 2, none
		end
		return nil, 0, none
	end

	-- constant slots: values preloaded in front of the registers so folded constants read like registers
	local consts: { any } = {}
	local constCount = 0
	local constIndex: { [any]: number } = {}
	local nilSlot: number? = nil
	local function ConstSlot(value: any): number
		if value == nil then
			if not nilSlot then
				constCount += 1
				nilSlot = constCount
			end
			return -(nilSlot :: number)
		end
		-- NaN cannot be a key and -0 would share 0's key, so neither is shared
		local shareable = value == value and not (value == 0 and 1 / value < 0)
		local slot = if shareable then constIndex[value] else nil
		if not slot then
			constCount += 1
			slot = constCount
			consts[slot] = value
			if shareable then
				constIndex[value] = slot
			end
		end
		return -(slot :: number)
	end

	local imports: { [number]: any } = {}
	local function ImportValue(pc: number): any
		if not safeEnv then
			return nil
		end
		local value = imports[pc]
		if value == nil then
			value = ResolveImport(env, Analysis.ImportPath(K, Aux[pc]))
			imports[pc] = value
		end
		return value
	end

	local function ConstValue(pc: number): any
		local op = OpOf[pc]
		if op == Op.LOADNIL then
			return nil
		elseif op == Op.LOADB then
			return B[pc] ~= 0
		elseif op == Op.LOADN then
			return D[pc]
		elseif op == Op.LOADK then
			return K[D[pc] + 1]
		end
		return K[Aux[pc] + 1] -- LOADKX
	end

	-- The straight-line block ending at pc: instructions that reach pc and nothing else, nearest first.
	local function Window(pc: number): { number }
		local window = {}
		local cur = pc
		while #window < WINDOW and preds[cur] == 1 do
			local p = predOf[cur]
			if not p or NextPc[p] ~= cur or TargetPc[p] or LoopAt[p] or Effects(p) == nil then
				break
			end
			table.insert(window, p)
			cur = p
		end
		return window
	end

	-- Finds the load that last wrote register r before the call, provided nothing in between reads r.
	-- @param window { number } – block before the call, nearest first
	local function Writer(window: { number }, r: number): (number?, number)
		for i, w in window do
			local lo, hi, reads = Effects(w)
			if lo and r >= lo and r <= hi then
				return w, i
			end
			if reads(r) then
				return nil, i
			end
		end
		return nil, 0
	end

	-- Whether register x keeps its value from window position i down to the call.
	local function Stable(window: { number }, i: number, x: number): boolean
		if refCaptured[x] then
			return false
		end
		for j = 1, i - 1 do
			local lo, hi = Effects(window[j])
			if lo and x >= lo and x <= hi then
				return false
			end
		end
		return true
	end

	-- Folds the load feeding register r into an operand; returns the operand or nil.
	-- @param allowUpvalue boolean – whether a by-value upvalue may be returned (callee position only)
	local function Fold(window: { number }, r: number, lo: number, hi: number, allowUpvalue: boolean): (number?, number?)
		local w, i = Writer(window, r)
		if not w then
			return nil, nil
		end
		local op = OpOf[w]
		if CONST_LOAD[op] then
			skip[w] = true
			return ConstSlot(ConstValue(w)), nil
		elseif op == Op.GETIMPORT then
			local value = ImportValue(w)
			if value ~= nil then
				skip[w] = true
				return ConstSlot(value), nil
			end
		elseif op == Op.MOVE then
			local x = B[w]
			if (x < lo or x > hi) and Stable(window, i, x) then
				skip[w] = true
				return x, nil
			end
		elseif op == Op.GETUPVAL and allowUpvalue and not cells[B[w] + 1] then
			skip[w] = true
			return nil, B[w] + 1
		end
		return nil, nil
	end

	local selectFn = (select :: any)

	-- error/assert loaded only to be called: the load can produce a wrapper that knows the call's position
	local positioned: { [number]: number } = {}
	for _, pc in live do
		local op = OpOf[pc]
		if op == Op.CALL or op == Op.CALLFB then
			local w = Writer(Window(pc), A[pc])
			if w and OpOf[w] == Op.GETIMPORT then
				local value = ImportValue(w)
				if rawequal(value, error) or rawequal(value, assert) then
					positioned[w] = pc
				end
			end
		end
	end

	for _, pc in live do
		local op = OpOf[pc]
		if (op ~= Op.CALL and op ~= Op.CALLFB) or Tail[pc] then
			continue
		end
		local a, nargs = A[pc], B[pc] - 1
		local window = Window(pc)

		if nargs < 0 then
			-- select(i, ...): callee is the real select, the first argument a fixed load, the rest GETVARARGS
			local tailLoad = window[1]
			if tailLoad and OpOf[tailLoad] == Op.GETVARARGS and B[tailLoad] == 0 and A[tailLoad] == a + 2 and C[pc] == 2 then
				local w = Writer(window, a)
				if w and OpOf[w] == Op.GETIMPORT and rawequal(ImportValue(w), selectFn) then
					local index = Fold(window, a + 1, a, a + 2, false) or (a + 1)
					skip[w] = true
					skip[tailLoad] = true
					calls[pc] = { Kind = "select", Args = { index } }
				end
			end
			continue
		end
		if nargs > 3 then
			continue
		end

		-- method calls: NAMECALL directly feeding this call through pure argument loads
		local namecall: number? = nil
		do
			local w = Writer(window, a)
			if w and (OpOf[w] == Op.NAMECALL or OpOf[w] == Op.NAMECALLUDATA) and nargs >= 1 then
				local pure = true
				for _, p in window do
					if p == w then
						break
					end
					if not PURE[OpOf[p]] then
						pure = false
						break
					end
				end
				local object = B[w]
				local _, at = Writer(window, a)
				if pure and Stable(window, at, object) and (object < a + 2 or object > a + nargs) then
					namecall = w
				end
			end
		end

		local args = {}
		for k = 1, nargs do
			if namecall and k == 1 then
				continue
			end
			local operand = Fold(window, a + k, a, a + nargs, false)
			args[k] = operand or (a + k)
		end

		if namecall then
			skip[namecall] = true
			local key = K[(if OpOf[namecall] == Op.NAMECALLUDATA then band(Aux[namecall], 0xFFFF) else Aux[namecall]) + 1]
			args[1] = B[namecall]
			calls[pc] = { Kind = "namecall", Args = args, Object = B[namecall], Method = key }
		else
			local callee, up = Fold(window, a, a, a + nargs, true)
			calls[pc] = { Kind = "call", Callee = callee or (if up then nil else a), CalleeUp = up, Args = args }
		end
	end

	for _, pc in redundantCloses do
		skip[pc] = true
	end

	-- folded loads disappear: re-thread every edge past them
	local function Rethread()
		if not next(skip) then
			return
		end
		for _, pc in live do
			if NextPc[pc] then
				NextPc[pc] = Resolve(NextPc[pc])
			end
			if TargetPc[pc] then
				TargetPc[pc] = Resolve(TargetPc[pc])
			end
		end
		entry = Resolve(entry)
		local remaining = {}
		for _, pc in live do
			if not skip[pc] then
				table.insert(remaining, pc)
			end
		end
		live = remaining
	end
	Rethread()

	-- Whether register r is overwritten before any read on every path leaving pc (bounded search; unsure means live).
	local function DeadAfter(pc: number, r: number): boolean
		if refCaptured[r] then
			return false
		end
		local stack = { NextPc[pc], TargetPc[pc] }
		local seen: { [number]: boolean } = {}
		local budget = 32
		while #stack > 0 do
			local p = table.remove(stack) :: number
			if seen[p] then
				continue
			end
			seen[p] = true
			budget -= 1
			if budget < 0 or LoopAt[p] or Tail[p] or kept[p] then
				return false
			end
			local op = OpOf[p]
			if op == Op.RETURN then
				local b = B[p]
				if r >= A[p] and (b == 0 or r <= A[p] + b - 2) then
					return false
				end
			elseif BRANCH[op] then
				if A[p] == r or ((op >= Op.JUMPIFEQ and op <= Op.JUMPIFNOTLT) and Aux[p] == r) then
					return false
				end
				table.insert(stack, NextPc[p])
				table.insert(stack, TargetPc[p])
			else
				local lo, hi, reads = Effects(p)
				if lo == nil or reads(r) then
					return false
				end
				if not (r >= lo and r <= hi) then
					local n = NextPc[p]
					if n == nil then
						return false
					end
					table.insert(stack, n)
				end
			end
		end
		return true
	end

	-- compares against a constant loaded into a temporary read the constant slot instead
	local compareK: { [number]: { Side: "A" | "B", Operand: number } } = {}
	for _, pc in live do
		local op = OpOf[pc]
		if op < Op.JUMPIFEQ or op > Op.JUMPIFNOTLT then
			continue
		end
		local window = Window(pc)
		for _, side in { "B", "A" } do
			local r = if side == "B" then Aux[pc] else A[pc]
			local other = if side == "B" then A[pc] else Aux[pc]
			if r == other then
				continue
			end
			local w = Writer(window, r)
			if w and CONST_LOAD[OpOf[w]] and DeadAfter(pc, r) then
				skip[w] = true
				compareK[pc] = { Side = side :: any, Operand = ConstSlot(ConstValue(w)) }
				break
			end
		end
	end
	Rethread()

	-- numeric loops read their setup operands where they live, so constant and copied bounds need no handlers
	local forOperands: { [number]: { number } } = {}
	for _, pc in live do
		if OpOf[pc] == Op.FORNPREP then
			local a = A[pc]
			local window = Window(pc)
			local limit = Fold(window, a, a, a + 2, false) or a
			local step = Fold(window, a + 1, a, a + 2, false) or (a + 1)
			local start = Fold(window, a + 2, a, a + 2, false) or (a + 2)
			forOperands[pc] = { limit, step, start }
		end
	end
	Rethread()

	-- 4. fusion
	-- `x = a < b` compiles to a branch over two LOADBs; it becomes one handler storing the condition
	local bools: { [number]: Bool } = {}
	do
		local predCount: { [number]: number } = {}
		for _, pc in live do
			for _, dst in { NextPc[pc], TargetPc[pc] } do
				predCount[dst] = (predCount[dst] or 0) + 1
			end
		end
		local absorbed: { [number]: boolean } = {}
		for _, pc in live do
			local n, t = NextPc[pc], TargetPc[pc]
			if not BRANCH[OpOf[pc]] or not n or not t or n == t then
				continue
			end
			if OpOf[n] == Op.LOADB and OpOf[t] == Op.LOADB and A[n] == A[t] and predCount[n] == 1 and predCount[t] == 1
				and NextPc[n] == NextPc[t] and (B[n] ~= 0) ~= (B[t] ~= 0) and n > pc and t > pc and not kept[n] and not kept[t]
			then
				local after = NextPc[n]
				local returns = OpOf[after] == Op.RETURN and A[after] == A[n] and B[after] == 2 and predCount[after] == 2
				bools[pc] = { Reg = A[n], Invert = B[t] == 0, Return = returns }
				NextPc[pc] = if returns then nil :: any else after
				if returns then
					absorbed[after] = true
				end
				TargetPc[pc] = nil :: any
				absorbed[n] = true
				absorbed[t] = true
			end
		end
		if next(absorbed) then
			local remaining = {}
			for _, pc in live do
				if not absorbed[pc] then
					table.insert(remaining, pc)
				end
			end
			live = remaining
		end
	end

	-- adjacent pairs with a fused handler (see Ops/Fused): the second instruction is absorbed by the first
	local pairs: { [number]: number } = {}
	do
		local predCount: { [number]: number } = {}
		predCount[entry] = 1
		for _, pc in live do
			for _, dst in { NextPc[pc], TargetPc[pc] } do
				predCount[dst] = (predCount[dst] or 0) + 1
			end
		end

		local function IsGetK(op: number): boolean
			return op == Op.GETTABLEKS or op == Op.GETTABLEN
		end
		local function IsSetK(op: number): boolean
			return op == Op.SETTABLEKS or op == Op.SETTABLEN
		end
		local function IsRR(op: number): boolean
			return op >= Op.ADD and op <= Op.DIV
		end
		local function IsRK(op: number): boolean
			return op >= Op.ADDK and op <= Op.DIVK
		end

		local function Fusable(p1: number, p2: number): boolean
			local o1, o2 = OpOf[p1], OpOf[p2]
			local a1 = A[p1]
			if IsGetK(o1) then
				return IsGetK(o2)
					or (IsSetK(o2) and A[p2] == a1)
					or (IsRR(o2) and (B[p2] == a1 or C[p2] == a1))
					or (IsRK(o2) and B[p2] == a1)
			elseif IsSetK(o1) then
				return IsGetK(o2)
			elseif o1 == Op.GETUPVAL and not cells[B[p1] + 1] then
				return (IsGetK(o2) or o2 == Op.GETTABLE) and B[p2] == a1
			elseif o1 == Op.GETTABLE then
				return IsRR(o2) and (B[p2] == a1 or C[p2] == a1)
			elseif IsRR(o1) then
				return ((IsSetK(o2) or o2 == Op.SETTABLE) and A[p2] == a1)
					or (IsRR(o2) and (B[p2] == a1 or C[p2] == a1))
					or (IsRK(o2) and B[p2] == a1)
			elseif IsRK(o1) then
				return (IsSetK(o2) or o2 == Op.SETTABLE) and A[p2] == a1
			end
			return false
		end

		-- a computed value tested by the branch right after it (`if t.x then`, `if i % 3 == 0 then`)
		local function FusableBranch(p1: number, p2: number): boolean
			local o1, o2 = OpOf[p1], OpOf[p2]
			if bools[p2] or A[p2] ~= A[p1] then
				return false
			end
			local tests = o2 == Op.JUMPIF or o2 == Op.JUMPIFNOT or (o2 >= Op.JUMPXEQKNIL and o2 <= Op.JUMPXEQKS)
			return tests and (IsGetK(o1) or o1 == Op.GETTABLE or o1 == Op.MODK)
		end

		local absorbed: { [number]: boolean } = {}
		for _, p1 in live do
			if absorbed[p1] or TargetPc[p1] or LoopAt[p1] or kept[p1] then
				continue
			end
			local p2 = NextPc[p1]
			if p2 and p2 > p1 and predCount[p2] == 1 and TargetPc[p2] and NextPc[p2] and FusableBranch(p1, p2) then
				pairs[p1] = p2
				absorbed[p2] = true
				NextPc[p1] = NextPc[p2]
				TargetPc[p1] = TargetPc[p2]
				continue
			end
			if p2 and p2 > p1 and predCount[p2] == 1 and not LoopAt[p2] and not kept[p2] and not TargetPc[p2]
				and NextPc[p2] and Fusable(p1, p2)
			then
				pairs[p1] = p2
				absorbed[p2] = true
				NextPc[p1] = NextPc[p2]
			end
		end
		if next(absorbed) then
			local remaining = {}
			for _, pc in live do
				if not absorbed[pc] then
					table.insert(remaining, pc)
				end
			end
			live = remaining
		end
	end

	-- 5. back loops: every backward edge closes the region from its target to its furthest source;
	-- a for loop's exit leaves from its whole region, so a back loop it closes must contain all of it
	local backHi: { [number]: number } = {}
	local function NoteBack(src: number, dst: number?)
		local reach = if LoopAt[src] then LoopAt[src].Hi else src
		if dst and dst <= src then
			backHi[dst] = math.max(backHi[dst] or 0, reach)
		end
	end
	for _, pc in live do
		NoteBack(pc, NextPc[pc])
		if not LoopAt[pc] then
			NoteBack(pc, TargetPc[pc])
		end
	end
	local wrappers: { [number]: { Loop } } = {}
	for header, hi in backHi do
		local loop = NewLoop("back", header, header, hi, header)
		wrappers[header] = wrappers[header] or {}
		table.insert(wrappers[header], loop)
	end
	for _, list in wrappers do
		table.sort(list, function(x, y)
			return x.Hi < y.Hi
		end)
	end

	-- nesting: parents sort before children; partially overlapping regions are not structured code
	table.sort(loops, function(x, y)
		if x.Lo ~= y.Lo then
			return x.Lo < y.Lo
		end
		return x.Hi > y.Hi
	end)
	local Inner: { [number]: Loop } = {}
	do
		local stack: { Loop } = {}
		for _, loop in loops do
			while #stack > 0 and stack[#stack].Hi < loop.Lo do
				table.remove(stack)
			end
			local parent = stack[#stack]
			if parent then
				if loop.Hi > parent.Hi then
					error("unstructured control flow in bytecode", 0)
				end
				loop.Parent = parent
			end
			table.insert(stack, loop)
		end
		for _, loop in loops do
			for pc = loop.Lo, loop.Hi do
				Inner[pc] = loop
			end
		end
	end

	local function Contains(loop: Loop, pc: number): boolean
		return loop.Lo <= pc and pc <= loop.Hi
	end

	local function IsCall(pc: number): boolean
		local op = OpOf[pc]
		return (op == Op.CALL or op == Op.CALLFB) and wrappers[pc] == nil
	end

	-- 6. edge planning, in forward order so chain depths are final before they are read
	local Depth: { [number]: number } = {}
	local EdgeN: { [number]: Edge } = {}
	local EdgeT: { [number]: Edge } = {}
	local BodyEdge: { [number]: Edge } = {}

	-- Registers a returned edge with the trampoline that will receive it.
	local function Bounce(src: number, dst: number)
		local loop = Inner[src]
		while loop and not Contains(loop, dst) do
			loop = loop.Parent
		end
		if loop then
			table.insert(loop.MemberPcs, dst)
		end
		Depth[dst] = math.max(Depth[dst] or 0, 1)
	end

	local function Plan(src: number, dst: number): Edge
		local loop = Inner[src]
		while loop do
			if loop.Cont == dst then
				return { Pc = dst, Chain = false, Loop = loop }
			end
			loop = loop.Parent
		end

		-- the only way into a loop region from outside is through its header
		loop = Inner[dst]
		while loop do
			if not Contains(loop, src) and not (loop.Kind == "back" and dst == loop.Lo) then
				error("jump into a loop body in bytecode", 0)
			end
			loop = loop.Parent
		end

		local here = Inner[src]
		local depth = Depth[src] or 1
		local chain = dst > src
			and (here == nil or dst <= here.Hi)
			and depth < CHAIN_LIMIT
			and not (BOUNCE_CALLS and IsCall(dst))
		if chain then
			Depth[dst] = math.max(Depth[dst] or 0, depth + 1)
		else
			Bounce(src, dst)
		end
		return { Pc = dst, Chain = chain }
	end

	Depth[entry] = 1
	for _, pc in live do
		local loop = LoopAt[pc]
		if loop then
			-- the body is entered by the loop handler itself; an empty body continues or leaves at once
			local first = TargetPc[pc]
			if first == loop.Cont then
				BodyEdge[pc] = { Pc = first, Chain = false, Loop = loop }
			elseif not Contains(loop, first) then
				Bounce(pc, first)
				BodyEdge[pc] = { Pc = first, Chain = false }
			else
				Depth[first] = math.max(Depth[first] or 0, 1)
				BodyEdge[pc] = { Pc = first, Chain = true }
			end
			EdgeN[pc] = Plan(pc, NextPc[pc])
		else
			local n, t = NextPc[pc], TargetPc[pc]
			if n then
				EdgeN[pc] = Plan(pc, n)
			end
			if t then
				EdgeT[pc] = Plan(pc, t)
			end
		end
	end

	return {
		Op = OpOf,
		A = A,
		B = B,
		C = C,
		D = D,
		Aux = Aux,
		Len = Len,
		Live = live,
		Entry = entry,
		EdgeN = EdgeN,
		EdgeT = EdgeT,
		BodyEdge = BodyEdge,
		LoopAt = LoopAt,
		Wrappers = wrappers,
		Loops = loops,
		Tail = Tail,
		Kept = kept,
		Calls = calls,
		Pairs = pairs,
		Bools = bools,
		ForOperands = forOperands,
		CompareK = compareK,
		Imports = imports,
		Positioned = positioned,
		Consts = consts,
		ConstCount = constCount,
		Base = BASE + constCount,
	}
end

return Analysis
