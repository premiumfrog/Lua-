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

local Types = require("@self/Types")
local Deserialize = require("@self/Deserializer")
local Compiler = require("@self/Compiler")
local Env = require("@self/Env")

export type Options = Types.Options
export type EnvState = Env.State

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

-- Whether any function of a chunk names getfenv or setfenv (as a global, an import or a field).
-- Why: DynamicEnv turns itself on for such chunks, as the host deoptimizes environments for them.
local function UsesFenv(chunk: Types.Chunk): boolean
	for _, proto in chunk.Protos do
		for _, k in proto.Constants do
			if k == "getfenv" or k == "setfenv" then
				return true
			end
		end
	end
	return false
end

-- Loads bytecode and returns its main function.
-- @param bytecode string | buffer – serialized Luau bytecode (luau-compile --binary / luau_compile)
-- @param env table? – globals for the chunk; defaults to the caller-independent shared _G
-- @param options Options? – vector constructor and import resolution policy
function Interpreter.Load(bytecode: string | buffer, env: { [any]: any }?, options: Options?): (...any) -> ...any
	local opts: Options = options or {}
	local chunk = Deserialize(bytecode, opts.Vector or DefaultVector)
	local globals = env or _G
	local dyn: Env.State? = nil
	if opts.DynamicEnv == true or (opts.DynamicEnv == nil and UsesFenv(chunk)) then
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
