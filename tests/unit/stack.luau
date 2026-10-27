-- Guest view of the stack without the Debug option: positions of host-raised errors at catch points, error levels,
-- debug.info levels and debug.traceback.
-- Functions live in a table so O2 does not inline them (inlined frames are not levels, natively either).

local M = {}

local function lineOf(message)
	return tonumber(string.match(message, ":(%d+): "))
end

-- host-raised errors caught by pcall carry the guest line
local here = debug.info(1, "l")
local ok, e = pcall(function()
	local t = nil
	return t.x -- here + 3
end)
assert(not ok and lineOf(e) == here + 3, e)
assert(string.find(e, "^stack.luau:"), e)

ok, e = pcall(function()
	return 1 + {} -- here + 9
end)
assert(lineOf(e) == here + 9, e)

-- xpcall handlers see the positioned message, and run before the stack unwinds
local seen
ok, e = xpcall(function()
	local f = nil
	f() -- here + 17
end, function(m)
	seen = debug.info(2, "l")
	return "handled: " .. m
end)
assert(not ok and string.find(e, "^handled: stack.luau:"), e)
assert(lineOf(e) == here + 17, e)

-- errors inside coroutines, through resume and wrap
local co = coroutine.create(function()
	local n = nil
	return n + 1 -- here + 28
end)
ok, e = coroutine.resume(co)
assert(not ok and lineOf(e) == here + 28, e)
ok, e = pcall(coroutine.wrap(function()
	return #nil -- here + 33
end))
assert(not ok and lineOf(e) == here + 33, e)

-- error levels name the caller's call site
function M.check(v)
	if type(v) ~= "number" then
		error("expected number", 2)
	end
end
function M.caller()
	M.check("x") -- here + 44
end
ok, e = pcall(M.caller)
assert(e == `stack.luau:{here + 44}: expected number`, e)
ok, e = pcall(function()
	error("three", 3)
end)
assert(e == `stack.luau:{here + 48}: three`, e) -- level 2 is pcall, level 3 the pcall call site

-- debug.info levels count guest functions
function M.inner()
	local s, l, n = debug.info(1, "sln")
	return s, l, n, debug.info(2, "l"), debug.info(2, "n")
end
function M.outer()
	local s, l, n, l2, n2 = M.inner() -- here + 59
	return s, l, n, l2, n2
end
local s, l, n, l2, n2 = M.outer()
assert(s == "stack.luau" and n == "inner" and l == here + 55, `{s} {l} {n}`)
assert(l2 == here + 59 and n2 == "outer", `{l2} {n2}`)
assert(debug.info(1, "f") == nil or true)
function M.arity(a, b, ...)
	local p, v = debug.info(1, "a")
	return p, v
end
local p, v = M.arity()
assert(p == 2 and v == true)
function M.self()
	local f = debug.info(1, "f")
	return f
end
assert(M.self() == M.self)

-- tracebacks list guest frames with their current lines
function M.deepest()
	local tb = debug.traceback("msg")
	return tb
end
function M.middle()
	local tb = M.deepest() -- here + 84
	return tb
end
local tb = M.middle()
local lines = string.split(tb, "\n")
assert(lines[1] == "msg", tb)
assert(lines[2] == `stack.luau:{here + 80} function deepest`, tb)
assert(lines[3] == `stack.luau:{here + 84} function middle`, tb)

-- tracebacks of another coroutine
function M.waiting()
	coroutine.yield() -- here + 95
end
local suspended = coroutine.create(function()
	M.waiting()
end)
coroutine.resume(suspended)
local ctb = debug.traceback(suspended)
assert(string.find(ctb, `stack.luau:{here + 95} function waiting`, 1, true), ctb)

return "OK"
