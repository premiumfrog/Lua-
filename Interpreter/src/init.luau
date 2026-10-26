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

export type Options = Types.Options

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
	return Compiler.Compile(chunk, env or _G, opts.SafeEnv ~= false, opts.ChunkName)
end

-- Exposes the parser for tooling (disassemblers, analyzers) without running anything.
Interpreter.Deserialize = Deserialize

return Interpreter
