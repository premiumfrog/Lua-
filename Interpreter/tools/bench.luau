--!optimize 2

-- Benchmark driver: runs embedded workloads natively, on this interpreter and optionally on another VM module.
--
-- Usage (from Interpreter/):
--     python3 tools/embed.py <luau-compile> build/bench 2 bench/workloads/*.luau
--     luau -O2 tools/bench.luau -a build/bench <name>... [--ref path/to/OtherVM]
-- The other VM must expose Load(bytecode, env) like this one. Times are the best of RUNS runs.

local Interpreter = require("../src")

local RUNS = 7

local args = { ... }
local dir = table.remove(args, 1)
local refPath: string? = nil
local names = {}
local i = 1
while i <= #args do
	if args[i] == "--ref" then
		refPath = args[i + 1]
		i += 2
	else
		table.insert(names, args[i])
		i += 1
	end
end
local Ref = if refPath then (require :: any)("../" .. refPath) else nil

-- Best wall time of n runs and the last result.
local function Best(f: () -> any, n: number): (number, any)
	local best, result = math.huge, nil
	for _ = 1, n do
		local t = os.clock()
		result = f()
		best = math.min(best, os.clock() - t)
	end
	return best, result
end

for _, name in names do
	local w = (require :: any)("../" .. dir .. "/" .. name)
	local env = setmetatable({}, { __index = _G })
	local tn, rn = Best(loadstring(w.Source) :: any, RUNS)
	local tm, rm = Best(Interpreter.Load(w.Bytecode, env), RUNS)
	local line = string.format("%-14s native %8.2fms  vm %8.2fms (%5.1fx)", name, tn * 1000, tm * 1000, tm / tn)
	if Ref then
		local tr, rr = Best(Ref.Load(w.Bytecode, env), RUNS)
		line ..= string.format("  ref %8.2fms (%5.1fx)  speedup %4.2fx", tr * 1000, tr / tn, tr / tm)
		if rr ~= rn then
			line ..= "  REF MISMATCH"
		end
	end
	if rm ~= rn then
		line ..= `  MISMATCH {rn} {rm}`
	end
	print(line)
end
