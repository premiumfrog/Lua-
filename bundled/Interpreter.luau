--!optimize 2
--!strict

-- Luau bytecode interpreter written in Luau.
--
-- Usage:
--     local Interpreter = require(path.to.Interpreter)
--     local main = Interpreter.Load(bytecode, getfenv(), { SafeEnv = true })
--     main(...)
--
-- Bytecode is compiled once into closure graphs (see Compiler); running it involves no opcode dispatch.
--
-- This file is the whole interpreter, generated from src/ by tools/bundle.py: each section below is one module, in
-- dependency order. Edit src/ and regenerate rather than editing this file.

export type Proto = {
	MaxStack: number,
	Params: number,
	Upvalues: number,
	IsVararg: boolean,
	Flags: number,
	Code: { number },
	Constants: { any },
	Imports: { [number]: number }, -- constant index -> encoded import path
	Closures: { [number]: number }, -- constant index -> proto index (DUPCLOSURE)
	Children: { number }, -- child proto indices (NEWCLOSURE)
	Name: string?,
	Lines: { number }?, -- source line per code word, when compiled with line info
	Shapes: { [number]: number }, -- CONSTRUCT feedback slot -> constant index (1-based) of its table template
}

export type Chunk = {
	Protos: { Proto },
	Main: number,
	HasClasses: boolean, -- class bytecode: type/typeof/getmetatable and `class` reads become class-aware
}

export type Frame = { any }

export type Handler = (Frame) -> any

export type Factory = ({ any }) -> (...any) -> ...any

export type Options = {
	Vector: ((number, number, number, number) -> any)?, -- vector constant constructor
	SafeEnv: boolean?, -- resolve imports once at load (default true)
	ChunkName: string?, -- position prefix for errors raised by guest error()/assert() and method calls
	DynamicEnv: (boolean | any)?, -- per-closure environments with getfenv/setfenv; true or a state from NewEnvState
	Debug: boolean?, -- position host-raised errors (arithmetic on nil, calling nil) at the guest line; slower
}

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

export type CallPlan = {
	Kind: "call" | "namecall" | "select",
	Callee: number?, -- operand holding the function
	CalleeUp: number?, -- or upvalue index (1-based) of a by-value upvalue holding it
	Args: { number },
	Object: number?, -- namecall: register of the object
	Method: string?, -- namecall: method name
}

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
	EdgeE: { [number]: Edge }, -- numeric loops: exit taken when the loop runs zero times, if it differs
	LoopAt: { [number]: Loop },
	Wrappers: { [number]: { Loop } },
	Loops: { Loop },
	Tail: { [number]: boolean },
	Kept: { [number]: boolean },
	Calls: { [number]: CallPlan },
	Pairs: { [number]: number }, -- first pc of a fused pair -> second pc
	BranchDead: { [number]: boolean }, -- fused value+branch pairs whose value is never read after the branch
	Bools: { [number]: Bool }, -- branches that only materialize a boolean
	ForOperands: { [number]: { number } }, -- FORNPREP: limit, step, start operands
	CompareK: { [number]: { Side: "A" | "B", Operand: number } }, -- compare operand replaced by a constant slot
	Imports: { [number]: any }, -- resolved GETIMPORT values by pc (safe environments only)
	Positioned: { [number]: number }, -- GETIMPORT of error/assert -> pc of the call it feeds
	Consts: { any },
	ConstCount: number,
	Base: number, -- frame index of register 0
}

export type Class = {
	Name: string,
	Id: number,
	IsOpen: boolean,
	Super: Class?,
	Members: { [any]: number }, -- public member name -> offset
	Names: { [number]: string }, -- offset -> name; private fields and private methods have none
	NInstance: number,
	NMembers: number,
	NPrivateFields: number,
	OwnPrivateStart: number,
	NPrivateStatics: number,
	Statics: { any }, -- static offset + 1 -> value; private methods occupy the last NPrivateStatics slots
	HasUserInit: boolean,
	InstanceMeta: { [string]: any }?, -- user metamethods, inherited by subclasses
	ObjectMeta: { [any]: any }, -- metatable of instances
	Proxy: { [any]: any }, -- the guest-visible class value
}

export type EnvState = {
	Unsafe: { [any]: boolean }, -- environments exposed through getfenv/setfenv; their imports resolve per access
	Owners: { [any]: { any } }, -- VM closure -> its upvalue table
	getfenv: (any?) -> any,
	setfenv: (any, any) -> any,
}

-- Runtime.luau
local Module_Runtime = (function()
	-- Activation runtime: frame pooling, the function trampoline, the return protocol and upvalue cells.
	-- Exists so handlers stay tiny: everything that happens once per call or once per capture lives here.



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
end)()

