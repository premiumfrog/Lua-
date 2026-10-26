-- interpreter: unsafe-env
-- Globals and imports when the environment changes after loading (SafeEnv off).

local G = getfenv()
assert(_G == G)

counter = 0
local function bump()
	counter += 1
	return counter
end
assert(bump() == 1 and counter == 1)

-- a replaced library function is seen by already-loaded code
local saved = math.max
math = setmetatable({ max = function()
	return "patched"
end }, { __index = saved and G.math or nil })
assert(math.max(1, 2) == "patched")
math = nil
math = getmetatable(G) and getmetatable(G).__index.math
assert(math.max(1, 2) == 2)

-- globals created at runtime, rawget/rawset on the environment
rawset(G, "dynamic", 5)
assert(dynamic == 5)
dynamic = nil
assert(rawget(G, "dynamic") == nil)

-- function declarations store globals, local functions do not
function declared()
	return "declared"
end
assert(rawget(G, "declared") ~= nil and declared() == "declared")
local function hidden() end
assert(rawget(G, "hidden") == nil)

-- missing globals read as nil, calling them errors
assert(undefined_global == nil)
assert(not pcall(function()
	undefined_global()
end))

-- string library through the string metatable and as a global
local s = "abc"
assert(s:upper() == "ABC" and string.upper(s) == "ABC")

-- loadstring produces functions in the same globals
local f = loadstring("shared = (shared or 0) + 1 return shared")
assert(f() == 1 and shared == 1)

return "OK"
