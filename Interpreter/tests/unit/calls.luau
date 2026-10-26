-- Calls, returns and varargs across every arity the handlers specialize.

local function id(...)
	return ...
end
local function count(...)
	return select("#", ...)
end
assert(count() == 0 and count(nil) == 1 and count(nil, nil) == 2)
assert(count(id(1, nil, 3, nil)) == 4)
assert(select(-1, 1, 2, 3) == 3)
assert(select(2, "a", "b", "c") == "b")
local packed = table.pack(id(1, 2, 3, 4, 5, 6, 7, 8))
assert(packed.n == 8 and packed[8] == 8)

-- results truncated and padded
local a, b, c = id(1)
assert(a == 1 and b == nil and c == nil)
local x = (id(1, 2, 3))
assert(x == 1)
local t = { id(1, 2), id(3, 4) }
assert(#t == 3 and t[2] == 3 and t[3] == 4)

-- many arguments and results
local args = {}
for i = 1, 300 do
	args[i] = i
end
assert(count(table.unpack(args)) == 300)
local last = select(300, table.unpack(args))
assert(last == 300)
local function sum(...)
	local s = 0
	for i = 1, select("#", ...) do
		s += (select(i, ...))
	end
	return s
end
assert(sum(table.unpack(args)) == 45150)

-- fixed arities with extra and missing arguments
local function three(p, q, r)
	return p, q, r
end
local p, q, r = three(1)
assert(p == 1 and q == nil and r == nil)
p, q, r = three(1, 2, 3, 4)
assert(r == 3)
local function four(p1, p2, p3, p4)
	return p4
end
assert(four(1, 2, 3, 4) == 4 and four(1, 2, 3) == nil)

-- vararg functions with fixed parameters
local function head(first, ...)
	return first, select("#", ...)
end
local h, rest = head(1, 2, 3)
assert(h == 1 and rest == 2)

-- recursion and mutual recursion reuse frames safely
local function fib(n)
	if n < 2 then
		return n
	end
	return fib(n - 1) + fib(n - 2)
end
assert(fib(20) == 6765)
local isEven, isOdd
function isEven(n)
	if n == 0 then
		return true
	end
	return isOdd(n - 1)
end
function isOdd(n)
	if n == 0 then
		return false
	end
	return isEven(n - 1)
end
assert(isEven(1000) and not isOdd(1000))

-- reentrancy: a function called while its own frame is live
local function outer(depth, f)
	if depth == 0 then
		return f()
	end
	local before = depth
	local result = outer(depth - 1, f)
	assert(before == depth)
	return result + depth
end
assert(outer(5, function()
	return outer(3, function()
		return 0
	end)
end) == 6 + 15)

-- methods through tables, strings and namecall on nil errors
local obj = { v = 2 }
function obj:double(k)
	return self.v * (k or 2)
end
assert(obj:double() == 4 and obj:double(5) == 10 and obj.double(obj, 3) == 6)
assert(not pcall(function()
	local missing = nil
	missing:method()
end))
assert(not pcall(function()
	obj:nope()
end))

-- tail calls return every result
local function tail(...)
	return id(...)
end
assert(count(tail(1, 2, 3)) == 3)

-- pcall/xpcall return shapes
assert(select("#", pcall(id)) == 1)
assert(select("#", pcall(id, 1, 2)) == 3)
local ok, err = pcall(error)
assert(not ok and err == nil)
local okx, ex = xpcall(function()
	error("e", 0)
end, function(m)
	return "handled " .. m
end)
assert(not okx and ex == "handled e")

-- upvalues: shared cells between closures, closing after loops and returns
local function counter()
	local n = 0
	return function()
		n += 1
		return n
	end, function()
		return n
	end
end
local inc, get = counter()
inc()
inc()
assert(get() == 2)

return "OK"