-- Analysis.luau
local Module_Analysis = (function()
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

	local Runtime = Module_Runtime


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
		FASTPCALL = 89, NEWCLASS = 90, CONSTRUCT = 91, FINCONSTRUCT = 92, GETPRIVATEFIELD = 93, SETPRIVATEFIELD = 94,
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
	-- FINCONSTRUCT only skips the CALL after a CONSTRUCT that built the instance itself; CONSTRUCT here always leaves
	-- the property table, so the CALL constructs (the host's own fallback path).
	local REMOVED = Set({ 0, 1, 60, 62, 65, 68, 69, 70, 73, 74, 75, 89, 92 })

	-- Unconditional jumps; CMPPROTO never matches a host closure, so it always takes its jump.
	local PURE_JUMP = Set({ Op.JUMP, Op.JUMPBACK, Op.JUMPX, Op.CMPPROTO })

	local BRANCH = Set({ 25, 26, 27, 28, 29, 30, 31, 32, 77, 78, 79, 80 })

	local FORG_PREP = Set({ Op.FORGPREP, Op.FORGPREP_INEXT, Op.FORGPREP_NEXT })

	-- Loads whose only effect is writing register A from a value fixed for the rest of the block.
	local CONST_LOAD = Set({ Op.LOADNIL, Op.LOADB, Op.LOADN, Op.LOADK, Op.LOADKX })

	-- Instructions that cannot run guest code or metamethods; NAMECALL folding only crosses these.
	local PURE = Set({ Op.LOADNIL, Op.LOADB, Op.LOADN, Op.LOADK, Op.LOADKX, Op.MOVE, Op.GETUPVAL, Op.GETIMPORT })



	-- Operand of a folded call: register r >= 0, or -c for constant slot c.

	-- A branch over two LOADBs: stores the condition in Reg (negated when Invert), and returns it when Return is set.


	local Analysis = {}

	Analysis.Op = Op
	Analysis.HAS_AUX = HAS_AUX

	-- Resolves an import path against the environment at load time; nil when any step is missing or is not a table.
	-- Why: indexing anything else could run metamethods or raise at load, so those paths are left to run time.
	function Analysis.ResolveImport(env: any, path: { any }): any
		local v = env[path[1]]
		for i = 2, #path do
			if type(v) ~= "table" then
				return nil
			end
			v = v[path[i]]
		end
		return v
	end

	local ResolveImport = Analysis.ResolveImport

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
	-- @param noChain boolean? – return every edge to a trampoline (Debug mode: no host frame outlives its handler, so
	-- the GC sees only the guest registers, as on the host)
	-- @param resolve ((path) -> any)? – resolves an import at load in place of the environment walk (class chunks)
	function Analysis.Analyze(proto: Proto, cells: { boolean }, env: any, safeEnv: boolean, noChain: boolean?, resolve: (({ any }) -> any)?): Program
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
		local EmptyPc: { [number]: number } = {} -- FORNPREP whose zero-iteration exit differs from its normal exit
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
				-- the FORNLOOP closing this loop jumps back to the body start; the zero-iteration exit (FORNPREP's own
				-- jump) usually lands right after it, but the compiler may thread it elsewhere
				local last = pc + 1
				while last <= size and not (OpOf[last] == Op.FORNLOOP and JumpTarget(last) == pc + 1) do
					last += Len[last]
				end
				if last > size then
					-- a body that always breaks leaves its FORNLOOP unreachable, jumping forward; it sits before the exit
					last = pc + D[pc]
					assert(OpOf[last] == Op.FORNLOOP, "malformed numeric for loop")
				end
				LoopAt[pc] = NewLoop("numeric", pc, pc + 1, last, last)
				NextPc[pc] = Resolve(last + 1)
				TargetPc[pc] = Resolve(pc + 1)
				local empty = Resolve(JumpTarget(pc))
				if empty ~= NextPc[pc] then
					EmptyPc[pc] = empty
				end
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
			AddPred(pc, EmptyPc[pc])
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
			local value = imports[pc]
			if value == nil then
				local path = Analysis.ImportPath(K, Aux[pc])
				if resolve then
					value = resolve(path)
				elseif safeEnv then
					value = ResolveImport(env, path)
				end
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

		-- error/assert loaded only to be called: the load produces a wrapper that knows the call's position.
		-- The load is found by scanning back in code order, so it is found across the joins O0 code creates.
		local orderIndex: { [number]: number } = {}
		for i, pc in order do
			orderIndex[pc] = i
		end
		local function GlobalName(pc: number): string?
			local op = OpOf[pc]
			if op == Op.GETGLOBAL then
				return K[Aux[pc] + 1]
			elseif op == Op.GETIMPORT and rshift(Aux[pc], 30) == 1 then
				return K[band(rshift(Aux[pc], 20), 0x3FF) + 1]
			end
			return nil
		end
		local positioned: { [number]: number } = {}
		for _, pc in live do
			local op = OpOf[pc]
			if op ~= Op.CALL and op ~= Op.CALLFB then
				continue
			end
			local r = A[pc]
			local i = orderIndex[pc] - 1
			local steps = 0
			while i >= 1 and steps < 64 do
				local p = order[i]
				local name = GlobalName(p)
				if name ~= nil and A[p] == r then
					if name == "error" or name == "assert" then
						positioned[p] = pc
					end
					break
				end
				local lo, hi, reads = Effects(p)
				if lo == nil then
					if not (BRANCH[OpOf[p]] or PURE_JUMP[OpOf[p]] or REMOVED[OpOf[p]]) then
						break
					end
				elseif (r >= lo and r <= hi) or reads(r) then
					break
				end
				i -= 1
				steps += 1
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
				if EmptyPc[pc] then
					EmptyPc[pc] = Resolve(EmptyPc[pc])
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
				for _, dst in { NextPc[pc], TargetPc[pc], EmptyPc[pc] } do
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
		local branchDead: { [number]: boolean } = {}
		do
			local predCount: { [number]: number } = {}
			predCount[entry] = 1
			for _, pc in live do
				for _, dst in { NextPc[pc], TargetPc[pc], EmptyPc[pc] } do
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

			-- field loads of getfenv/setfenv stay unfused: DynamicEnv swaps them for VM-aware versions
			local function Swapped(pc: number): boolean
				if OpOf[pc] ~= Op.GETTABLEKS then
					return false
				end
				local key = K[Aux[pc] + 1]
				return key == "getfenv" or key == "setfenv"
			end

			local function Fusable(p1: number, p2: number): boolean
				local o1, o2 = OpOf[p1], OpOf[p2]
				local a1 = A[p1]
				if Swapped(p1) or Swapped(p2) then
					return false
				end
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
				return tests and not Swapped(p1) and (IsGetK(o1) or o1 == Op.GETTABLE or o1 == Op.MODK)
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
					-- a tested value nobody reads again is never stored: faster, and a stale register cannot keep a
					-- weakly referenced value alive across the next allocation
					if DeadAfter(p2, A[p1]) then
						branchDead[p1] = true
					end
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
			if EmptyPc[pc] then
				NoteBack(pc, EmptyPc[pc])
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
		local EdgeE: { [number]: Edge } = {}

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
			local chain = not noChain
				and dst > src
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
				elseif noChain then
					-- the loop handler settles its own body
					table.insert(loop.MemberPcs, first)
					Depth[first] = math.max(Depth[first] or 0, 1)
					BodyEdge[pc] = { Pc = first, Chain = false }
				else
					Depth[first] = math.max(Depth[first] or 0, 1)
					BodyEdge[pc] = { Pc = first, Chain = true }
				end
				EdgeN[pc] = Plan(pc, NextPc[pc])
				if EmptyPc[pc] then
					EdgeE[pc] = Plan(pc, EmptyPc[pc])
				end
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
			EdgeE = EdgeE,
			LoopAt = LoopAt,
			Wrappers = wrappers,
			Loops = loops,
			Tail = Tail,
			Kept = kept,
			Calls = calls,
			Pairs = pairs,
			BranchDead = branchDead,
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
end)()

-- Classes.luau
local Module_Classes = (function()
	-- Luau classes (bytecode versions 10 and 100): class objects, instances and the `class` library, after VM/src/lclass.cpp.
	-- Why: class bytecode needs a runtime object model; pure Luau cannot create new value types, so classes and
	-- instances are tables whose shared metatables reproduce the host's member rules and error messages, and the
	-- builtins that reveal a type (type, typeof, getmetatable) are swapped for class-aware versions in class chunks.
	--
	-- A class record mirrors LuauClass: member offsets are 0-based, instance members come first (public fields, then
	-- private fields), then static members (public methods, then private methods). An instance stores its members by
	-- offset + 1 in an array held under a private key, so every named access goes through the class's metamethods.


	-- Private keys: an instance's member array and a class value's record
	local STORE, CLASS = newproxy(false), newproxy(false)

	local hostType, hostTypeof, hostGetmetatable = type, typeof, getmetatable
	local create = table.create
	local format = string.format

	local lastId = 0
	local addresses = 0

	local Classes = {}

	-- Fake address for default tostring; real addresses are not observable from Luau.
	local function Address(kind: string): string
		addresses += 1
		return format("%s: 0x%016x", kind, addresses)
	end

	-- Guest-visible type name, as luaT_objtypename reports it.
	local function TypeName(value: any): string
		if hostType(value) == "table" then
			if rawget(value, STORE) ~= nil then
				return "object"
			elseif rawget(value, CLASS) ~= nil then
				return "class"
			end
		end
		return hostTypeof(value)
	end

	-- Raises a host runtime error (luaG_runerror). The position names this module, which the Debug option replaces
	-- with the guest instruction's, as it does for every error raised inside the interpreter.
	local function Raise(message: string): never
		error(message, 1)
	end

	local function MissingMember(object: any, key: any): never
		if hostType(key) ~= "string" then
			Raise(`cannot index {TypeName(object)} with a {TypeName(key)}`)
		end
		Raise(`this {TypeName(object)} does not have a key named '{key}'`)
	end

	local function IndexError(object: any, key: any): never
		if hostType(key) == "string" and #key <= 64 then
			Raise(`attempt to index {TypeName(object)} with '{key}'`)
		end
		Raise(`attempt to index {TypeName(object)} with {TypeName(key)}`)
	end

	-- Metamethods every instance and class value has unless the class defines its own: they raise the host's
	-- errors for a value without metamethods, named "object"/"class" instead of "table".
	local ARITH = { "add", "sub", "mul", "div", "mod", "pow", "idiv" }

	local function Defaults(meta: { [any]: any })
		for _, op in ARITH do
			meta["__" .. op] = function(a, b)
				local ta, tb = TypeName(a), TypeName(b)
				if ta == tb then
					Raise(`attempt to perform arithmetic ({op}) on {ta}`)
				end
				Raise(`attempt to perform arithmetic ({op}) on {ta} and {tb}`)
			end
		end
		meta.__unm = function(a)
			Raise(`attempt to perform arithmetic (unm) on {TypeName(a)}`)
		end
		meta.__lt = function(a, b)
			Raise(`attempt to compare {TypeName(a)} < {TypeName(b)}`)
		end
		meta.__le = function(a, b)
			Raise(`attempt to compare {TypeName(a)} <= {TypeName(b)}`)
		end
		meta.__concat = function(a, b)
			Raise(`attempt to concatenate {TypeName(a)} with {TypeName(b)}`)
		end
		meta.__len = function(a)
			Raise(`attempt to get length of a {TypeName(a)} value`)
		end
		meta.__call = function(a)
			Raise(`attempt to call a {TypeName(a)} value`)
		end
		meta.__iter = function(a)
			Raise(`attempt to iterate over a {TypeName(a)} value`)
		end
		meta.__metatable = false
	end

	-- Class value metatable, shared by every class: static members, construction and the host's errors.
	local ClassMeta: { [any]: any } = {}
	Defaults(ClassMeta)

	ClassMeta.__index = function(proxy, key)
		local cls: Class = rawget(proxy, CLASS)
		local offset = cls.Members[key]
		if offset == nil or offset < cls.NInstance then
			MissingMember(proxy, key)
		end
		return cls.Statics[offset - cls.NInstance + 1]
	end

	ClassMeta.__newindex = function(proxy, key)
		IndexError(proxy, key)
	end

	ClassMeta.__tostring = function(proxy)
		local cls: Class = rawget(proxy, CLASS)
		local text = (cls :: any).Text
		if not text then
			text = Address("class")
			;(cls :: any).Text = text
		end
		return text
	end

	-- luaR_constructobject: the class value's __call. Creates a blank instance and runs __init on it.
	ClassMeta.__call = function(proxy, ...)
		local cls: Class = rawget(proxy, CLASS)
		local self = Classes.Blank(cls)
		local init = cls.Statics[cls.Members.__init - cls.NInstance + 1]
		init(self, ...)
		return self
	end

	-- Instance metatable of a class: member access by offset; user metamethods are added as they are registered.
	local function ObjectMeta(cls: Class): { [any]: any }
		local meta: { [any]: any } = {}
		Defaults(meta)
		local members = cls.Members
		local count = cls.NInstance
		meta.__index = function(object, key)
			local offset = members[key]
			if offset == nil then
				MissingMember(object, key)
			elseif offset < count then
				return rawget(object, STORE)[offset + 1]
			end
			return cls.Statics[offset - count + 1]
		end
		meta.__newindex = function(object, key, value)
			local offset = members[key]
			if offset == nil then
				MissingMember(object, key)
			elseif offset >= count then
				IndexError(object, key)
			end
			rawget(object, STORE)[offset + 1] = value
		end
		meta.__tostring = function(object)
			local store = rawget(object, STORE)
			local text = store.Text
			if not text then
				text = Address("object")
				store.Text = text
			end
			return text
		end
		return meta
	end

	-- Makes the guest-visible value for a class record.
	local function Publish(cls: Class): { [any]: any }
		local proxy = setmetatable({ [CLASS] = cls }, ClassMeta)
		cls.Proxy = proxy
		return proxy
	end

	local function NewBlankClass(name: string, isOpen: boolean): Class
		lastId += 1
		return {
			Name = name,
			Id = lastId,
			IsOpen = isOpen,
			Super = nil,
			Members = {},
			Names = {},
			NInstance = 0,
			NMembers = 0,
			NPrivateFields = 0,
			OwnPrivateStart = 0,
			NPrivateStatics = 0,
			Statics = {},
			HasUserInit = false,
			InstanceMeta = nil,
			ObjectMeta = nil :: any,
			Proxy = nil :: any,
		}
	end

	-- luaR_defaultcreateobject: the __init every class starts with; copies fields from a property table.
	local function DefaultInit(cls: Class): (...any) -> ()
		return function(...)
			if cls.HasUserInit then
				error(`Class {cls.Name} must define a constructor because it is derived from a class that defines one`, 0)
			elseif cls.NPrivateFields ~= 0 then
				if cls.Super then
					error(`Class {cls.Name} must define a constructor because it or a class it inherits from has private fields`, 0)
				end
				error(`Class {cls.Name} must define a constructor because it has private fields`, 0)
			end
			local count = select("#", ...)
			if count ~= 2 then
				error(`The constructor of {cls.Name} must be called with 2 arguments.  Got {count}`, 0)
			end
			local self, props = ...
			local store = if hostType(self) == "table" then rawget(self, STORE) else nil
			if store == nil then
				error(`{cls.Name}.__init must be called with an instance of the class as its first argument`, 0)
			end
			local owner: Class = store[0]
			if owner ~= cls then
				error(`Cannot call {cls.Name}.__init on an instance of class {owner.Name}`, 0)
			end
			local names = cls.Names
			for offset = 0, cls.NInstance - 1 do
				local name = names[offset]
				if name ~= nil then
					store[offset + 1] = props[name]
				end
			end
		end
	end

	-- luaR_setupconstructor: installs the default __init in the class's __init slot.
	local function SetupConstructor(cls: Class)
		cls.ObjectMeta = cls.ObjectMeta or ObjectMeta(cls)
		local offset = cls.Members.__init
		assert(offset ~= nil and offset >= cls.NInstance, "class shape has no __init")
		cls.Statics[offset - cls.NInstance + 1] = DefaultInit(cls)
	end

	-- luaR_newclass: a class from its LBC_CONSTANT_CLASS_SHAPE constant, as the loader builds it.
	-- @param publicFields { string } – public instance field names in offset order
	-- @param publicMethods { string } – public method names in offset order (after every instance member)
	-- @param privateFields number – unnamed instance fields after the public ones
	-- @param privateMethods number – unnamed methods after the public ones
	function Classes.FromShape(name: string, publicFields: { string }, publicMethods: { string }, privateFields: number, privateMethods: number): any
		local cls = NewBlankClass(name, false)
		local nInstance = #publicFields + privateFields
		local nStatic = #publicMethods + privateMethods
		for i, field in publicFields do
			cls.Members[field] = i - 1
			cls.Names[i - 1] = field
		end
		for i, method in publicMethods do
			cls.Members[method] = nInstance + i - 1
			cls.Names[nInstance + i - 1] = method
		end
		cls.NInstance = nInstance
		cls.NMembers = nInstance + nStatic
		cls.NPrivateFields = privateFields
		cls.OwnPrivateStart = nInstance - privateFields
		cls.NPrivateStatics = privateMethods
		cls.Statics = create(nStatic)
		SetupConstructor(cls)
		return Publish(cls)
	end

	-- Class record of a class value, or nil.
	function Classes.Of(value: any): Class?
		if hostType(value) == "table" then
			return rawget(value, CLASS)
		end
		return nil
	end

	-- Member array of an instance, or nil.
	function Classes.StoreOf(value: any): { any }?
		if hostType(value) == "table" then
			return rawget(value, STORE)
		end
		return nil
	end

	-- luaR_newblankobject with members set to nil.
	function Classes.Blank(cls: Class): any
		local store = create(cls.NInstance)
		store[0] = cls
		return setmetatable({ [STORE] = store }, cls.ObjectMeta)
	end

	-- Sets the instance metatable entry for a metamethod, keeping the defaults for the rest.
	local function SetMetamethod(cls: Class, name: string, value: any)
		local user = cls.InstanceMeta
		if not user then
			user = {}
			cls.InstanceMeta = user
		end
		user[name] = value
		cls.ObjectMeta[name] = value
	end

	-- Names the host treats as metamethods for classes (the parser's allowlist; __init is a plain static).
	local METAMETHODS = {
		__call = true, __concat = true, __unm = true, __add = true, __sub = true, __mul = true, __div = true,
		__mod = true, __pow = true, __tostring = true, __eq = true, __lt = true, __le = true, __iter = true,
		__len = true, __idiv = true,
	}

	-- luaR_addpublicstaticmember (NEWCLASSMEMBER, public).
	function Classes.AddPublic(proxy: any, name: string, value: any)
		local cls = rawget(proxy, CLASS) :: Class
		local offset = cls.Members[name]
		cls.Statics[offset - cls.NInstance + 1] = value
		if name == "__init" then
			cls.HasUserInit = true
		end
		if METAMETHODS[name] then
			local user = cls.InstanceMeta
			if user and (name == "__eq" or name == "__lt" or name == "__le") and user[name] ~= nil then
				Raise(`Overriding comparison metamethods is not allowed ('{name}' in class '{cls.Name}')`)
			end
			SetMetamethod(cls, name, value)
		end
	end

	-- luaR_addprivatestaticmember (NEWCLASSMEMBER, private).
	function Classes.AddPrivate(proxy: any, index: number, value: any)
		local cls = rawget(proxy, CLASS) :: Class
		cls.Statics[cls.NMembers - cls.NInstance - cls.NPrivateStatics + index + 1] = value
	end

	-- luaR_inheritclass: a flattened class combining parent and child, as NEWCLASS with a superclass makes.
	function Classes.Inherit(childProxy: any, parentProxy: any): any
		local child = rawget(childProxy, CLASS) :: Class
		local parent = rawget(parentProxy, CLASS) :: Class
		if not parent.IsOpen then
			Raise(`Non-open class '{parent.Name}' cannot be extended`)
		end
		for offset = 0, parent.NInstance - 1 do
			local name = parent.Names[offset]
			if name ~= nil and child.Members[name] ~= nil then
				Raise(`Cannot override instance member '{name}' of parent class '{parent.Name}' in child class '{child.Name}'`)
			end
		end

		local cls = NewBlankClass(child.Name, child.IsOpen)
		cls.Super = parent
		cls.HasUserInit = parent.HasUserInit

		local offset = 0
		for i = 0, parent.NInstance - 1 do
			local name = parent.Names[i]
			cls.Names[offset] = name
			if name ~= nil then
				cls.Members[name] = offset
			end
			offset += 1
		end
		for i = 0, child.NInstance - 1 do
			local name = child.Names[i]
			cls.Names[offset] = name
			if name ~= nil then
				cls.Members[name] = offset
			end
			offset += 1
		end
		cls.NPrivateFields = child.NPrivateFields + parent.NPrivateFields
		cls.OwnPrivateStart = child.OwnPrivateStart + parent.NInstance
		cls.NInstance = offset

		-- parent's public statics the child does not redeclare, then the child's public statics, then its private ones
		local statics = {}
		local parentPublicEnd = parent.NMembers - parent.NPrivateStatics
		for i = parent.NInstance, parentPublicEnd - 1 do
			local name = parent.Names[i]
			if child.Members[name] == nil then
				table.insert(statics, name)
				cls.Statics[#statics] = parent.Statics[i - parent.NInstance + 1]
			end
		end
		local childPublicEnd = child.NMembers - child.NPrivateStatics
		for i = child.NInstance, childPublicEnd - 1 do
			local name = child.Names[i]
			table.insert(statics, name)
			cls.Statics[#statics] = child.Statics[i - child.NInstance + 1]
		end
		for i, name in statics do
			cls.Names[offset + i - 1] = name
			cls.Members[name] = offset + i - 1
		end
		local publicStatics = #statics
		local childPrivateBase = child.NMembers - child.NInstance - child.NPrivateStatics
		for i = 1, child.NPrivateStatics do
			cls.Statics[publicStatics + i] = child.Statics[childPrivateBase + i]
		end
		cls.NPrivateStatics = child.NPrivateStatics
		cls.NMembers = offset + publicStatics + child.NPrivateStatics

		cls.ObjectMeta = ObjectMeta(cls)
		if parent.InstanceMeta then
			for name, value in parent.InstanceMeta do
				SetMetamethod(cls, name, value)
			end
		end
		SetupConstructor(cls)
		return Publish(cls)
	end

	-- Whether an instance's class is cls or derives from it (luaR_isinstance).
	function Classes.IsInstance(store: { any }, cls: Class): boolean
		local c: Class? = store[0]
		while c do
			if c == cls then
				return true
			end
			c = c.Super
		end
		return false
	end

	-- Whether child is ancestor or derives from it (luaR_issubclass).
	function Classes.IsSubclass(child: Class, ancestor: Class): boolean
		local c: Class? = child
		while c do
			if c == ancestor then
				return true
			end
			c = c.Super
		end
		return false
	end

	-- Private static member of a class by index.
	function Classes.PrivateStatic(cls: Class, index: number): any
		return cls.Statics[cls.NMembers - cls.NInstance - cls.NPrivateStatics + index + 1]
	end

	Classes.TypeName = TypeName

	-- The `class` library (lclasslib.cpp).
	local function MissingArgument(n: number, fname: string): never
		error(`missing argument #{n} to '{fname}'`, 0)
	end

	Classes.Library = table.freeze({
		isinstance = function(...)
			local count = select("#", ...)
			local object, cls = ...
			if count < 1 then
				MissingArgument(1, "isinstance")
			end
			local record = Classes.Of(cls)
			if record == nil then
				if count < 2 then
					MissingArgument(2, "isinstance")
				end
				error(`invalid argument #2 to 'isinstance' (class expected, got {TypeName(cls)})`, 0)
			end
			local store = Classes.StoreOf(object)
			return store ~= nil and Classes.IsInstance(store, record :: Class)
		end,
		classof = function(...)
			if select("#", ...) < 1 then
				MissingArgument(1, "classof")
			end
			local store = Classes.StoreOf((...))
			if store == nil then
				return nil
			end
			return (store[0] :: Class).Proxy
		end,
	})

	-- Class-aware builtins, swapped in for the host's when class bytecode reads them.
	Classes.Builtins = {
		type = function(...)
			local value = ...
			if select("#", ...) > 0 and hostType(value) == "table" then
				local name = TypeName(value)
				if name ~= "table" then
					return name
				end
			end
			return hostType(...)
		end,
		typeof = function(...)
			local value = ...
			if select("#", ...) > 0 and hostType(value) == "table" then
				return TypeName(value)
			end
			return hostTypeof(...)
		end,
		getmetatable = function(...)
			local value = ...
			if hostType(value) == "table" and (rawget(value, STORE) ~= nil or rawget(value, CLASS) ~= nil) then
				return nil
			end
			return hostGetmetatable(...)
		end,
	}

	-- Host builtin -> class-aware replacement.
	Classes.Swaps = {
		[hostType] = Classes.Builtins.type,
		[hostTypeof] = Classes.Builtins.typeof,
		[hostGetmetatable] = Classes.Builtins.getmetatable,
	} :: { [any]: any }

	return Classes
end)()

-- Env.luau
local Module_Env = (function()
	-- Dynamic environments: getfenv/setfenv with the host's semantics, enabled by the DynamicEnv load option.
	-- Why: by default globals bind to one environment at load time, which is fastest; code that swaps environments
	-- needs every closure to carry its own environment and imports to re-resolve once an environment is exposed.
	--
	-- Each VM closure's upvalue table holds its environment under ENV and the closure itself under FN. Numeric levels
	-- walk the host call stack: VM closures are real host functions there, interpreter internals are skipped, and
	-- other functions (pcall, host callbacks) count as levels, as they do on the host.


	local hostGetfenv = getfenv
	local hostSetfenv = setfenv
	local info = debug.info

	-- Upvalue-table keys of a closure's environment and of the closure itself
	local ENV, FN = "\0env", "\0fn"

	-- Sources of interpreter modules; their frames are invisible to guest levels
	local internal: { [string]: boolean } = {}
	-- Interpreter functions run through a host pcall; that pcall's frame is invisible too
	local guarded: { [any]: boolean } = {}

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
			if skip then
				skip = false
			elseif guarded[fn] then
				skip = true
			elseif owners[fn] ~= nil or not internal[info(i, "s")] then
				seen += 1
				if seen == level then
					return fn
				end
			end
			i += 1
		end
	end

	-- Creates a dynamic environment state. Level 0 is the running thread's globals, as on the host.
	function Env.New(): EnvState
		local state: EnvState
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
	function Env.Swap(state: EnvState, value: any): any
		if rawequal(value, hostGetfenv) then
			return state.getfenv
		elseif rawequal(value, hostSetfenv) then
			return state.setfenv
		end
		return value
	end

	Env.MarkInternal(Env.Swap)

	return Env
end)()

-- Ops/Arith.luau
local Module_Arith = (function()
	-- Arithmetic, logical and unary handlers.
	-- Operators are executed natively, so metamethods, coercions and error messages match the host exactly.
	-- @param A number – target frame index
	-- @param B number – left operand frame index
	-- @param C number – right operand frame index (or constant value for K forms)
	-- @param Next Handler – successor, or a loop token in returning mode
	-- @param Chain boolean – whether to call Next directly



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
end)()

-- Ops/Branches.luau
local Module_Branches = (function()
	-- Conditional branch handlers.
	-- Negated opcodes are built by swapping successors, so each condition is written once.
	-- Each successor is either chained (called) or returned to a trampoline, giving four variants per condition.
	-- @param N Handler – fallthrough successor (or loop token)
	-- @param NC boolean – whether N is chained
	-- @param T Handler – branch target (or loop token)
	-- @param TC boolean – whether T is chained

	local Runtime = Module_Runtime


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
end)()

-- Ops/Calls.luau
local Module_Calls = (function()
	-- Call, method-call and return handlers.
	-- Callees are invoked as ordinary host calls, so VM closures, host functions, coroutines and pcall all interoperate natively.
	-- Operands are frame indices chosen by Analysis: a callee or argument load folded into the call is read straight
	-- from its source register or constant slot.
	-- @param A number – frame index results are written from
	-- @param Next Handler – successor, or a loop token in returning mode
	-- @param Chain boolean – whether to call Next directly

	local Runtime = Module_Runtime


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

	-- Method lookup on a non-table: userdata with a __namecall metamethod dispatches every method call through it.
	-- Why: the host's NAMECALL checks __namecall before indexing userdata.
	local function Lookup(object: any, key: string): any
		if type(object) == "userdata" then
			local mt = getmetatable(object)
			if type(mt) == "table" then
				local handler = rawget(mt, "__namecall")
				if handler ~= nil then
					return handler
				end
			end
		end
		return object[key]
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
			-- the callee stays in A, as the host's CALL leaves it: a folded callee load must not leave a stale
			-- register holding the only reference to a collectable value (weak-table tests observe this)
			if n == 0 then
				if Chain then
					return function(S)
						local f = S[F]
						S[A] = f
						f()
						return Next(S)
					end
				end
				return function(S)
					local f = S[F]
					S[A] = f
					f()
					return Next
				end
			elseif n == 1 then
				if Chain then
					return function(S)
						local f = S[F]
						S[A] = f
						f(S[X])
						return Next(S)
					end
				end
				return function(S)
					local f = S[F]
					S[A] = f
					f(S[X])
					return Next
				end
			elseif n == 2 then
				if Chain then
					return function(S)
						local f = S[F]
						S[A] = f
						f(S[X], S[Y])
						return Next(S)
					end
				end
				return function(S)
					local f = S[F]
					S[A] = f
					f(S[X], S[Y])
					return Next
				end
			elseif n == 3 then
				return function(S)
					local f = S[F]
					S[A] = f
					f(S[X], S[Y], S[Z])
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
					local f = S[1][U]
					S[A] = f
					f()
					return if Chain then Next(S) else Next
				end
			elseif n == 1 then
				return function(S)
					local f = S[1][U]
					S[A] = f
					f(S[X])
					return if Chain then Next(S) else Next
				end
			elseif n == 2 then
				return function(S)
					local f = S[1][U]
					S[A] = f
					f(S[X], S[Y])
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
				S[A] = fn
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
			local fn = if type(self) == "table" then self[K] else Lookup(self, K)
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
						local fn = if type(o) == "table" then o[K] else Lookup(o, K)
						if fn == nil then
							MissingMethod(o, K, Where)
						end
						S[A] = fn(o)
						return Next(S)
					end
				end
				return function(S)
					local o = S[O]
					local fn = if type(o) == "table" then o[K] else Lookup(o, K)
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
						local fn = if type(o) == "table" then o[K] else Lookup(o, K)
						if fn == nil then
							MissingMethod(o, K, Where)
						end
						S[A] = fn(o, S[X])
						return Next(S)
					end
				end
				return function(S)
					local o = S[O]
					local fn = if type(o) == "table" then o[K] else Lookup(o, K)
					if fn == nil then
						MissingMethod(o, K, Where)
					end
					S[A] = fn(o, S[X])
					return Next
				end
			elseif n == 2 then
				return function(S)
					local o = S[O]
					local fn = if type(o) == "table" then o[K] else Lookup(o, K)
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
					local fn = if type(o) == "table" then o[K] else Lookup(o, K)
					if fn == nil then
						MissingMethod(o, K, Where)
					end
					S[A] = fn
					fn(o)
					return if Chain then Next(S) else Next
				end
			elseif n == 1 then
				if Chain then
					return function(S)
						local o = S[O]
						local fn = if type(o) == "table" then o[K] else Lookup(o, K)
						if fn == nil then
							MissingMethod(o, K, Where)
						end
						S[A] = fn
						fn(o, S[X])
						return Next(S)
					end
				end
				return function(S)
					local o = S[O]
					local fn = if type(o) == "table" then o[K] else Lookup(o, K)
					if fn == nil then
						MissingMethod(o, K, Where)
					end
					S[A] = fn
					fn(o, S[X])
					return Next
				end
			elseif n == 2 then
				return function(S)
					local o = S[O]
					local fn = if type(o) == "table" then o[K] else Lookup(o, K)
					if fn == nil then
						MissingMethod(o, K, Where)
					end
					S[A] = fn
					fn(o, S[X], S[Y])
					return if Chain then Next(S) else Next
				end
			end
		end

		if n <= 1 then
			return function(S)
				local o = S[O]
				local fn = if type(o) == "table" then o[K] else Lookup(o, K)
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
			local fn = if type(o) == "table" then o[K] else Lookup(o, K)
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
end)()

-- Ops/Closures.luau
local Module_Closures = (function()
	-- Closure creation handlers (NEWCLOSURE, DUPCLOSURE).
	-- A VM closure is a plain host function whose upvalues live in a table: by-value captures are stored directly,
	-- by-reference captures as shared cells (see Runtime.Capture).
	-- @param A number – target frame index
	-- @param Make Factory – builds the host function for the child proto
	-- @param Kinds { number } – capture kind per upvalue (see constants below)
	-- @param Sources { number } – frame index or parent upvalue index per upvalue
	-- @param Next Handler – successor, or a loop token in returning mode
	-- @param Chain boolean – whether to call Next directly

	local Runtime = Module_Runtime
	local Env = Module_Env


	local create = table.create
	local rawequal = rawequal
	local Capture = Runtime.Capture
	local ENV, FN = Env.ENV, Env.FN

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

	-- DynamicEnv closure creation: the closure inherits its creator's environment and is registered for getfenv.
	-- @param Reuse boolean – DUPCLOSURE: reuse the last closure while environment and captured values are unchanged
	local function Dynamic(A: number, Make: Factory, Kinds: { number }, Sources: { number }, Next: Handler, Chain: boolean, Dyn: EnvState, Reuse: boolean): Handler
		local n = #Kinds
		local owners = Dyn.Owners
		local cached: any = nil
		local cachedU: { any } = NO_UPVALUES
		local reusable = Reuse
		for i = 1, n do
			if Kinds[i] ~= VALUE and Kinds[i] ~= UPVALUE then
				reusable = false
			end
		end
		return function(S)
			local env = S[1][ENV]
			if reusable and cached ~= nil and cachedU[ENV] == env then
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
			U[ENV] = env
			U[FN] = fn
			owners[fn] = U
			S[A] = fn
			for i = 1, n do
				U[i] = Captured(S, Kinds[i], Sources[i])
			end
			cached, cachedU = fn, U
			return if Chain then Next(S) else Next
		end
	end

	-- NEWCLOSURE: always creates a fresh closure.
	-- Single captures (the common case) are written out per kind; the closure is stored before its captures are read
	-- so a function capturing itself by value sees the closure.
	function Closures.New(A: number, Make: Factory, Kinds: { number }, Sources: { number }, Next: Handler, Chain: boolean, Dyn: EnvState?): Handler
		local n = #Kinds
		if Dyn then
			return Dynamic(A, Make, Kinds, Sources, Next, Chain, Dyn, false)
		end
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
	function Closures.Dup(A: number, Make: Factory, Kinds: { number }, Sources: { number }, Next: Handler, Chain: boolean, Dyn: EnvState?): Handler
		local n = #Kinds
		if Dyn then
			return Dynamic(A, Make, Kinds, Sources, Next, Chain, Dyn, true)
		end
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
end)()

-- Ops/Fused.luau
local Module_Fused = (function()
	-- GENERATED by tools/gen_fused.py; edit the generator, not this file.
	--
	-- Handlers for hot adjacent instruction pairs (field loads feeding arithmetic, arithmetic feeding stores and
	-- other arithmetic). One fused handler replaces two handler calls; the first instruction's result is still
	-- written, so the pair behaves exactly like its two instructions in order.
	-- @param Next Handler – successor, or a loop token in returning mode
	-- @param Chain boolean – whether to call Next directly



	local Fused = {}

	-- GETTABLEKS/GETTABLEN pairs
	Fused.GetGet = nil :: any
	Fused.GetSet = nil :: any
	Fused.SetGet = nil :: any
	-- GETUPVAL (by value) feeding a table read
	Fused.UpGetK = nil :: any
	Fused.UpGet = nil :: any
	-- [op][side]: field load feeding the left ("L") or right ("R") operand of a register-register operator
	Fused.GetArith = {} :: { [string]: { [string]: any } }
	-- [op][side]: register-key table load feeding a register-register operator
	Fused.GetRArith = {} :: { [string]: { [string]: any } }
	-- [op]: operator result stored with a register key
	Fused.ArithSetR = {} :: { [string]: any }
	Fused.ArithKSetR = {} :: { [string]: any }
	-- [op]: field load feeding a register-constant operator
	Fused.GetArithK = {} :: { [string]: any }
	-- [op]: operator result stored into a field
	Fused.ArithSet = {} :: { [string]: any }
	Fused.ArithKSet = {} :: { [string]: any }
	-- [op1 .. "_" .. op2][side]: operator result feeding another operator
	Fused.ArithArith = {} :: { [string]: { [string]: any } }
	-- [op1 .. "_" .. op2]: operator result feeding a register-constant operator
	Fused.ArithArithK = {} :: { [string]: any }
	-- [first .. kind]: a value computed for a conditional branch (successors as in Ops/Branches)
	Fused.Branch = {} :: { [string]: any }

	-- Two field loads.
	Fused.GetGet = function(A1: number, B1: number, K1: any, A2: number, B2: number, K2: any, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				S[A1] = S[B1][K1]
				S[A2] = S[B2][K2]
				return Next(S)
			end
		end
		return function(S)
			S[A1] = S[B1][K1]
			S[A2] = S[B2][K2]
			return Next
		end
	end

	-- Field copy: a load whose result is stored.
	Fused.GetSet = function(A1: number, B1: number, K1: any, B2: number, K2: any, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1][K1]
				S[A1] = v
				S[B2][K2] = v
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1][K1]
			S[A1] = v
			S[B2][K2] = v
			return Next
		end
	end

	-- Field store followed by a field load.
	Fused.SetGet = function(A1: number, B1: number, K1: any, A2: number, B2: number, K2: any, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				S[B1][K1] = S[A1]
				S[A2] = S[B2][K2]
				return Next(S)
			end
		end
		return function(S)
			S[B1][K1] = S[A1]
			S[A2] = S[B2][K2]
			return Next
		end
	end

	-- By-value upvalue indexed with a constant key.
	Fused.UpGetK = function(A1: number, U: number, A2: number, K2: any, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local t = S[1][U]
				S[A1] = t
				S[A2] = t[K2]
				return Next(S)
			end
		end
		return function(S)
			local t = S[1][U]
			S[A1] = t
			S[A2] = t[K2]
			return Next
		end
	end

	-- By-value upvalue indexed with a register key.
	Fused.UpGet = function(A1: number, U: number, A2: number, C2: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local t = S[1][U]
				S[A1] = t
				S[A2] = t[S[C2]]
				return Next(S)
			end
		end
		return function(S)
			local t = S[1][U]
			S[A1] = t
			S[A2] = t[S[C2]]
			return Next
		end
	end

	Fused.GetArith.ADD = {}
	Fused.GetRArith.ADD = {}
	-- Field load as the left operand of ADD.
	Fused.GetArith.ADD.L = function(A1: number, B1: number, K1: any, A2: number, O: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1][K1]
				S[A1] = v
				S[A2] = v + S[O]
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1][K1]
			S[A1] = v
			S[A2] = v + S[O]
			return Next
		end
	end

	-- Field load as the right operand of ADD.
	Fused.GetArith.ADD.R = function(A1: number, B1: number, K1: any, A2: number, O: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1][K1]
				S[A1] = v
				S[A2] = S[O] + v
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1][K1]
			S[A1] = v
			S[A2] = S[O] + v
			return Next
		end
	end

	-- Field load feeding ADDK.
	Fused.GetArithK.ADD = function(A1: number, B1: number, K1: any, A2: number, K2: any, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1][K1]
				S[A1] = v
				S[A2] = v + K2
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1][K1]
			S[A1] = v
			S[A2] = v + K2
			return Next
		end
	end

	-- Register-key load as the left operand of ADD.
	Fused.GetRArith.ADD.L = function(A1: number, B1: number, C1: number, A2: number, O: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1][S[C1]]
				S[A1] = v
				S[A2] = v + S[O]
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1][S[C1]]
			S[A1] = v
			S[A2] = v + S[O]
			return Next
		end
	end

	-- Register-key load as the right operand of ADD.
	Fused.GetRArith.ADD.R = function(A1: number, B1: number, C1: number, A2: number, O: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1][S[C1]]
				S[A1] = v
				S[A2] = S[O] + v
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1][S[C1]]
			S[A1] = v
			S[A2] = S[O] + v
			return Next
		end
	end

	-- ADD stored with a register key.
	Fused.ArithSetR.ADD = function(A1: number, B1: number, C1: number, B2: number, C2: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] + S[C1]
				S[A1] = v
				S[B2][S[C2]] = v
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] + S[C1]
			S[A1] = v
			S[B2][S[C2]] = v
			return Next
		end
	end

	-- ADDK stored with a register key.
	Fused.ArithKSetR.ADD = function(A1: number, B1: number, K1: any, B2: number, C2: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] + K1
				S[A1] = v
				S[B2][S[C2]] = v
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] + K1
			S[A1] = v
			S[B2][S[C2]] = v
			return Next
		end
	end

	-- ADD stored into a field.
	Fused.ArithSet.ADD = function(A1: number, B1: number, C1: number, B2: number, K2: any, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] + S[C1]
				S[A1] = v
				S[B2][K2] = v
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] + S[C1]
			S[A1] = v
			S[B2][K2] = v
			return Next
		end
	end

	-- ADDK stored into a field.
	Fused.ArithKSet.ADD = function(A1: number, B1: number, K1: any, B2: number, K2: any, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] + K1
				S[A1] = v
				S[B2][K2] = v
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] + K1
			S[A1] = v
			S[B2][K2] = v
			return Next
		end
	end

	Fused.GetArith.SUB = {}
	Fused.GetRArith.SUB = {}
	-- Field load as the left operand of SUB.
	Fused.GetArith.SUB.L = function(A1: number, B1: number, K1: any, A2: number, O: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1][K1]
				S[A1] = v
				S[A2] = v - S[O]
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1][K1]
			S[A1] = v
			S[A2] = v - S[O]
			return Next
		end
	end

	-- Field load as the right operand of SUB.
	Fused.GetArith.SUB.R = function(A1: number, B1: number, K1: any, A2: number, O: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1][K1]
				S[A1] = v
				S[A2] = S[O] - v
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1][K1]
			S[A1] = v
			S[A2] = S[O] - v
			return Next
		end
	end

	-- Field load feeding SUBK.
	Fused.GetArithK.SUB = function(A1: number, B1: number, K1: any, A2: number, K2: any, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1][K1]
				S[A1] = v
				S[A2] = v - K2
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1][K1]
			S[A1] = v
			S[A2] = v - K2
			return Next
		end
	end

	-- Register-key load as the left operand of SUB.
	Fused.GetRArith.SUB.L = function(A1: number, B1: number, C1: number, A2: number, O: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1][S[C1]]
				S[A1] = v
				S[A2] = v - S[O]
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1][S[C1]]
			S[A1] = v
			S[A2] = v - S[O]
			return Next
		end
	end

	-- Register-key load as the right operand of SUB.
	Fused.GetRArith.SUB.R = function(A1: number, B1: number, C1: number, A2: number, O: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1][S[C1]]
				S[A1] = v
				S[A2] = S[O] - v
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1][S[C1]]
			S[A1] = v
			S[A2] = S[O] - v
			return Next
		end
	end

	-- SUB stored with a register key.
	Fused.ArithSetR.SUB = function(A1: number, B1: number, C1: number, B2: number, C2: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] - S[C1]
				S[A1] = v
				S[B2][S[C2]] = v
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] - S[C1]
			S[A1] = v
			S[B2][S[C2]] = v
			return Next
		end
	end

	-- SUBK stored with a register key.
	Fused.ArithKSetR.SUB = function(A1: number, B1: number, K1: any, B2: number, C2: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] - K1
				S[A1] = v
				S[B2][S[C2]] = v
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] - K1
			S[A1] = v
			S[B2][S[C2]] = v
			return Next
		end
	end

	-- SUB stored into a field.
	Fused.ArithSet.SUB = function(A1: number, B1: number, C1: number, B2: number, K2: any, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] - S[C1]
				S[A1] = v
				S[B2][K2] = v
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] - S[C1]
			S[A1] = v
			S[B2][K2] = v
			return Next
		end
	end

	-- SUBK stored into a field.
	Fused.ArithKSet.SUB = function(A1: number, B1: number, K1: any, B2: number, K2: any, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] - K1
				S[A1] = v
				S[B2][K2] = v
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] - K1
			S[A1] = v
			S[B2][K2] = v
			return Next
		end
	end

	Fused.GetArith.MUL = {}
	Fused.GetRArith.MUL = {}
	-- Field load as the left operand of MUL.
	Fused.GetArith.MUL.L = function(A1: number, B1: number, K1: any, A2: number, O: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1][K1]
				S[A1] = v
				S[A2] = v * S[O]
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1][K1]
			S[A1] = v
			S[A2] = v * S[O]
			return Next
		end
	end

	-- Field load as the right operand of MUL.
	Fused.GetArith.MUL.R = function(A1: number, B1: number, K1: any, A2: number, O: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1][K1]
				S[A1] = v
				S[A2] = S[O] * v
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1][K1]
			S[A1] = v
			S[A2] = S[O] * v
			return Next
		end
	end

	-- Field load feeding MULK.
	Fused.GetArithK.MUL = function(A1: number, B1: number, K1: any, A2: number, K2: any, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1][K1]
				S[A1] = v
				S[A2] = v * K2
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1][K1]
			S[A1] = v
			S[A2] = v * K2
			return Next
		end
	end

	-- Register-key load as the left operand of MUL.
	Fused.GetRArith.MUL.L = function(A1: number, B1: number, C1: number, A2: number, O: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1][S[C1]]
				S[A1] = v
				S[A2] = v * S[O]
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1][S[C1]]
			S[A1] = v
			S[A2] = v * S[O]
			return Next
		end
	end

	-- Register-key load as the right operand of MUL.
	Fused.GetRArith.MUL.R = function(A1: number, B1: number, C1: number, A2: number, O: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1][S[C1]]
				S[A1] = v
				S[A2] = S[O] * v
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1][S[C1]]
			S[A1] = v
			S[A2] = S[O] * v
			return Next
		end
	end

	-- MUL stored with a register key.
	Fused.ArithSetR.MUL = function(A1: number, B1: number, C1: number, B2: number, C2: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] * S[C1]
				S[A1] = v
				S[B2][S[C2]] = v
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] * S[C1]
			S[A1] = v
			S[B2][S[C2]] = v
			return Next
		end
	end

	-- MULK stored with a register key.
	Fused.ArithKSetR.MUL = function(A1: number, B1: number, K1: any, B2: number, C2: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] * K1
				S[A1] = v
				S[B2][S[C2]] = v
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] * K1
			S[A1] = v
			S[B2][S[C2]] = v
			return Next
		end
	end

	-- MUL stored into a field.
	Fused.ArithSet.MUL = function(A1: number, B1: number, C1: number, B2: number, K2: any, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] * S[C1]
				S[A1] = v
				S[B2][K2] = v
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] * S[C1]
			S[A1] = v
			S[B2][K2] = v
			return Next
		end
	end

	-- MULK stored into a field.
	Fused.ArithKSet.MUL = function(A1: number, B1: number, K1: any, B2: number, K2: any, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] * K1
				S[A1] = v
				S[B2][K2] = v
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] * K1
			S[A1] = v
			S[B2][K2] = v
			return Next
		end
	end

	Fused.GetArith.DIV = {}
	Fused.GetRArith.DIV = {}
	-- Field load as the left operand of DIV.
	Fused.GetArith.DIV.L = function(A1: number, B1: number, K1: any, A2: number, O: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1][K1]
				S[A1] = v
				S[A2] = v / S[O]
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1][K1]
			S[A1] = v
			S[A2] = v / S[O]
			return Next
		end
	end

	-- Field load as the right operand of DIV.
	Fused.GetArith.DIV.R = function(A1: number, B1: number, K1: any, A2: number, O: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1][K1]
				S[A1] = v
				S[A2] = S[O] / v
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1][K1]
			S[A1] = v
			S[A2] = S[O] / v
			return Next
		end
	end

	-- Field load feeding DIVK.
	Fused.GetArithK.DIV = function(A1: number, B1: number, K1: any, A2: number, K2: any, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1][K1]
				S[A1] = v
				S[A2] = v / K2
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1][K1]
			S[A1] = v
			S[A2] = v / K2
			return Next
		end
	end

	-- Register-key load as the left operand of DIV.
	Fused.GetRArith.DIV.L = function(A1: number, B1: number, C1: number, A2: number, O: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1][S[C1]]
				S[A1] = v
				S[A2] = v / S[O]
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1][S[C1]]
			S[A1] = v
			S[A2] = v / S[O]
			return Next
		end
	end

	-- Register-key load as the right operand of DIV.
	Fused.GetRArith.DIV.R = function(A1: number, B1: number, C1: number, A2: number, O: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1][S[C1]]
				S[A1] = v
				S[A2] = S[O] / v
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1][S[C1]]
			S[A1] = v
			S[A2] = S[O] / v
			return Next
		end
	end

	-- DIV stored with a register key.
	Fused.ArithSetR.DIV = function(A1: number, B1: number, C1: number, B2: number, C2: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] / S[C1]
				S[A1] = v
				S[B2][S[C2]] = v
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] / S[C1]
			S[A1] = v
			S[B2][S[C2]] = v
			return Next
		end
	end

	-- DIVK stored with a register key.
	Fused.ArithKSetR.DIV = function(A1: number, B1: number, K1: any, B2: number, C2: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] / K1
				S[A1] = v
				S[B2][S[C2]] = v
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] / K1
			S[A1] = v
			S[B2][S[C2]] = v
			return Next
		end
	end

	-- DIV stored into a field.
	Fused.ArithSet.DIV = function(A1: number, B1: number, C1: number, B2: number, K2: any, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] / S[C1]
				S[A1] = v
				S[B2][K2] = v
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] / S[C1]
			S[A1] = v
			S[B2][K2] = v
			return Next
		end
	end

	-- DIVK stored into a field.
	Fused.ArithKSet.DIV = function(A1: number, B1: number, K1: any, B2: number, K2: any, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] / K1
				S[A1] = v
				S[B2][K2] = v
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] / K1
			S[A1] = v
			S[B2][K2] = v
			return Next
		end
	end

	Fused.ArithArith.ADD_ADD = {}
	-- ADD as the left operand of ADD.
	Fused.ArithArith.ADD_ADD.L = function(A1: number, B1: number, C1: number, A2: number, O: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] + S[C1]
				S[A1] = v
				S[A2] = v + S[O]
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] + S[C1]
			S[A1] = v
			S[A2] = v + S[O]
			return Next
		end
	end

	-- ADD as the right operand of ADD.
	Fused.ArithArith.ADD_ADD.R = function(A1: number, B1: number, C1: number, A2: number, O: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] + S[C1]
				S[A1] = v
				S[A2] = S[O] + v
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] + S[C1]
			S[A1] = v
			S[A2] = S[O] + v
			return Next
		end
	end

	-- ADD feeding ADDK.
	Fused.ArithArithK.ADD_ADD = function(A1: number, B1: number, C1: number, A2: number, K2: any, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] + S[C1]
				S[A1] = v
				S[A2] = v + K2
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] + S[C1]
			S[A1] = v
			S[A2] = v + K2
			return Next
		end
	end

	Fused.ArithArith.ADD_SUB = {}
	-- ADD as the left operand of SUB.
	Fused.ArithArith.ADD_SUB.L = function(A1: number, B1: number, C1: number, A2: number, O: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] + S[C1]
				S[A1] = v
				S[A2] = v - S[O]
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] + S[C1]
			S[A1] = v
			S[A2] = v - S[O]
			return Next
		end
	end

	-- ADD as the right operand of SUB.
	Fused.ArithArith.ADD_SUB.R = function(A1: number, B1: number, C1: number, A2: number, O: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] + S[C1]
				S[A1] = v
				S[A2] = S[O] - v
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] + S[C1]
			S[A1] = v
			S[A2] = S[O] - v
			return Next
		end
	end

	-- ADD feeding SUBK.
	Fused.ArithArithK.ADD_SUB = function(A1: number, B1: number, C1: number, A2: number, K2: any, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] + S[C1]
				S[A1] = v
				S[A2] = v - K2
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] + S[C1]
			S[A1] = v
			S[A2] = v - K2
			return Next
		end
	end

	Fused.ArithArith.ADD_MUL = {}
	-- ADD as the left operand of MUL.
	Fused.ArithArith.ADD_MUL.L = function(A1: number, B1: number, C1: number, A2: number, O: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] + S[C1]
				S[A1] = v
				S[A2] = v * S[O]
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] + S[C1]
			S[A1] = v
			S[A2] = v * S[O]
			return Next
		end
	end

	-- ADD as the right operand of MUL.
	Fused.ArithArith.ADD_MUL.R = function(A1: number, B1: number, C1: number, A2: number, O: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] + S[C1]
				S[A1] = v
				S[A2] = S[O] * v
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] + S[C1]
			S[A1] = v
			S[A2] = S[O] * v
			return Next
		end
	end

	-- ADD feeding MULK.
	Fused.ArithArithK.ADD_MUL = function(A1: number, B1: number, C1: number, A2: number, K2: any, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] + S[C1]
				S[A1] = v
				S[A2] = v * K2
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] + S[C1]
			S[A1] = v
			S[A2] = v * K2
			return Next
		end
	end

	Fused.ArithArith.ADD_DIV = {}
	-- ADD as the left operand of DIV.
	Fused.ArithArith.ADD_DIV.L = function(A1: number, B1: number, C1: number, A2: number, O: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] + S[C1]
				S[A1] = v
				S[A2] = v / S[O]
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] + S[C1]
			S[A1] = v
			S[A2] = v / S[O]
			return Next
		end
	end

	-- ADD as the right operand of DIV.
	Fused.ArithArith.ADD_DIV.R = function(A1: number, B1: number, C1: number, A2: number, O: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] + S[C1]
				S[A1] = v
				S[A2] = S[O] / v
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] + S[C1]
			S[A1] = v
			S[A2] = S[O] / v
			return Next
		end
	end

	-- ADD feeding DIVK.
	Fused.ArithArithK.ADD_DIV = function(A1: number, B1: number, C1: number, A2: number, K2: any, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] + S[C1]
				S[A1] = v
				S[A2] = v / K2
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] + S[C1]
			S[A1] = v
			S[A2] = v / K2
			return Next
		end
	end

	Fused.ArithArith.SUB_ADD = {}
	-- SUB as the left operand of ADD.
	Fused.ArithArith.SUB_ADD.L = function(A1: number, B1: number, C1: number, A2: number, O: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] - S[C1]
				S[A1] = v
				S[A2] = v + S[O]
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] - S[C1]
			S[A1] = v
			S[A2] = v + S[O]
			return Next
		end
	end

	-- SUB as the right operand of ADD.
	Fused.ArithArith.SUB_ADD.R = function(A1: number, B1: number, C1: number, A2: number, O: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] - S[C1]
				S[A1] = v
				S[A2] = S[O] + v
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] - S[C1]
			S[A1] = v
			S[A2] = S[O] + v
			return Next
		end
	end

	-- SUB feeding ADDK.
	Fused.ArithArithK.SUB_ADD = function(A1: number, B1: number, C1: number, A2: number, K2: any, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] - S[C1]
				S[A1] = v
				S[A2] = v + K2
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] - S[C1]
			S[A1] = v
			S[A2] = v + K2
			return Next
		end
	end

	Fused.ArithArith.SUB_SUB = {}
	-- SUB as the left operand of SUB.
	Fused.ArithArith.SUB_SUB.L = function(A1: number, B1: number, C1: number, A2: number, O: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] - S[C1]
				S[A1] = v
				S[A2] = v - S[O]
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] - S[C1]
			S[A1] = v
			S[A2] = v - S[O]
			return Next
		end
	end

	-- SUB as the right operand of SUB.
	Fused.ArithArith.SUB_SUB.R = function(A1: number, B1: number, C1: number, A2: number, O: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] - S[C1]
				S[A1] = v
				S[A2] = S[O] - v
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] - S[C1]
			S[A1] = v
			S[A2] = S[O] - v
			return Next
		end
	end

	-- SUB feeding SUBK.
	Fused.ArithArithK.SUB_SUB = function(A1: number, B1: number, C1: number, A2: number, K2: any, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] - S[C1]
				S[A1] = v
				S[A2] = v - K2
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] - S[C1]
			S[A1] = v
			S[A2] = v - K2
			return Next
		end
	end

	Fused.ArithArith.SUB_MUL = {}
	-- SUB as the left operand of MUL.
	Fused.ArithArith.SUB_MUL.L = function(A1: number, B1: number, C1: number, A2: number, O: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] - S[C1]
				S[A1] = v
				S[A2] = v * S[O]
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] - S[C1]
			S[A1] = v
			S[A2] = v * S[O]
			return Next
		end
	end

	-- SUB as the right operand of MUL.
	Fused.ArithArith.SUB_MUL.R = function(A1: number, B1: number, C1: number, A2: number, O: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] - S[C1]
				S[A1] = v
				S[A2] = S[O] * v
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] - S[C1]
			S[A1] = v
			S[A2] = S[O] * v
			return Next
		end
	end

	-- SUB feeding MULK.
	Fused.ArithArithK.SUB_MUL = function(A1: number, B1: number, C1: number, A2: number, K2: any, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] - S[C1]
				S[A1] = v
				S[A2] = v * K2
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] - S[C1]
			S[A1] = v
			S[A2] = v * K2
			return Next
		end
	end

	Fused.ArithArith.SUB_DIV = {}
	-- SUB as the left operand of DIV.
	Fused.ArithArith.SUB_DIV.L = function(A1: number, B1: number, C1: number, A2: number, O: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] - S[C1]
				S[A1] = v
				S[A2] = v / S[O]
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] - S[C1]
			S[A1] = v
			S[A2] = v / S[O]
			return Next
		end
	end

	-- SUB as the right operand of DIV.
	Fused.ArithArith.SUB_DIV.R = function(A1: number, B1: number, C1: number, A2: number, O: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] - S[C1]
				S[A1] = v
				S[A2] = S[O] / v
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] - S[C1]
			S[A1] = v
			S[A2] = S[O] / v
			return Next
		end
	end

	-- SUB feeding DIVK.
	Fused.ArithArithK.SUB_DIV = function(A1: number, B1: number, C1: number, A2: number, K2: any, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] - S[C1]
				S[A1] = v
				S[A2] = v / K2
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] - S[C1]
			S[A1] = v
			S[A2] = v / K2
			return Next
		end
	end

	Fused.ArithArith.MUL_ADD = {}
	-- MUL as the left operand of ADD.
	Fused.ArithArith.MUL_ADD.L = function(A1: number, B1: number, C1: number, A2: number, O: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] * S[C1]
				S[A1] = v
				S[A2] = v + S[O]
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] * S[C1]
			S[A1] = v
			S[A2] = v + S[O]
			return Next
		end
	end

	-- MUL as the right operand of ADD.
	Fused.ArithArith.MUL_ADD.R = function(A1: number, B1: number, C1: number, A2: number, O: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] * S[C1]
				S[A1] = v
				S[A2] = S[O] + v
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] * S[C1]
			S[A1] = v
			S[A2] = S[O] + v
			return Next
		end
	end

	-- MUL feeding ADDK.
	Fused.ArithArithK.MUL_ADD = function(A1: number, B1: number, C1: number, A2: number, K2: any, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] * S[C1]
				S[A1] = v
				S[A2] = v + K2
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] * S[C1]
			S[A1] = v
			S[A2] = v + K2
			return Next
		end
	end

	Fused.ArithArith.MUL_SUB = {}
	-- MUL as the left operand of SUB.
	Fused.ArithArith.MUL_SUB.L = function(A1: number, B1: number, C1: number, A2: number, O: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] * S[C1]
				S[A1] = v
				S[A2] = v - S[O]
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] * S[C1]
			S[A1] = v
			S[A2] = v - S[O]
			return Next
		end
	end

	-- MUL as the right operand of SUB.
	Fused.ArithArith.MUL_SUB.R = function(A1: number, B1: number, C1: number, A2: number, O: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] * S[C1]
				S[A1] = v
				S[A2] = S[O] - v
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] * S[C1]
			S[A1] = v
			S[A2] = S[O] - v
			return Next
		end
	end

	-- MUL feeding SUBK.
	Fused.ArithArithK.MUL_SUB = function(A1: number, B1: number, C1: number, A2: number, K2: any, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] * S[C1]
				S[A1] = v
				S[A2] = v - K2
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] * S[C1]
			S[A1] = v
			S[A2] = v - K2
			return Next
		end
	end

	Fused.ArithArith.MUL_MUL = {}
	-- MUL as the left operand of MUL.
	Fused.ArithArith.MUL_MUL.L = function(A1: number, B1: number, C1: number, A2: number, O: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] * S[C1]
				S[A1] = v
				S[A2] = v * S[O]
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] * S[C1]
			S[A1] = v
			S[A2] = v * S[O]
			return Next
		end
	end

	-- MUL as the right operand of MUL.
	Fused.ArithArith.MUL_MUL.R = function(A1: number, B1: number, C1: number, A2: number, O: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] * S[C1]
				S[A1] = v
				S[A2] = S[O] * v
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] * S[C1]
			S[A1] = v
			S[A2] = S[O] * v
			return Next
		end
	end

	-- MUL feeding MULK.
	Fused.ArithArithK.MUL_MUL = function(A1: number, B1: number, C1: number, A2: number, K2: any, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] * S[C1]
				S[A1] = v
				S[A2] = v * K2
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] * S[C1]
			S[A1] = v
			S[A2] = v * K2
			return Next
		end
	end

	Fused.ArithArith.MUL_DIV = {}
	-- MUL as the left operand of DIV.
	Fused.ArithArith.MUL_DIV.L = function(A1: number, B1: number, C1: number, A2: number, O: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] * S[C1]
				S[A1] = v
				S[A2] = v / S[O]
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] * S[C1]
			S[A1] = v
			S[A2] = v / S[O]
			return Next
		end
	end

	-- MUL as the right operand of DIV.
	Fused.ArithArith.MUL_DIV.R = function(A1: number, B1: number, C1: number, A2: number, O: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] * S[C1]
				S[A1] = v
				S[A2] = S[O] / v
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] * S[C1]
			S[A1] = v
			S[A2] = S[O] / v
			return Next
		end
	end

	-- MUL feeding DIVK.
	Fused.ArithArithK.MUL_DIV = function(A1: number, B1: number, C1: number, A2: number, K2: any, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] * S[C1]
				S[A1] = v
				S[A2] = v / K2
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] * S[C1]
			S[A1] = v
			S[A2] = v / K2
			return Next
		end
	end

	Fused.ArithArith.DIV_ADD = {}
	-- DIV as the left operand of ADD.
	Fused.ArithArith.DIV_ADD.L = function(A1: number, B1: number, C1: number, A2: number, O: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] / S[C1]
				S[A1] = v
				S[A2] = v + S[O]
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] / S[C1]
			S[A1] = v
			S[A2] = v + S[O]
			return Next
		end
	end

	-- DIV as the right operand of ADD.
	Fused.ArithArith.DIV_ADD.R = function(A1: number, B1: number, C1: number, A2: number, O: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] / S[C1]
				S[A1] = v
				S[A2] = S[O] + v
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] / S[C1]
			S[A1] = v
			S[A2] = S[O] + v
			return Next
		end
	end

	-- DIV feeding ADDK.
	Fused.ArithArithK.DIV_ADD = function(A1: number, B1: number, C1: number, A2: number, K2: any, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] / S[C1]
				S[A1] = v
				S[A2] = v + K2
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] / S[C1]
			S[A1] = v
			S[A2] = v + K2
			return Next
		end
	end

	Fused.ArithArith.DIV_SUB = {}
	-- DIV as the left operand of SUB.
	Fused.ArithArith.DIV_SUB.L = function(A1: number, B1: number, C1: number, A2: number, O: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] / S[C1]
				S[A1] = v
				S[A2] = v - S[O]
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] / S[C1]
			S[A1] = v
			S[A2] = v - S[O]
			return Next
		end
	end

	-- DIV as the right operand of SUB.
	Fused.ArithArith.DIV_SUB.R = function(A1: number, B1: number, C1: number, A2: number, O: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] / S[C1]
				S[A1] = v
				S[A2] = S[O] - v
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] / S[C1]
			S[A1] = v
			S[A2] = S[O] - v
			return Next
		end
	end

	-- DIV feeding SUBK.
	Fused.ArithArithK.DIV_SUB = function(A1: number, B1: number, C1: number, A2: number, K2: any, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] / S[C1]
				S[A1] = v
				S[A2] = v - K2
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] / S[C1]
			S[A1] = v
			S[A2] = v - K2
			return Next
		end
	end

	Fused.ArithArith.DIV_MUL = {}
	-- DIV as the left operand of MUL.
	Fused.ArithArith.DIV_MUL.L = function(A1: number, B1: number, C1: number, A2: number, O: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] / S[C1]
				S[A1] = v
				S[A2] = v * S[O]
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] / S[C1]
			S[A1] = v
			S[A2] = v * S[O]
			return Next
		end
	end

	-- DIV as the right operand of MUL.
	Fused.ArithArith.DIV_MUL.R = function(A1: number, B1: number, C1: number, A2: number, O: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] / S[C1]
				S[A1] = v
				S[A2] = S[O] * v
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] / S[C1]
			S[A1] = v
			S[A2] = S[O] * v
			return Next
		end
	end

	-- DIV feeding MULK.
	Fused.ArithArithK.DIV_MUL = function(A1: number, B1: number, C1: number, A2: number, K2: any, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] / S[C1]
				S[A1] = v
				S[A2] = v * K2
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] / S[C1]
			S[A1] = v
			S[A2] = v * K2
			return Next
		end
	end

	Fused.ArithArith.DIV_DIV = {}
	-- DIV as the left operand of DIV.
	Fused.ArithArith.DIV_DIV.L = function(A1: number, B1: number, C1: number, A2: number, O: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] / S[C1]
				S[A1] = v
				S[A2] = v / S[O]
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] / S[C1]
			S[A1] = v
			S[A2] = v / S[O]
			return Next
		end
	end

	-- DIV as the right operand of DIV.
	Fused.ArithArith.DIV_DIV.R = function(A1: number, B1: number, C1: number, A2: number, O: number, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] / S[C1]
				S[A1] = v
				S[A2] = S[O] / v
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] / S[C1]
			S[A1] = v
			S[A2] = S[O] / v
			return Next
		end
	end

	-- DIV feeding DIVK.
	Fused.ArithArithK.DIV_DIV = function(A1: number, B1: number, C1: number, A2: number, K2: any, Next: Handler, Chain: boolean): Handler
		if Chain then
			return function(S)
				local v = S[B1] / S[C1]
				S[A1] = v
				S[A2] = v / K2
				return Next(S)
			end
		end
		return function(S)
			local v = S[B1] / S[C1]
			S[A1] = v
			S[A2] = v / K2
			return Next
		end
	end

	-- Constant-key field load feeding JUMPIF.
	Fused.Branch.GetKTruthy = function(A1: number, B1: number, K1: any, N: Handler, NC: boolean, T: Handler, TC: boolean): Handler
		if NC and TC then
			return function(S)
				local v = S[B1][K1]
				S[A1] = v
				if v then
					return T(S)
				end
				return N(S)
			end
		elseif NC then
			return function(S)
				local v = S[B1][K1]
				S[A1] = v
				if v then
					return T
				end
				return N(S)
			end
		elseif TC then
			return function(S)
				local v = S[B1][K1]
				S[A1] = v
				if v then
					return T(S)
				end
				return N
			end
		end
		return function(S)
			local v = S[B1][K1]
			S[A1] = v
			if v then
				return T
			end
			return N
		end
	end

	-- Constant-key field load feeding a JUMPXEQK compare.
	Fused.Branch.GetKEqK = function(A1: number, B1: number, K1: any, K2: any, N: Handler, NC: boolean, T: Handler, TC: boolean): Handler
		if NC and TC then
			return function(S)
				local v = S[B1][K1]
				S[A1] = v
				if v == K2 then
					return T(S)
				end
				return N(S)
			end
		elseif NC then
			return function(S)
				local v = S[B1][K1]
				S[A1] = v
				if v == K2 then
					return T
				end
				return N(S)
			end
		elseif TC then
			return function(S)
				local v = S[B1][K1]
				S[A1] = v
				if v == K2 then
					return T(S)
				end
				return N
			end
		end
		return function(S)
			local v = S[B1][K1]
			S[A1] = v
			if v == K2 then
				return T
			end
			return N
		end
	end

	-- Constant-key field load feeding JUMPIF; value not kept.
	Fused.Branch.GetKTruthyDead = function(A1: number, B1: number, K1: any, N: Handler, NC: boolean, T: Handler, TC: boolean): Handler
		if NC and TC then
			return function(S)
				local v = S[B1][K1]
				if v then
					return T(S)
				end
				return N(S)
			end
		elseif NC then
			return function(S)
				local v = S[B1][K1]
				if v then
					return T
				end
				return N(S)
			end
		elseif TC then
			return function(S)
				local v = S[B1][K1]
				if v then
					return T(S)
				end
				return N
			end
		end
		return function(S)
			local v = S[B1][K1]
			if v then
				return T
			end
			return N
		end
	end

	-- Constant-key field load feeding a JUMPXEQK compare; value not kept.
	Fused.Branch.GetKEqKDead = function(A1: number, B1: number, K1: any, K2: any, N: Handler, NC: boolean, T: Handler, TC: boolean): Handler
		if NC and TC then
			return function(S)
				local v = S[B1][K1]
				if v == K2 then
					return T(S)
				end
				return N(S)
			end
		elseif NC then
			return function(S)
				local v = S[B1][K1]
				if v == K2 then
					return T
				end
				return N(S)
			end
		elseif TC then
			return function(S)
				local v = S[B1][K1]
				if v == K2 then
					return T(S)
				end
				return N
			end
		end
		return function(S)
			local v = S[B1][K1]
			if v == K2 then
				return T
			end
			return N
		end
	end

	-- Register-key table load feeding JUMPIF.
	Fused.Branch.GetTruthy = function(A1: number, B1: number, C1: number, N: Handler, NC: boolean, T: Handler, TC: boolean): Handler
		if NC and TC then
			return function(S)
				local v = S[B1][S[C1]]
				S[A1] = v
				if v then
					return T(S)
				end
				return N(S)
			end
		elseif NC then
			return function(S)
				local v = S[B1][S[C1]]
				S[A1] = v
				if v then
					return T
				end
				return N(S)
			end
		elseif TC then
			return function(S)
				local v = S[B1][S[C1]]
				S[A1] = v
				if v then
					return T(S)
				end
				return N
			end
		end
		return function(S)
			local v = S[B1][S[C1]]
			S[A1] = v
			if v then
				return T
			end
			return N
		end
	end

	-- Register-key table load feeding a JUMPXEQK compare.
	Fused.Branch.GetEqK = function(A1: number, B1: number, C1: number, K2: any, N: Handler, NC: boolean, T: Handler, TC: boolean): Handler
		if NC and TC then
			return function(S)
				local v = S[B1][S[C1]]
				S[A1] = v
				if v == K2 then
					return T(S)
				end
				return N(S)
			end
		elseif NC then
			return function(S)
				local v = S[B1][S[C1]]
				S[A1] = v
				if v == K2 then
					return T
				end
				return N(S)
			end
		elseif TC then
			return function(S)
				local v = S[B1][S[C1]]
				S[A1] = v
				if v == K2 then
					return T(S)
				end
				return N
			end
		end
		return function(S)
			local v = S[B1][S[C1]]
			S[A1] = v
			if v == K2 then
				return T
			end
			return N
		end
	end

	-- Register-key table load feeding JUMPIF; value not kept.
	Fused.Branch.GetTruthyDead = function(A1: number, B1: number, C1: number, N: Handler, NC: boolean, T: Handler, TC: boolean): Handler
		if NC and TC then
			return function(S)
				local v = S[B1][S[C1]]
				if v then
					return T(S)
				end
				return N(S)
			end
		elseif NC then
			return function(S)
				local v = S[B1][S[C1]]
				if v then
					return T
				end
				return N(S)
			end
		elseif TC then
			return function(S)
				local v = S[B1][S[C1]]
				if v then
					return T(S)
				end
				return N
			end
		end
		return function(S)
			local v = S[B1][S[C1]]
			if v then
				return T
			end
			return N
		end
	end

	-- Register-key table load feeding a JUMPXEQK compare; value not kept.
	Fused.Branch.GetEqKDead = function(A1: number, B1: number, C1: number, K2: any, N: Handler, NC: boolean, T: Handler, TC: boolean): Handler
		if NC and TC then
			return function(S)
				local v = S[B1][S[C1]]
				if v == K2 then
					return T(S)
				end
				return N(S)
			end
		elseif NC then
			return function(S)
				local v = S[B1][S[C1]]
				if v == K2 then
					return T
				end
				return N(S)
			end
		elseif TC then
			return function(S)
				local v = S[B1][S[C1]]
				if v == K2 then
					return T(S)
				end
				return N
			end
		end
		return function(S)
			local v = S[B1][S[C1]]
			if v == K2 then
				return T
			end
			return N
		end
	end

	-- MODK feeding JUMPIF.
	Fused.Branch.ModKTruthy = function(A1: number, B1: number, K1: any, N: Handler, NC: boolean, T: Handler, TC: boolean): Handler
		if NC and TC then
			return function(S)
				local v = S[B1] % K1
				S[A1] = v
				if v then
					return T(S)
				end
				return N(S)
			end
		elseif NC then
			return function(S)
				local v = S[B1] % K1
				S[A1] = v
				if v then
					return T
				end
				return N(S)
			end
		elseif TC then
			return function(S)
				local v = S[B1] % K1
				S[A1] = v
				if v then
					return T(S)
				end
				return N
			end
		end
		return function(S)
			local v = S[B1] % K1
			S[A1] = v
			if v then
				return T
			end
			return N
		end
	end

	-- MODK feeding a JUMPXEQK compare.
	Fused.Branch.ModKEqK = function(A1: number, B1: number, K1: any, K2: any, N: Handler, NC: boolean, T: Handler, TC: boolean): Handler
		if NC and TC then
			return function(S)
				local v = S[B1] % K1
				S[A1] = v
				if v == K2 then
					return T(S)
				end
				return N(S)
			end
		elseif NC then
			return function(S)
				local v = S[B1] % K1
				S[A1] = v
				if v == K2 then
					return T
				end
				return N(S)
			end
		elseif TC then
			return function(S)
				local v = S[B1] % K1
				S[A1] = v
				if v == K2 then
					return T(S)
				end
				return N
			end
		end
		return function(S)
			local v = S[B1] % K1
			S[A1] = v
			if v == K2 then
				return T
			end
			return N
		end
	end

	-- MODK feeding JUMPIF; value not kept.
	Fused.Branch.ModKTruthyDead = function(A1: number, B1: number, K1: any, N: Handler, NC: boolean, T: Handler, TC: boolean): Handler
		if NC and TC then
			return function(S)
				local v = S[B1] % K1
				if v then
					return T(S)
				end
				return N(S)
			end
		elseif NC then
			return function(S)
				local v = S[B1] % K1
				if v then
					return T
				end
				return N(S)
			end
		elseif TC then
			return function(S)
				local v = S[B1] % K1
				if v then
					return T(S)
				end
				return N
			end
		end
		return function(S)
			local v = S[B1] % K1
			if v then
				return T
			end
			return N
		end
	end

	-- MODK feeding a JUMPXEQK compare; value not kept.
	Fused.Branch.ModKEqKDead = function(A1: number, B1: number, K1: any, K2: any, N: Handler, NC: boolean, T: Handler, TC: boolean): Handler
		if NC and TC then
			return function(S)
				local v = S[B1] % K1
				if v == K2 then
					return T(S)
				end
				return N(S)
			end
		elseif NC then
			return function(S)
				local v = S[B1] % K1
				if v == K2 then
					return T
				end
				return N(S)
			end
		elseif TC then
			return function(S)
				local v = S[B1] % K1
				if v == K2 then
					return T(S)
				end
				return N
			end
		end
		return function(S)
			local v = S[B1] % K1
			if v == K2 then
				return T
			end
			return N
		end
	end

	return Fused
