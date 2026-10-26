--!optimize 2
--!strict

-- Turns deserialized protos into handler graphs.
--
-- Every live instruction becomes one handler closure with its operands captured as upvalues. Analysis decides the
-- control-flow plan and which loads fold into calls; this module maps each instruction to its handler maker.
-- Handlers are built back to front so forward successors already exist; edges to a loop's continue point return
-- the loop's token, so no handler needs patching after creation.

local Types = require("./Types")
local Runtime = require("./Runtime")
local Analysis = require("./Analysis")
local Values = require("./Ops/Values")
local Arith = require("./Ops/Arith")
local Tables = require("./Ops/Tables")
local Calls = require("./Ops/Calls")
local Branches = require("./Ops/Branches")
local Loops = require("./Ops/Loops")
local Closures = require("./Ops/Closures")
local Env = require("./Env")
local Fused = require("./Ops/Fused")

type Proto = Types.Proto
type Chunk = Types.Chunk
type Handler = Types.Handler
type Frame = Types.Frame
type Factory = Types.Factory
type Edge = Analysis.Edge

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
	Dyn: Env.State?, -- DynamicEnv state; nil binds globals to Env at load
	Debug: boolean, -- track the running pc so host-raised errors carry guest positions
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
	local prog = Analysis.Analyze(proto, cells, env, ctx.SafeEnv and dyn == nil, ctx.Debug)

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
		elseif op == Op.GETGLOBAL and dyn then
			return Values.GetGlobalDyn(A, Env.ENV, K[Aux[pc] + 1], Swaps(pc), nextH, chain)
		elseif op == Op.GETGLOBAL then
			local site = prog.Positioned[pc]
			local where = if site then Where(site) else ""
			if where ~= "" then
				-- the global may be replaced at any time, so the swap for a positioned wrapper happens per read
				return Values.GetGlobalSwapped(A, env, K[Aux[pc] + 1], { [error] = GuestError(where), [assert] = GuestAssert(where) }, nextH, chain)
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
				local site = prog.Positioned[pc]
				local where = if site then Where(site) else ""
				if where ~= "" and (rawequal(value, error) or rawequal(value, assert)) then
					value = if rawequal(value, error) then GuestError(where) else GuestAssert(where)
				end
				if value ~= nil then
					return Values.LoadK(A, value, nextH, chain)
				end
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
-- @param dyn Env.State? – DynamicEnv state (per-closure environments, getfenv/setfenv)
-- @param debug boolean? – position host-raised errors at the guest line (slower)
function Compiler.Compile(chunk: Chunk, env: any, safeEnv: boolean, chunkName: string?, dyn: Env.State?, debug: boolean?): (...any) -> ...any
	local protos = chunk.Protos
	local ctx: Context = {
		Cells = ResolveCells(chunk),
		Factories = {},
		Env = env,
		SafeEnv = safeEnv,
		ChunkName = chunkName,
		Dyn = dyn,
		Debug = debug == true,
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
for _, module in { Values, Arith, Tables, Calls, Branches, Loops, Closures, Fused, Runtime, Analysis, Compiler } do
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
