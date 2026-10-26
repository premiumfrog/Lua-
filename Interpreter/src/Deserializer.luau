--!optimize 2
--!strict

-- Parses serialized Luau bytecode into plain proto records.
-- Pure data transform: no execution and no environment access, so it is safe on untrusted input.

local Types = require("./Types")
local Runtime = require("./Runtime")

local PresizedHash = Runtime.PresizedHash

type Proto = Types.Proto
type Chunk = Types.Chunk

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
	elseif version < 3 or version > 14 then
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
				error("class bytecode is not supported", 0)
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

		if version >= 11 then -- feedback slots
			for _ = 1, varint() do
				u8()
				varint()
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
		}
	end

	local main = varint() + 1
	if cursor ~= size then
		error("malformed bytecode: trailing data", 0)
	end

	return { Protos = protos, Main = main }
end

return Deserialize