end)()

-- Ops/Loops.luau
local Module_Loops = (function()
	-- Loop handlers: every bytecode loop runs as a real host loop.
	-- Numeric and generic for loops use the host's own for statements (including its next/inext fast paths and
	-- generalized iteration); other loops run their body in a local trampoline.
	--
	-- Body protocol: the body returns Token to continue, nil when the function returned, a member handler when it
	-- bounced inside the loop, or anything else when control leaves the loop (break, outer continue, exit).
	-- @param Body Handler – first handler of the loop body
	-- @param Token any – value the body returns to start the next iteration
	-- @param Members { [Handler]: boolean } – handlers the body may bounce to without leaving the loop
	-- @param Exit Handler – successor after normal termination
	-- @param Chain boolean – whether Exit is chained



	local pack = table.pack
	local move = table.move
	local getmetatable = getmetatable
	local next = next

	local Loops = {}

	-- Runs body bounces until the iteration ends; returns Token to continue or the value that leaves the loop.
	local function Settle(S: { any }, f: any, Token: any, Members: { [any]: boolean }): any
		while Members[f] do
			f = f(S)
			if f == Token then
				return f
			end
		end
		return f
	end

	-- FORNPREP/FORNLOOP: runs a host numeric for; the setup operands may be registers or constant slots.
	-- @param I number – frame index of the visible loop variable
	-- @param Limit number – frame index of the limit
	-- @param Step number – frame index of the step
	-- @param Start number – frame index of the initial value
	-- @param Empty Handler? – successor when the loop runs zero times, when the compiler gave it its own exit
	-- @param EmptyChain boolean? – whether Empty is chained
	function Loops.Numeric(I: number, Limit: number, Step: number, Start: number, Body: Handler, Token: any, Members: { [any]: boolean }, Exit: Handler, Chain: boolean, Empty: Handler?, EmptyChain: boolean?): Handler
		if Empty then
			return function(S)
				local entered = false
				for i = S[Start], S[Limit], S[Step] do
					entered = true
					S[I] = i
					local f = Body(S)
					if f ~= Token then
						f = Settle(S, f, Token, Members)
						if f ~= Token then
							return f
						end
					end
				end
				if not entered then
					return if EmptyChain then (Empty :: Handler)(S) else Empty
				end
				return if Chain then Exit(S) else Exit
			end
		end
		return function(S)
			for i = S[Start], S[Limit], S[Step] do
				S[I] = i
				local f = Body(S)
				if f ~= Token then
					f = Settle(S, f, Token, Members)
					if f ~= Token then
						return f
					end
				end
			end
			if Chain then
				return Exit(S)
			end
			return Exit
		end
	end

	-- FORGPREP*/FORGLOOP: registers A generator, A+1 state, A+2 control, variables from A+3.
	-- @param Count number – loop variable count
	function Loops.Generic(A: number, Count: number, Body: Handler, Token: any, Members: { [any]: boolean }, Exit: Handler, Chain: boolean): Handler
		local A1, A2, A3, A4, A5 = A + 1, A + 2, A + 3, A + 4, A + 5
		local function Leave(S: { any }): any
			if Chain then
				return Exit(S)
			end
			return Exit
		end

		if Count == 1 then
			return function(S)
				for a in S[A], S[A1], S[A2] do
					S[A3] = a
					local f = Body(S)
					if f ~= Token then
						f = Settle(S, f, Token, Members)
						if f ~= Token then
							return f
						end
					end
				end
				return Leave(S)
			end
		elseif Count == 2 then
			return function(S)
				for a, b in S[A], S[A1], S[A2] do
					S[A3], S[A4] = a, b
					local f = Body(S)
					if f ~= Token then
						f = Settle(S, f, Token, Members)
						if f ~= Token then
							return f
						end
					end
				end
				return Leave(S)
			end
		elseif Count == 3 then
			return function(S)
				for a, b, c in S[A], S[A1], S[A2] do
					S[A3], S[A4], S[A5] = a, b, c
					local f = Body(S)
					if f ~= Token then
						f = Settle(S, f, Token, Members)
						if f ~= Token then
							return f
						end
					end
				end
				return Leave(S)
			end
		end

		-- wide loops: generalized iteration done by hand (tables iterate like next, __iter is honoured)
		return function(S)
			local gen, state, control = S[A], S[A1], S[A2]
			if type(gen) ~= "function" then
				local mt = getmetatable(gen)
				local iter = if type(mt) == "table" then mt.__iter else nil
				if iter then
					gen, state, control = iter(gen)
				elseif type(gen) == "table" then
					gen, state, control = next, gen, nil
				else
					error(`attempt to iterate over a {typeof(gen)} value`)
				end
			end
			while true do
				local values = pack(gen(state, control))
				control = values[1]
				if control == nil then
					break
				end
				move(values, 1, Count, A3, S)
				local f = Body(S)
				if f ~= Token then
					f = Settle(S, f, Token, Members)
					if f ~= Token then
						return f
					end
				end
			end
			return Leave(S)
		end
	end

	-- Loops closed by a backward jump (while, repeat, goto-free continue): the body restarts on Token.
	function Loops.Back(Body: Handler, Token: any, Members: { [any]: boolean }): Handler
		return function(S)
			local f = Body(S)
			while true do
				if f == Token then
					f = Body(S)
				elseif Members[f] then
					f = f(S)
				else
					return f
				end
			end
		end
	end

	return Loops
