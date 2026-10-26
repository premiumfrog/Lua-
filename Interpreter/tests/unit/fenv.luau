-- getfenv/setfenv on interpreted functions (DynamicEnv): levels, function targets, inheritance and imports.

local G = getfenv()
assert(getfenv(0) == G)
assert(getfenv(1) == G)
assert(getfenv(G.print) ~= nil)

-- function targets: setfenv returns the function and retargets its globals
local function reader()
	return value
end
value = "global"
assert(reader() == "global")
local custom = { value = "custom" }
assert(setfenv(reader, custom) == reader)
assert(reader() == "custom")
assert(getfenv(reader) == custom)

-- closures inherit the environment of the function that created them
local function maker()
	return function()
		return value
	end
end
setfenv(maker, { value = "inherited" })
assert(maker()() == "inherited")

-- level 1 is the caller of getfenv, level 2 its caller
local function level2()
	return getfenv(2)
end
local function level1()
	return level2()
end
local marked = setmetatable({ getfenv = getfenv }, { __index = G })
setfenv(level1, marked)
assert(level1() == marked)

-- setfenv(1, t) changes the running function's globals
local function swap()
	local saved = getfenv()
	setfenv(1, setmetatable({}, { __index = saved }))
	swapped = true
	return rawget(saved, "swapped")
end
assert(swap() == nil)
assert(rawget(G, "swapped") == nil)

-- imports re-resolve once an environment has been exposed
local function floor(x)
	return math.floor(x)
end
assert(floor(1.5) == 1)
setfenv(floor, { math = { floor = function()
	return "replaced"
end } })
assert(floor(1.5) == "replaced")

-- errors match the host
local okLevel, levelErr = pcall(getfenv, -1)
assert(not okLevel and levelErr == "invalid argument #1 to 'getfenv' (level must be non-negative)")
assert(getfenv(math.floor) == getfenv(0))
assert(not pcall(getfenv, 1000))
assert(not pcall(setfenv, 1000, {}))
assert(not pcall(setfenv, reader, nil))
assert(not pcall(setfenv, math.floor, {}))
local ok, err = pcall(setfenv, setfenv, {})
assert(not ok and string.find(err, "cannot change environment", 1, true))

-- field reads of getfenv see the same function
assert(G.getfenv(1) == G)

return "OK"
