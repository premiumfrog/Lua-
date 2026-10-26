-- Runs one embedded conformance test natively and on the interpreter; prints PASS, FAIL or SKIP.
-- A test that fails natively (it needs CLI features such as a writable global table) is skipped.
--
-- Usage: luau tools/conformance.luau -a <embedded-dir> <name>

local Interpreter = require("../src")

local dir, name = ...
local w = (require :: any)("../" .. dir .. "/" .. name)

local native = loadstring(w.Source, name)
local okN, rN = pcall(native :: any)
if not okN or rN ~= "OK" then
	print("SKIP", name, (tostring(rN):gsub("\n", " ")):sub(1, 120))
	return
end

local okL, f = pcall(Interpreter.Load, w.Bytecode, getfenv(native :: any), { ChunkName = `[string "{name}"]` })
if not okL then
	print("FAIL", name, "load: " .. tostring(f):sub(1, 200))
	return
end
local okV, rV = pcall(f)
if okV and rV == "OK" then
	print("PASS", name)
else
	print("FAIL", name, (tostring(rV):gsub("\n", " ")):sub(1, 200))
end