end)()

-- Ops/Objects.luau
local Module_Objects = (function()
	-- Class instruction handlers: NEWCLASS, NEWCLASSMEMBER, CONSTRUCT, GETPRIVATEFIELD, SETPRIVATEFIELD.
	-- The object model itself lives in Classes; errors are raised here so the Debug option positions them at the guest
	-- instruction, as the host raises them from its interpreter loop.

	local Classes = Module_Classes


	local Of, StoreOf, TypeName = Classes.Of, Classes.StoreOf, Classes.TypeName
	local IsInstance, IsSubclass, PrivateStatic = Classes.IsInstance, Classes.IsSubclass, Classes.PrivateStatic

	local Objects = {}

	-- Reads an upvalue holding a class: by value, or through a shared cell.
	local function Upvalue(S: { any }, U: number, Boxed: boolean): any
		local value = S[1][U]
		if Boxed then
			return value[1][value[2]]
		end
		return value
	end

	-- NEWCLASS: hands out the loaded class value; with a superclass, a flattened class derived from both.
	-- @param Proxy any – class value built by the loader from its shape constant
	-- @param Super number? – frame index of the superclass, or nil
	-- @param Open boolean – whether the class may be extended
	function Objects.NewClass(A: number, Proxy: any, Super: number?, Open: boolean, Next: Handler, Chain: boolean): Handler
		local record = Of(Proxy) :: Class
		return function(S)
			S[A] = Proxy
			record.IsOpen = Open
			if Super then
				local parent = S[Super]
				if Of(parent) == nil then
					error(`attempt to extend a {TypeName(parent)} value`)
				end
				S[A] = Classes.Inherit(Proxy, parent)
			end
			return if Chain then Next(S) else Next
		end
	end

	-- NEWCLASSMEMBER: registers a method (or metamethod) on the class in A.
	-- @param Name string? – public member name, or nil for a private method
	-- @param Index number – private method index
	-- @param C number – frame index of the value
	function Objects.NewMember(A: number, Name: string?, Index: number, C: number, Next: Handler, Chain: boolean): Handler
		if Name then
			return function(S)
				Classes.AddPublic(S[A], Name, S[C])
				return if Chain then Next(S) else Next
			end
		end
		return function(S)
			Classes.AddPrivate(S[A], Index, S[C])
			return if Chain then Next(S) else Next
		end
	end

	-- GETPRIVATEFIELD: a private field of an instance, or a private method of an instance or class.
	-- @param U number – upvalue index (1-based) holding the declaring class
	-- @param Boxed boolean – whether that upvalue is a shared cell
	-- @param Index number – private field offset within the declaring class, or private method index
	-- @param Static boolean – whether Index names a private method
	-- @param Namecall boolean – also store the object in A + 1, for a method call
	function Objects.GetPrivate(A: number, B: number, U: number, Boxed: boolean, Index: number, Static: boolean, Namecall: boolean, Next: Handler, Chain: boolean): Handler
		return function(S)
			local value = S[B]
			local store = StoreOf(value)
			local owner = if store == nil then Of(value) else nil
			if store == nil and owner == nil then
				error(`attempt to access private field of a {TypeName(value)} value`)
			end
			local clsv = Upvalue(S, U, Boxed)
			local cls = Of(clsv)
			if cls == nil then
				error(`attempt to verify object is an instance of a {TypeName(clsv)} value`)
			end
			local result
			if store then
				if not IsInstance(store, cls) then
					error("attempt to illegally access private field")
				end
				result = if Static then PrivateStatic(cls, Index) else store[Index + cls.OwnPrivateStart + 1]
			else
				if not IsSubclass(owner :: Class, cls) then
					error("attempt to illegally access private field of a class")
				elseif not Static then
					error("attempt to access private instance field of a class")
				end
				result = PrivateStatic(cls, Index)
			end
			if Namecall then
				S[A + 1] = value
			end
			S[A] = result
			return if Chain then Next(S) else Next
		end
	end

	-- SETPRIVATEFIELD: assigns a private field of an instance of the declaring class (or a subclass).
	function Objects.SetPrivate(A: number, B: number, U: number, Boxed: boolean, Index: number, Next: Handler, Chain: boolean): Handler
		return function(S)
			local value = S[B]
			local store = StoreOf(value)
			if store == nil then
				error(`attempt to assign private field of a {TypeName(value)} value`)
			end
			local clsv = Upvalue(S, U, Boxed)
			local cls = Of(clsv)
			if cls == nil then
				error(`attempt to assign private field of a {TypeName(clsv)} value`)
			end
			if not IsInstance(store, cls) then
				error("attempt to assign private field of an object with a different class")
			end
			store[Index + cls.OwnPrivateStart + 1] = S[A]
			return if Chain then Next(S) else Next
		end
	end

	return Objects
end)()

