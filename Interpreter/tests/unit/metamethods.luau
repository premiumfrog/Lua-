-- Metamethods implemented by interpreted functions and host callbacks into interpreted code.

local log = {}
local V = {}
V.__index = V
V.__add = function(a, b)
	return setmetatable({ x = a.x + b.x }, V)
end
V.__sub = function(a, b)
	return setmetatable({ x = a.x - b.x }, V)
end
V.__mul = function(a, b)
	if type(b) == "number" then
		return setmetatable({ x = a.x * b }, V)
	end
	return setmetatable({ x = a * b.x }, V)
end
V.__unm = function(a)
	return setmetatable({ x = -a.x }, V)
end
V.__eq = function(a, b)
	return a.x == b.x
end
V.__lt = function(a, b)
	return a.x < b.x
end
V.__le = function(a, b)
	return a.x <= b.x
end
V.__len = function(a)
	return a.x
end
V.__concat = function(a, b)
	local l = if type(a) == "table" then a.x else a
	local r = if type(b) == "table" then b.x else b
	return l .. ":" .. r
end
V.__call = function(self, y)
	return self.x + y
end
V.__tostring = function(self)
	return "V(" .. self.x .. ")"
end
V.__idiv = function(a, b)
	return setmetatable({ x = a.x // b }, V)
end
V.__mod = function(a, b)
	return setmetatable({ x = a.x % b }, V)
end
V.__pow = function(a, b)
	return setmetatable({ x = a.x ^ b }, V)
end
V.__div = function(a, b)
	return setmetatable({ x = a.x / b }, V)
end

local function new(x)
	return setmetatable({ x = x }, V)
end

local a, b = new(3), new(4)
assert((a + b).x == 7)
assert((a - b).x == -1)
assert((a * 2).x == 6)
assert((2 * a).x == 6)
assert((-a).x == -3)
assert(a == new(3) and a ~= b)
assert(a < b and a <= b and b > a and b >= a)
assert(#a == 3)
assert(a .. b == "3:4" and a .. "s" == "3:s" and 1 .. a == "1:3")
assert(a .. "x" .. b == "3:x:4")
assert(a(10) == 13)
assert(tostring(a) == "V(3)")
assert((b // 3).x == 1 and (b % 3).x == 1 and (b ^ 2).x == 16 and (b / 2).x == 2)

-- __index / __newindex functions and chains
local proxy = setmetatable({}, {
	__index = function(_, k)
		table.insert(log, "get " .. k)
		return k .. "!"
	end,
	__newindex = function(t, k, v)
		table.insert(log, "set " .. k)
		rawset(t, k, v * 2)
	end,
})
assert(proxy.foo == "foo!")
proxy.bar = 21
assert(proxy.bar == 42)
assert(log[1] == "get foo" and log[2] == "set bar" and #log == 2)

local base = { greet = function(self)
	return "hi " .. self.name
end }
local mid = setmetatable({}, { __index = base })
local obj = setmetatable({ name = "x" }, { __index = mid })
assert(obj:greet() == "hi x")

-- __iter drives generic for loops
local iterable = setmetatable({}, {
	__iter = function()
		local i = 0
		return function()
			i += 1
			if i <= 3 then
				return i, i * i
			end
		end
	end,
})
local sum = 0
for k, v in iterable do
	sum += k + v
end
assert(sum == 1 + 1 + 2 + 4 + 3 + 9)

-- host functions calling interpreted callbacks
local words = { "pear", "fig", "banana" }
table.sort(words, function(x, y)
	return #x < #y
end)
assert(words[1] == "fig" and words[3] == "banana")
assert((string.gsub("abc", "%w", function(c)
	return c:upper()
end)) == "ABC")
local seen = 0
for _ in string.gmatch("a b c", "%a") do
	seen += 1
end
assert(seen == 3)
assert(select("#", xpcall(function()
	error("x")
end, function(m)
	return "handled", m
end)) == 2)

-- __namecall-free method calls on strings
local s = "Hello"
assert(s:lower() == "hello" and s:rep(2) == "HelloHello" and ("x"):byte() == 120)

-- __metatable protection
local locked = setmetatable({}, { __metatable = "locked" })
assert(getmetatable(locked) == "locked")
assert(not pcall(setmetatable, locked, {}))

return "OK"