-- Ops/Tables.luau
local Module_Tables = (function()
	-- Table construction and indexing handlers.
	-- Indexing is native so __index/__newindex and userdata (e.g. Instances) behave exactly as in host code.
	-- @param Next Handler – successor, or a loop token in returning mode
	-- @param Chain boolean – whether to call Next directly

	local Runtime = Module_Runtime


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
end)()

-- Ops/Values.luau
local Module_Values = (function()
	-- Handlers that move values: constants, registers, globals, upvalues and varargs.
	-- Each maker returns a chained handler (calls its successor) or a returning one (hands the successor back to a trampoline).
	-- @param Next Handler – successor, or a loop token in returning mode
	-- @param Chain boolean – whether to call Next directly

	local Runtime = Module_Runtime


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
end)()

-- Compiler.luau
local Module_Compiler = (function()
	-- Turns deserialized protos into handler graphs.
	--
	-- Every live instruction becomes one handler closure with its operands captured as upvalues. Analysis decides the
	-- control-flow plan and which loads fold into calls; this module maps each instruction to its handler maker.
	-- Handlers are built back to front so forward successors already exist; edges to a loop's continue point return
	-- the loop's token, so no handler needs patching after creation.

	local Runtime = Module_Runtime
	local Analysis = Module_Analysis
	local Values = Module_Values
	local Arith = Module_Arith
	local Tables = Module_Tables
	local Calls = Module_Calls
	local Branches = Module_Branches
	local Loops = Module_Loops
	local Closures = Module_Closures
	local Env = Module_Env
	local Fused = Module_Fused
	local Objects = Module_Objects
	local Classes = Module_Classes


	local band = bit32.band
	local rshift = bit32.rshift

	local BASE = Runtime.BASE
	local Op = Analysis.Op
	local HAS_AUX = Analysis.HAS_AUX

	local ARITH_NAMES = { [0] = "ADD", "SUB", "MUL", "DIV", "MOD", "POW" }

	-- Two-successor opcodes and whether the condition is negated (successors swapped).
	local BRANCH: { [number]: boolean } = {
		[Op.JUMPIF] = false, [Op.JUMPIFNOT] = true, [Op.JUMPIFEQ] = false, [Op.JUMPIFNOTEQ] = true,
		[Op.JUMPIFLE] = false, [Op.JUMPIFNOTLE] = true, [Op.JUMPIFLT] = false, [Op.JUMPIFNOTLT] = true,
		[Op.JUMPXEQKNIL] = false, [Op.JUMPXEQKB] = false, [Op.JUMPXEQKN] = false, [Op.JUMPXEQKS] = false,
	}

	type Context = {
		Cells: { { boolean } },
		Factories: { Factory },
		Env: any,
		SafeEnv: boolean,
		ChunkName: string?,
		Dyn: EnvState?, -- DynamicEnv state; nil binds globals to Env at load
		Debug: boolean, -- track the running pc so host-raised errors carry guest positions
		Classes: boolean, -- class bytecode: class-aware builtins and the `class` library
	}

	-- Decides which upvalues of every proto are shared cells; a child slot is a cell when any capture site passes a
	-- reference. Iterates to a fixed point because inlining can give a proto several parents.
	local function ResolveCells(chunk: Chunk): { { boolean } }
		local protos = chunk.Protos
		local cells: { { boolean } } = {}
		for i = 1, #protos do
			cells[i] = {}
		end

		local changed = true
		while changed do
			changed = false
			for index, proto in protos do
				local code = proto.Code
				local pc = 1
				while pc <= #code do
					local w = code[pc]
					local op = band(w, 0xFF)
					if op == Op.NEWCLOSURE or op == Op.DUPCLOSURE then
						local d = rshift(w, 16)
						d = if d >= 0x8000 then d - 0x10000 else d
						local child = if op == Op.NEWCLOSURE then proto.Children[d + 1] else proto.Closures[d + 1]
						local childCells = cells[child]
						for i = 1, protos[child].Upvalues do
							local capture = code[pc + i]
							local kind = band(rshift(capture, 8), 0xFF)
							local source = band(rshift(capture, 16), 0xFF)
							local isCell = kind == 1 or (kind == 2 and cells[index][source + 1] == true)
							if isCell and not childCells[i] then
								childCells[i] = true
								changed = true
							end
						end
					end
					pc += if HAS_AUX[op] then 2 else 1
				end
			end
		end

		return cells
	end

	-- Wraps error() so a message raised at level 1 carries the guest call site, not the handler's.
	-- Higher levels name host frames the guest cannot see, so those messages stay bare.
	-- @param where string – "chunk:line: " prefix of the call site
	local function GuestError(where: string): (...any) -> ()
		return function(message: any, level: any)
			local kind = type(message)
			if (kind == "string" or kind == "number") and (level == nil or level == 1) then
				error(where .. message, 0)
			end
			error(message, 0)
		end
	end

	-- Wraps assert() so its messages carry the guest call site, as luaL_error adds it in the host.
	-- @param where string – "chunk:line: " prefix of the call site
	local function GuestAssert(where: string): (...any) -> ...any
		return function(...: any): ...any
			if (...) then
				return ...
			end
			local count = select("#", ...)
			if count == 0 then
				error(where .. "missing argument #1", 0)
			end
			local message = if count >= 2 then select(2, ...) else nil
			if message == nil then
				error(where .. "assertion failed!", 0)
			end
			local kind = type(message)
			if kind ~= "string" and kind ~= "number" then
				return assert(...) -- the host's own argument error
			end
			error(where .. message, 0)
		end
	end

	-- Debug mode: frame key holding the pc of the running handler
	local PC = "\0pc"

	-- Debug mode: records the handler's pc before running it.
	-- @param h Handler – handler to wrap
	-- @param pc number – its instruction
	local function Track(h: Handler, pc: number): Handler
		return function(S)
			S[PC] = pc
			return h(S)
		end
	end

	-- Runs a proto body to completion on the frame (the factory's trampoline).
	local function Run(entry: Handler, S: Frame)
		local f = entry(S)
		while f do
			f = f(S)
		end
	end

	-- Debug mode: runs the body under pcall and repositions errors raised inside interpreter handlers.
	-- @param entry Handler – the proto's first handler
	-- @param Where (number) -> string – guest position prefix of a pc
	local function Guard(entry: Handler, Where: (number) -> string): Handler
		return function(S)
			local ok, err = pcall(Run, entry, S)
			if not ok then
				local pc = S[PC]
				error(Env.Reposition(err, if pc then Where(pc) else ""), 0)
			end
			return nil
		end
	end

	-- Compiles one proto; returns its entry handler and the constant slot layout its factory preloads.
	-- @param proto Proto – deserialized proto
	-- @param index number – proto index (selects its cell layout)
	-- @param ctx Context – chunk-wide compilation state
	local function CompileProto(proto: Proto, index: number, ctx: Context): (Handler, { any }, number)
		local cells = ctx.Cells[index]
		local env = ctx.Env
		local K = proto.Constants
		local dyn = ctx.Dyn
		local safe = ctx.SafeEnv and dyn == nil

		-- class chunks: `class` is the interpreter's library, and type/typeof/getmetatable resolve to class-aware versions
		local ClassRoot = { class = Classes.Library }
		local function ResolveClassImport(path: { any }): any
			if path[1] == "class" then
				return Analysis.ResolveImport(ClassRoot, path)
			elseif not safe then
				return nil
			end
			local value = Analysis.ResolveImport(env, path)
			if value ~= nil and Classes.Swaps[value] ~= nil then
				value = Classes.Swaps[value]
			end
			return value
		end

		local prog = Analysis.Analyze(proto, cells, env, safe, ctx.Debug, if ctx.Classes then ResolveClassImport else nil)

		local OpOf, OA, OB, OC, OD, Aux, Len = prog.Op, prog.A, prog.B, prog.C, prog.D, prog.Aux, prog.Len
		local base = prog.Base
		local consts = prog.Consts

		-- Frame index of a call operand: register r >= 0, or constant slot -c.
		local function Slot(operand: number): number
			return if operand >= 0 then operand + base else BASE - 1 - operand
		end

		-- "chunk:line: " prefix for errors raised on behalf of the instruction at pc.
		local function Where(pc: number): string
			local lines = proto.Lines
			local name = ctx.ChunkName
			if lines and name and lines[pc] then
				return `{name}:{lines[pc]}: `
			end
			return ""
		end

		-- Values swapped when guest code reads them: VM-aware getfenv/setfenv, positioned error/assert wrappers.
		local function Swaps(pc: number): { [any]: any }?
			local swaps: { [any]: any }? = nil
			if dyn then
				swaps = { [Env.HostGetfenv] = dyn.getfenv, [Env.HostSetfenv] = dyn.setfenv }
			end
			if ctx.Classes then
				swaps = swaps or {}
				for host, replacement in Classes.Swaps do
					(swaps :: any)[host] = replacement
				end
			end
			local site = prog.Positioned[pc]
			local where = if site then Where(site) else ""
			if where ~= "" then
				swaps = swaps or {}
				;(swaps :: any)[error] = GuestError(where)
				;(swaps :: any)[assert] = GuestAssert(where)
			end
			return swaps
		end

		local Top: { [number]: Handler } = {}

		local function Value(edge: Edge): (any, boolean)
			if edge.Loop then
				return edge.Loop.Token, false
			end
			local h = Top[edge.Pc]
			assert(h, "successor built out of order")
			return h, edge.Chain
		end

		local function Unsupported(op: number): Handler
			return function(_S)
				error(`unsupported opcode {op}`)
			end
		end

		-- Builds a call whose operand loads Analysis folded in; nil when the call was left as is.
		local function BuildCall(pc: number, A: number, results: number, nextH: Handler, chain: boolean): Handler?
			local plan = prog.Calls[pc]
			if not plan then
				return nil
			end
			if plan.Kind == "select" then
				return Calls.SelectVararg(A, Slot(plan.Args[1]), nextH, chain)
			end
			local args = table.create(#plan.Args)
			for i, operand in plan.Args do
				args[i] = Slot(operand)
			end
			if plan.Kind == "namecall" then
				table.remove(args, 1) -- self is passed by the method handler
				return Calls.Method(A, Slot(plan.Object :: number), plan.Method :: string, args, results, Where(pc), nextH, chain)
			end
			local callee = plan.Callee
			if callee and callee < 0 then
				-- error/assert get a per-site wrapper so their messages carry guest positions
				local fn = consts[-callee]
				local where = Where(pc)
				if where ~= "" and (rawequal(fn, error) or rawequal(fn, assert)) then
					local wrapped = if rawequal(fn, error) then GuestError(where) else GuestAssert(where)
					return Calls.Direct(A, wrapped, args, results, nextH, chain)
				end
			end
			return Calls.Call(A, if callee then Slot(callee) else nil, plan.CalleeUp, args, results, nextH, chain)
		end

		-- Constant key of a GETTABLEKS/GETTABLEN/SETTABLEKS/SETTABLEN.
		local function FieldKey(pc: number): any
			local op = OpOf[pc]
			if op == Op.GETTABLEN or op == Op.SETTABLEN then
				return OC[pc] + 1
			end
			return K[Aux[pc] + 1]
		end

		-- Builds the fused handler of an adjacent pair chosen by Analysis.
		local function BuildPair(p1: number, p2: number, nextH: Handler, chain: boolean): Handler
			local o1, o2 = OpOf[p1], OpOf[p2]
			local A1, B1, C1 = OA[p1] + base, OB[p1] + base, OC[p1] + base
			local A2, B2, C2 = OA[p2] + base, OB[p2] + base, OC[p2] + base
			local get1 = o1 == Op.GETTABLEKS or o1 == Op.GETTABLEN
			local get2 = o2 == Op.GETTABLEKS or o2 == Op.GETTABLEN
			local set1 = o1 == Op.SETTABLEKS or o1 == Op.SETTABLEN
			local set2 = o2 == Op.SETTABLEKS or o2 == Op.SETTABLEN
			local rr1 = o1 >= Op.ADD and o1 <= Op.DIV
			local rr2 = o2 >= Op.ADD and o2 <= Op.DIV
			local rk1 = o1 >= Op.ADDK and o1 <= Op.DIVK
			local rk2 = o2 >= Op.ADDK and o2 <= Op.DIVK

			if o1 == Op.GETUPVAL then
				if get2 then
					return Fused.UpGetK(A1, OB[p1] + 1, A2, FieldKey(p2), nextH, chain)
				end
				return Fused.UpGet(A1, OB[p1] + 1, A2, C2, nextH, chain)
			elseif get1 then
				local K1 = FieldKey(p1)
				if get2 then
					return Fused.GetGet(A1, B1, K1, A2, B2, FieldKey(p2), nextH, chain)
				elseif set2 then
					return Fused.GetSet(A1, B1, K1, B2, FieldKey(p2), nextH, chain)
				elseif rr2 then
					local name = ARITH_NAMES[o2 - Op.ADD]
					if B2 == A1 then
						return Fused.GetArith[name].L(A1, B1, K1, A2, C2, nextH, chain)
					end
					return Fused.GetArith[name].R(A1, B1, K1, A2, B2, nextH, chain)
				elseif rk2 then
					return Fused.GetArithK[ARITH_NAMES[o2 - Op.ADDK]](A1, B1, K1, A2, K[OC[p2] + 1], nextH, chain)
				end
			elseif o1 == Op.GETTABLE and rr2 then
				local name = ARITH_NAMES[o2 - Op.ADD]
				if B2 == A1 then
					return Fused.GetRArith[name].L(A1, B1, C1, A2, C2, nextH, chain)
				end
				return Fused.GetRArith[name].R(A1, B1, C1, A2, B2, nextH, chain)
			elseif set1 and get2 then
				return Fused.SetGet(A1, B1, FieldKey(p1), A2, B2, FieldKey(p2), nextH, chain)
			elseif rr1 then
				local name1 = ARITH_NAMES[o1 - Op.ADD]
				if o2 == Op.SETTABLE then
					return Fused.ArithSetR[name1](A1, B1, C1, B2, C2, nextH, chain)
				elseif set2 then
					return Fused.ArithSet[name1](A1, B1, C1, B2, FieldKey(p2), nextH, chain)
				elseif rr2 then
					local key = name1 .. "_" .. ARITH_NAMES[o2 - Op.ADD]
					if B2 == A1 then
						return Fused.ArithArith[key].L(A1, B1, C1, A2, C2, nextH, chain)
					end
					return Fused.ArithArith[key].R(A1, B1, C1, A2, B2, nextH, chain)
				elseif rk2 then
					local key = name1 .. "_" .. ARITH_NAMES[o2 - Op.ADDK]
					return Fused.ArithArithK[key](A1, B1, C1, A2, K[OC[p2] + 1], nextH, chain)
				end
			elseif rk1 and o2 == Op.SETTABLE then
				return Fused.ArithKSetR[ARITH_NAMES[o1 - Op.ADDK]](A1, B1, K[OC[p1] + 1], B2, C2, nextH, chain)
			elseif rk1 and set2 then
				return Fused.ArithKSet[ARITH_NAMES[o1 - Op.ADDK]](A1, B1, K[OC[p1] + 1], B2, FieldKey(p2), nextH, chain)
			end
			error(`no fused handler for opcodes {o1} and {o2}`)
		end

		-- Builds a value computation fused with the branch that tests it.
		local function BuildBranchPair(p1: number, p2: number): Handler
			local n, nc = Value(prog.EdgeN[p1])
			local t, tc = Value(prog.EdgeT[p1])
			local o1, o2 = OpOf[p1], OpOf[p2]
			local A1, B1 = OA[p1] + base, OB[p1] + base
			local dead = if prog.BranchDead[p1] then "Dead" else ""
			local first, operand
			if o1 == Op.GETTABLE then
				first, operand = "Get", OC[p1] + base
			elseif o1 == Op.MODK then
				first, operand = "ModK", K[OC[p1] + 1]
			else
				first, operand = "GetK", FieldKey(p1)
			end
			if o2 == Op.JUMPIF or o2 == Op.JUMPIFNOT then
				if o2 == Op.JUMPIFNOT then
					n, nc, t, tc = t, tc, n, nc
				end
				return Fused.Branch[first .. "Truthy" .. dead](A1, B1, operand, n, nc, t, tc)
			end
			local aux = Aux[p2]
			if rshift(aux, 31) == 1 then
				n, nc, t, tc = t, tc, n, nc
			end
			local k = if o2 == Op.JUMPXEQKNIL then nil elseif o2 == Op.JUMPXEQKB then band(aux, 1) == 1 else K[band(aux, 0xFFFFFF) + 1]
			return Fused.Branch[first .. "EqK" .. dead](A1, B1, operand, k, n, nc, t, tc)
		end

		local function Build(pc: number): Handler
			local op = OpOf[pc]
			local A = OA[pc] + base
			local B, C, D = OB[pc], OC[pc], OD[pc]

			if prog.Tail[pc] then
				return Calls.TailCall(A, B - 1)
			elseif op == Op.RETURN then
				return Calls.Return(A, B - 1)
			end

			local loop = prog.LoopAt[pc]
			if loop then
				local body, bodyChain = Value(prog.BodyEdge[pc])
				if not bodyChain then
					local value = body
					body = function()
						return value
					end
				end
				local exit, exitChain = Value(prog.EdgeN[pc])
				if op == Op.FORNPREP then
					local operands = prog.ForOperands[pc]
					local emptyEdge = prog.EdgeE[pc]
					local empty, emptyChain
					if emptyEdge then
						empty, emptyChain = Value(emptyEdge)
					end
					return Loops.Numeric(A + 2, Slot(operands[1]), Slot(operands[2]), Slot(operands[3]), body, loop.Token, loop.Members, exit, exitChain, empty, emptyChain)
				end
				return Loops.Generic(A, band(Aux[loop.Hi], 0xFF), body, loop.Token, loop.Members, exit, exitChain)
			end

			local second = prog.Pairs[pc]
			if second and BRANCH[OpOf[second]] ~= nil then
				return BuildBranchPair(pc, second)
			end

			local branch = BRANCH[op]
			local bool = prog.Bools[pc]
			if bool then
				local edge = prog.EdgeN[pc]
				local nextH, chain
				if edge then
					nextH, chain = Value(edge)
				end
				local aux = Aux[pc]
				local R = bool.Reg + base
				local negate = branch ~= bool.Invert
				if op == Op.JUMPXEQKNIL or op == Op.JUMPXEQKB or op == Op.JUMPXEQKN or op == Op.JUMPXEQKS then
					local k = if op == Op.JUMPXEQKNIL then nil elseif op == Op.JUMPXEQKB then band(aux, 1) == 1 else K[band(aux, 0xFFFFFF) + 1]
					negate = negate ~= (rshift(aux, 31) == 1)
					if bool.Return then
						return Branches.StoreReturn("eqk", A, k, negate)
					end
					return Branches.Store("eqk", R, A, k, negate, nextH, chain)
				elseif op == Op.JUMPIF or op == Op.JUMPIFNOT then
					if bool.Return then
						return Branches.StoreReturn("truthy", A, nil, negate)
					end
					return Branches.Store("truthy", R, A, nil, negate, nextH, chain)
				end
				local other = aux + base
				local folded = prog.CompareK[pc]
				if folded then
					if folded.Side == "A" then
						A = Slot(folded.Operand)
					else
						other = Slot(folded.Operand)
					end
				end
				local kind = if op == Op.JUMPIFEQ or op == Op.JUMPIFNOTEQ then "eq" elseif op == Op.JUMPIFLE or op == Op.JUMPIFNOTLE then "le" else "lt"
				if bool.Return then
					return Branches.StoreReturn(kind, A, other, negate)
				end
				return Branches.Store(kind, R, A, other, negate, nextH, chain)
			end
			if branch ~= nil then
				local n, nc = Value(prog.EdgeN[pc])
				local t, tc = Value(prog.EdgeT[pc])
				local aux = Aux[pc]
				if op == Op.JUMPXEQKNIL or op == Op.JUMPXEQKB or op == Op.JUMPXEQKN or op == Op.JUMPXEQKS then
					if rshift(aux, 31) == 1 then
						n, nc, t, tc = t, tc, n, nc
					end
					local k = if op == Op.JUMPXEQKNIL then nil elseif op == Op.JUMPXEQKB then band(aux, 1) == 1 else K[band(aux, 0xFFFFFF) + 1]
					return Branches.EqK(A, k, n, nc, t, tc)
				end
				if branch then
					n, nc, t, tc = t, tc, n, nc
				end
				if op == Op.JUMPIF or op == Op.JUMPIFNOT then
					return Branches.Truthy(A, n, nc, t, tc)
				end
				local other = aux + base
				local folded = prog.CompareK[pc]
				if folded then
					if folded.Side == "A" then
						A = Slot(folded.Operand)
					else
						other = Slot(folded.Operand)
					end
				end
				if op == Op.JUMPIFEQ or op == Op.JUMPIFNOTEQ then
					return Branches.Eq(A, other, n, nc, t, tc)
				elseif op == Op.JUMPIFLE or op == Op.JUMPIFNOTLE then
					return Branches.Le(A, other, n, nc, t, tc)
				end
				return Branches.Lt(A, other, n, nc, t, tc)
			end

			local nextH, chain = Value(prog.EdgeN[pc])

			if second then
				return BuildPair(pc, second, nextH, chain)
			end

			if prog.Kept[pc] then
				return function(S)
					return if chain then nextH(S) else nextH
				end
			elseif op == Op.LOADNIL then
				return Values.LoadK(A, nil, nextH, chain)
			elseif op == Op.LOADB then
				return Values.LoadK(A, B ~= 0, nextH, chain)
			elseif op == Op.LOADN then
				return Values.LoadK(A, D, nextH, chain)
			elseif op == Op.LOADK then
				return Values.LoadK(A, K[D + 1], nextH, chain)
			elseif op == Op.LOADKX then
				return Values.LoadK(A, K[Aux[pc] + 1], nextH, chain)
			elseif op == Op.MOVE then
				return Values.Move(A, B + base, nextH, chain)
			elseif op == Op.GETGLOBAL and ctx.Classes and K[Aux[pc] + 1] == "class" then
				return Values.LoadK(A, Classes.Library, nextH, chain)
			elseif op == Op.GETGLOBAL and dyn then
				return Values.GetGlobalDyn(A, Env.ENV, K[Aux[pc] + 1], Swaps(pc), nextH, chain)
			elseif op == Op.GETGLOBAL then
				-- the global may be replaced at any time, so swaps (positioned error/assert, class builtins) happen per read
				local swaps = Swaps(pc)
				if swaps then
					return Values.GetGlobalSwapped(A, env, K[Aux[pc] + 1], swaps, nextH, chain)
				end
				return Values.GetGlobal(A, env, K[Aux[pc] + 1], nextH, chain)
			elseif op == Op.SETGLOBAL then
				if dyn then
					return Values.SetGlobalDyn(A, Env.ENV, K[Aux[pc] + 1], nextH, chain)
				end
				return Values.SetGlobal(A, env, K[Aux[pc] + 1], nextH, chain)
			elseif op == Op.GETUPVAL then
				if cells[B + 1] then
					return Values.GetUpvalCell(A, B + 1, nextH, chain)
				end
				return Values.GetUpval(A, B + 1, nextH, chain)
			elseif op == Op.SETUPVAL then
				return Values.SetUpval(A, B + 1, cells[B + 1] == true, nextH, chain)
			elseif op == Op.CLOSEUPVALS then
				return Values.CloseUpvals(A, nextH, chain)
			elseif op == Op.GETIMPORT and ctx.Classes and Analysis.ImportPath(K, Aux[pc])[1] == "class" then
				return Values.LoadK(A, ResolveClassImport(Analysis.ImportPath(K, Aux[pc])), nextH, chain)
			elseif op == Op.GETIMPORT and dyn then
				local path = Analysis.ImportPath(K, Aux[pc])
				local resolved = if ctx.SafeEnv and not dyn.Unsafe[env] then Analysis.ResolveImport(env, path) else nil
				return Values.GetImportDyn(A, Env.ENV, path, resolved, env, dyn.Unsafe, Swaps(pc), nextH, chain)
			elseif op == Op.GETIMPORT then
				local path = Analysis.ImportPath(K, Aux[pc])
				if ctx.SafeEnv then
					local value = prog.Imports[pc]
					if value == nil then
						value = Analysis.ResolveImport(env, path)
					end
					if ctx.Classes and value ~= nil and Classes.Swaps[value] ~= nil then
						value = Classes.Swaps[value]
					end
					local site = prog.Positioned[pc]
					local where = if site then Where(site) else ""
					if where ~= "" and (rawequal(value, error) or rawequal(value, assert)) then
						value = if rawequal(value, error) then GuestError(where) else GuestAssert(where)
					end
					if value ~= nil then
						return Values.LoadK(A, value, nextH, chain)
					end
				end
				local swaps = Swaps(pc)
				if swaps then
					return Values.GetImportSwapped(A, env, path, swaps, nextH, chain)
				end
				return Values.GetImport(A, env, path, nextH, chain)
			elseif op == Op.GETTABLE then
				return Tables.Get(A, B + base, C + base, nextH, chain)
			elseif op == Op.SETTABLE then
				return Tables.Set(A, B + base, C + base, nextH, chain)
			elseif op == Op.GETTABLEKS then
				local key = K[Aux[pc] + 1]
				if dyn and (key == "getfenv" or key == "setfenv") then
					return Values.GetKSwapped(A, B + base, key, Swaps(pc) :: any, nextH, chain)
				end
				return Tables.GetK(A, B + base, key, nextH, chain)
			elseif op == Op.SETTABLEKS then
				return Tables.SetK(A, B + base, K[Aux[pc] + 1], nextH, chain)
			elseif op == Op.GETUDATAKS then
				return Tables.GetK(A, B + base, K[band(Aux[pc], 0xFFFF) + 1], nextH, chain)
			elseif op == Op.SETUDATAKS then
				return Tables.SetK(A, B + base, K[band(Aux[pc], 0xFFFF) + 1], nextH, chain)
			elseif op == Op.GETTABLEN then
				return Tables.GetK(A, B + base, C + 1, nextH, chain)
			elseif op == Op.SETTABLEN then
				return Tables.SetK(A, B + base, C + 1, nextH, chain)
			elseif op == Op.NEWTABLE then
				return Tables.New(A, Aux[pc], if B == 0 then 0 else bit32.lshift(1, B - 1), nextH, chain)
			elseif op == Op.DUPTABLE then
				return Tables.Dup(A, K[D + 1], nextH, chain)
			elseif op == Op.CONSTRUCT then
				-- the property table the CALL after it passes to the class (or to any other callee)
				local shape = proto.Shapes[Aux[pc]]
				assert(shape, "CONSTRUCT without a feedback shape")
				return Tables.Dup(A, K[shape], nextH, chain)
			elseif op == Op.NEWCLASS then
				return Objects.NewClass(A, K[Aux[pc] + 1], if B == 0xFF then nil else B + base, band(C, 1) == 1, nextH, chain)
			elseif op == Op.NEWCLASSMEMBER then
				local aux = Aux[pc]
				local public = band(B, 1) == 0
				return Objects.NewMember(A, if public then K[aux + 1] else nil, band(aux, 0xFF), C + base, nextH, chain)
			elseif op == Op.GETPRIVATEFIELD then
				local aux = Aux[pc]
				return Objects.GetPrivate(A, B + base, C + 1, cells[C + 1] == true, band(aux, 0xFF), band(rshift(aux, 8), 1) == 1, band(rshift(aux, 9), 1) == 1, nextH, chain)
			elseif op == Op.SETPRIVATEFIELD then
				return Objects.SetPrivate(A, B + base, C + 1, cells[C + 1] == true, band(Aux[pc], 0xFF), nextH, chain)
			elseif op == Op.SETLIST then
				if C == 0 then
					return Tables.SetListAll(A, B + base, Aux[pc], nextH, chain)
				end
				return Tables.SetList(A, B + base, C - 1, Aux[pc], nextH, chain)
			elseif op == Op.NAMECALL then
				return Calls.NameCall(A, B + base, K[Aux[pc] + 1], Where(pc), nextH, chain)
			elseif op == Op.NAMECALLUDATA then
				return Calls.NameCall(A, B + base, K[band(Aux[pc], 0xFFFF) + 1], Where(pc), nextH, chain)
			elseif op == Op.CALL or op == Op.CALLFB then
				local fused = BuildCall(pc, A, C - 1, nextH, chain)
				if fused then
					return fused
				end
				if B == 0 then
					return Calls.Call(A, A, nil, nil, C - 1, nextH, chain)
				end
				local args = table.create(B - 1)
				for i = 1, B - 1 do
					args[i] = A + i
				end
				return Calls.Call(A, A, nil, args, C - 1, nextH, chain)
			elseif op >= Op.ADD and op <= Op.POW then
				return Arith.RR[ARITH_NAMES[op - Op.ADD]](A, B + base, C + base, nextH, chain)
			elseif op >= Op.ADDK and op <= Op.POWK then
				return Arith.RK[ARITH_NAMES[op - Op.ADDK]](A, B + base, K[C + 1], nextH, chain)
			elseif op == Op.IDIV then
				return Arith.RR.IDIV(A, B + base, C + base, nextH, chain)
			elseif op == Op.IDIVK then
				return Arith.RK.IDIV(A, B + base, K[C + 1], nextH, chain)
			elseif op == Op.AND then
				return Arith.RR.AND(A, B + base, C + base, nextH, chain)
			elseif op == Op.OR then
				return Arith.RR.OR(A, B + base, C + base, nextH, chain)
			elseif op == Op.ANDK then
				return Arith.RK.AND(A, B + base, K[C + 1], nextH, chain)
			elseif op == Op.ORK then
				return Arith.RK.OR(A, B + base, K[C + 1], nextH, chain)
			elseif op == Op.SUBRK then
				return Arith.SubRK(A, K[B + 1], C + base, nextH, chain)
			elseif op == Op.DIVRK then
				return Arith.DivRK(A, K[B + 1], C + base, nextH, chain)
			elseif op == Op.CONCAT then
				return Arith.Concat(A, B + base, C + base, nextH, chain)
			elseif op == Op.NOT then
				return Arith.Not(A, B + base, nextH, chain)
			elseif op == Op.MINUS then
				return Arith.Minus(A, B + base, nextH, chain)
			elseif op == Op.LENGTH then
				return Arith.Length(A, B + base, nextH, chain)
			elseif op == Op.GETVARARGS then
				if B == 0 then
					return Values.GetVarargsAll(A, nextH, chain)
				end
				return Values.GetVarargs(A, B - 1, nextH, chain)
			elseif op == Op.NEWCLOSURE or op == Op.DUPCLOSURE then
				local child = if op == Op.NEWCLOSURE then proto.Children[D + 1] else proto.Closures[D + 1]
				local childCells = ctx.Cells[child]
				local kinds, sources = {}, {}
				local i = 1
				while OpOf[pc + Len[pc] + i - 1] == Op.CAPTURE do
					local at = pc + Len[pc] + i - 1
					local kind, source = OA[at], OB[at]
					if kind == 0 then
						kinds[i] = if childCells[i] then Closures.VALUE_BOXED else Closures.VALUE
						sources[i] = source + base
					elseif kind == 1 then
						kinds[i] = Closures.CELL
						sources[i] = source + base
					else
						kinds[i] = if childCells[i] and not cells[source + 1] then Closures.UPVALUE_BOXED else Closures.UPVALUE
						sources[i] = source + 1
					end
					i += 1
				end
				local make = ctx.Factories[child]
				assert(make, "child proto compiled out of order")
				if op == Op.NEWCLOSURE then
					return Closures.New(A, make, kinds, sources, nextH, chain, dyn)
				end
				return Closures.Dup(A, make, kinds, sources, nextH, chain, dyn)
			end

			return Unsupported(op)
		end

		local live = prog.Live
		for i = #live, 1, -1 do
			local pc = live[i]
			local h = Build(pc)
			local list = prog.Wrappers[pc]
			if list then
				for _, loop in list do
					h = Loops.Back(h, loop.Token, loop.Members)
				end
			end
			if ctx.Debug then
				h = Track(h, pc)
			end
			Top[pc] = h
		end

		for _, loop in prog.Loops do
			for _, pc in loop.MemberPcs do
				loop.Members[Top[pc]] = true
			end
		end

		local entry = Top[prog.Entry]
		if ctx.Debug then
			entry = Guard(entry, Where)
		end
		return entry, consts, prog.ConstCount
	end

	local Compiler = {}

	-- Compiles every proto of a chunk and returns the main function.
	-- @param chunk Chunk – deserialized bytecode
	-- @param env table – global environment for GETGLOBAL/SETGLOBAL/GETIMPORT
	-- @param safeEnv boolean – resolve imports once at load
	-- @param chunkName string? – prefix for guest error positions; nil leaves messages without one
	-- @param dyn EnvState? – DynamicEnv state (per-closure environments, getfenv/setfenv)
	-- @param debug boolean? – position host-raised errors at the guest line (slower)
	function Compiler.Compile(chunk: Chunk, env: any, safeEnv: boolean, chunkName: string?, dyn: EnvState?, debug: boolean?): (...any) -> ...any
		local protos = chunk.Protos
		local ctx: Context = {
			Cells = ResolveCells(chunk),
			Factories = {},
			Env = env,
			SafeEnv = safeEnv,
			ChunkName = chunkName,
			Dyn = dyn,
			Debug = debug == true,
			Classes = chunk.HasClasses,
		}

		-- children before parents, so closure makers can capture their child's factory directly
		local visited: { [number]: boolean } = {}
		local function Visit(index: number)
			if visited[index] then
				return
			end
			visited[index] = true
			local proto = protos[index]
			for _, child in proto.Children do
				Visit(child)
			end
			for _, child in proto.Closures do
				Visit(child)
			end
			local entry, consts, constCount = CompileProto(proto, index, ctx)
			ctx.Factories[index] = Runtime.Factory(entry, proto.MaxStack, proto.Params, proto.IsVararg, consts, constCount)
		end
		Visit(chunk.Main)

		if dyn then
			local U = { [Env.ENV] = env }
			local main = ctx.Factories[chunk.Main](U)
			U[Env.FN] = main
			dyn.Owners[main] = U
			return main
		end
		return ctx.Factories[chunk.Main]({})
	end

	-- interpreter frames are invisible to guest stack levels (getfenv/setfenv under DynamicEnv)
	for _, module in { Values, Arith, Tables, Calls, Branches, Loops, Closures, Fused, Runtime, Analysis, Compiler, Objects, Classes } do
		for _, member in module :: any do
			if type(member) == "function" then
				Env.MarkInternal(member)
				break
			end
		end
	end
	Env.MarkInternal(ResolveCells)
	Env.MarkInternal(Env.Reposition)
	Env.MarkGuarded(Run)

	return Compiler
end)()

-- Deserializer.luau
local Module_Deserializer = (function()
	-- Parses serialized Luau bytecode into plain proto records.
	-- Pure data transform: no execution and no environment access, so it is safe on untrusted input.

	local Runtime = Module_Runtime
	local Classes = Module_Classes

	local PresizedHash = Runtime.PresizedHash


	local readu8 = buffer.readu8
	local readu32 = buffer.readu32
	local readf32 = buffer.readf32
	local readf64 = buffer.readf64
	local readstring = buffer.readstring

	-- Constant kinds (LuauBytecodeConstantType)
	local K_NIL, K_BOOLEAN, K_NUMBER, K_STRING, K_IMPORT, K_TABLE, K_CLOSURE, K_VECTOR = 0, 1, 2, 3, 4, 5, 6, 7
	local K_TABLE_CONSTANTS, K_INTEGER, K_CLASS_SHAPE, K_VECTORD = 8, 9, 10, 11

	-- Builds a 64-bit integer constant from its 7-bit varint groups.
	-- Exists because integer values can only be made through the host integer library; wrapping arithmetic
	-- reproduces the two's complement bit pattern of the magnitude.
	-- @param groups { number } – 7-bit groups, least significant first
	-- @param negative boolean – sign flag stored next to the magnitude
	local function MakeInteger(groups: { number }, negative: boolean): any
		local lib = (_G :: any).integer
		assert(lib, "64-bit integer constants require the integer library")
		local radix = lib.create(128)
		local value = lib.create(0)
		for i = #groups, 1, -1 do
			value = lib.add(lib.mul(value, radix), lib.create(groups[i]))
		end
		return if negative then lib.neg(value) else value
	end

	-- Deserializes a bytecode blob into protos.
	-- @param input string | buffer – bytecode as produced by luau-compile or luau_compile
	-- @param vectorCtor (number, number, number, number) -> any – builds vector constants
	local function Deserialize(input: string | buffer, vectorCtor: (number, number, number, number) -> any): Chunk
		local stream = if type(input) == "string" then buffer.fromstring(input) else input :: buffer
		local size = buffer.len(stream)
		local cursor = 0

		local function u8(): number
			local v = readu8(stream, cursor)
			cursor += 1
			return v
		end

		local function u32(): number
			local v = readu32(stream, cursor)
			cursor += 4
			return v
		end

		local function f64(): number
			local v = readf64(stream, cursor)
			cursor += 8
			return v
		end

		local function f32(): number
			local v = readf32(stream, cursor)
			cursor += 4
			return v
		end

		local function varint(): number
			local result, scale = 0, 1
			repeat
				local b = u8()
				result += (b % 128) * scale
				scale *= 128
			until b < 128
			return result
		end

		local version = u8()
		if version == 0 then
			error(readstring(stream, 1, size - 1), 0)
		elseif (version < 3 or version > 14) and version ~= 100 then
			error(`unsupported bytecode version {version}`, 0)
		end
		local typesVersion = if version >= 4 then u8() else 0

		local strings: { string } = {}
		for i = 1, varint() do
			local len = varint()
			strings[i] = readstring(stream, cursor, len)
			cursor += len
		end

		-- userdata type names only feed the host's type remapping
		if typesVersion == 3 then
			while u8() ~= 0 do
				varint()
			end
		end

		local hasClasses = false

		local protoCount = varint()
		local protos: { Proto } = table.create(protoCount)

		for index = 1, protoCount do
			local protoSize = if version >= 12 then varint() else 0
			local protoStart = cursor

			local maxStack, params, upvalues = u8(), u8(), u8()
			local isVararg = u8() ~= 0
			local flags = 0
			if version >= 4 then
				flags = u8()
				cursor += varint() -- type info
			end

			local codeSize = varint()
			local code = table.create(codeSize)
			for i = 1, codeSize do
				code[i] = u32()
			end

			local constCount = varint()
			local constants: { any } = table.create(constCount)
			local imports: { [number]: number } = {}
			local closures: { [number]: number } = {}
			local templates: { [number]: { number } } = {}

			for k = 1, constCount do
				local kind = u8()
				if kind == K_NIL then
					-- stays nil
				elseif kind == K_BOOLEAN then
					constants[k] = u8() ~= 0
				elseif kind == K_NUMBER then
					constants[k] = f64()
				elseif kind == K_STRING then
					constants[k] = strings[varint()]
				elseif kind == K_IMPORT then
					imports[k] = u32()
				elseif kind == K_TABLE or kind == K_TABLE_CONSTANTS then
					local fields = {}
					for i = 1, varint() do
						fields[i * 2 - 1] = varint()
						if kind == K_TABLE then
							fields[i * 2] = -1
						else
							local ki = u32()
							fields[i * 2] = if ki >= 0x80000000 then ki - 0x100000000 else ki
						end
					end
					templates[k] = fields
				elseif kind == K_CLOSURE then
					closures[k] = varint() + 1
				elseif kind == K_VECTOR then
					local x, y, z, w = f32(), f32(), f32(), f32()
					constants[k] = vectorCtor(x, y, z, w)
				elseif kind == K_VECTORD then
					local x, y, z, w = f64(), f64(), f64(), f64()
					constants[k] = vectorCtor(x, y, z, w)
				elseif kind == K_INTEGER then
					local negative = u8() ~= 0
					local groups = {}
					repeat
						local b = u8()
						table.insert(groups, b % 128)
					until b < 128
					constants[k] = MakeInteger(groups, negative)
				elseif kind == K_CLASS_SHAPE then
					-- the class is created once per load, as the host loader does; NEWCLASS hands out this value
					local name = constants[varint() + 1]
					local privateFields, privateMethods = u8(), u8()
					local properties, methods = varint(), varint()
					local fields, names = {}, {}
					for i = 1, properties - privateFields do
						fields[i] = constants[varint() + 1]
					end
					for i = 1, methods - privateMethods do
						names[i] = constants[varint() + 1]
					end
					constants[k] = Classes.FromShape(name, fields, names, privateFields, privateMethods)
					hasClasses = true
				else
					error(`unknown constant kind {kind}`, 0)
				end
			end

			-- templates reference other constants by index, so they are built once every constant is known
			for k, fields in templates do
				local template = PresizedHash(#fields // 2)
				local nilKeys = {}
				for i = 1, #fields, 2 do
					local key = constants[fields[i] + 1]
					local vi = fields[i + 1]
					local value = if vi >= 0 then constants[vi + 1] else nil
					-- placeholder 0 mirrors the host loader: every field gets its node in order, nil constants last
					template[key] = if value == nil then 0 else value
					if vi >= 0 and value == nil then
						table.insert(nilKeys, key)
					end
				end
				for _, key in nilKeys do
					template[key] = nil
				end
				constants[k] = template
			end

			local children = {}
			for i = 1, varint() do
				children[i] = varint() + 1
			end

			varint() -- line defined
			local debugName = strings[varint()]

			-- line info: per-instruction byte deltas on top of absolute lines sampled every 2^gapLog2 instructions
			local lines: { number }? = nil
			if u8() ~= 0 then
				local gapLog2 = u8()
				local intervals = (codeSize - 1) // 2 ^ gapLog2 + 1
				local offsets = table.create(codeSize)
				local last = 0
				for i = 1, codeSize do
					last = (last + u8()) % 256
					offsets[i] = last
				end
				local absolute = table.create(intervals)
				local line = 0
				for i = 1, intervals do
					line += buffer.readi32(stream, cursor)
					cursor += 4
					absolute[i] = line
				end
				lines = offsets
				for i = 1, codeSize do
					offsets[i] = absolute[(i - 1) // 2 ^ gapLog2 + 1] + offsets[i]
				end
			end

			if u8() ~= 0 then -- debug info
				for _ = 1, varint() do
					varint()
					varint()
					varint()
					u8()
				end
				for _ = 1, varint() do
					varint()
				end
			end

			-- feedback slots: call targets (unused here) and CONSTRUCT shapes (constant index of the table template)
			local shapes: { [number]: number } = {}
			if version >= 11 then
				for slot = 0, varint() - 1 do
					local kind = u8()
					local value = varint()
					if kind == 1 then
						shapes[slot] = value + 1
					end
				end
			end

			if version >= 12 then
				cursor = protoStart + protoSize
			end

			protos[index] = {
				MaxStack = maxStack,
				Params = params,
				Upvalues = upvalues,
				IsVararg = isVararg,
				Flags = flags,
				Code = code,
				Constants = constants,
				Imports = imports,
				Closures = closures,
				Children = children,
				Name = debugName,
				Lines = lines,
				Shapes = shapes,
			}
		end

		local main = varint() + 1
		if cursor ~= size then
			error("malformed bytecode: trailing data", 0)
		end

		return { Protos = protos, Main = main, HasClasses = hasClasses }
	end

	return Deserialize
end)()

-- init.luau
local Module_init = (function()
	-- Luau bytecode interpreter written in Luau.
	--
	-- Usage:
	--     local Interpreter = require(path.to.Interpreter)
	--     local main = Interpreter.Load(bytecode, getfenv(), { SafeEnv = true })
	--     main(...)
	--
	-- Bytecode is compiled once into closure graphs (see Compiler); running it involves no opcode dispatch.

	local Deserialize = Module_Deserializer
	local Compiler = Module_Compiler
	local Env = Module_Env


	local Interpreter = {}

	-- Default vector constant constructor: the vector library when present, Vector3 on older Roblox runtimes.
	local function DefaultVector(x: number, y: number, z: number, w: number): any
		local lib = (_G :: any).vector
		if lib and lib.create then
			return lib.create(x, y, z)
		end
		local Vector3 = (_G :: any).Vector3
		if Vector3 then
			return Vector3.new(x, y, z)
		end
		error("vector constants need the vector library or Vector3", 0)
	end

	-- Loads bytecode and returns its main function.
	-- @param bytecode string | buffer – serialized Luau bytecode (luau-compile --binary / luau_compile)
	-- @param env table? – globals for the chunk; defaults to the caller-independent shared _G
	-- @param options Options? – vector constructor and import resolution policy
	function Interpreter.Load(bytecode: string | buffer, env: { [any]: any }?, options: Options?): (...any) -> ...any
		local opts: Options = options or {}
		local chunk = Deserialize(bytecode, opts.Vector or DefaultVector)
		local globals = env or _G
		local dyn: EnvState? = nil
		if opts.DynamicEnv == true then
			dyn = Env.New()
		elseif opts.DynamicEnv then
			dyn = opts.DynamicEnv :: any
		end
		return Compiler.Compile(chunk, globals, opts.SafeEnv ~= false, opts.ChunkName, dyn, opts.Debug)
	end

	-- Creates a DynamicEnv state to share between chunks, so getfenv/setfenv see each other's closures.
	Interpreter.NewEnvState = Env.New

	-- Exposes the parser for tooling (disassemblers, analyzers) without running anything.
	Interpreter.Deserialize = Deserialize

	return Interpreter
end)()

return Module_init
