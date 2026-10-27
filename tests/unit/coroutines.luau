-- Coroutines through interpreted frames: yields from nested calls, wrap, status, errors and pcall inside threads.

local function producer(n)
	for i = 1, n do
		coroutine.yield(i)
	end
	return "done"
end

local co = coroutine.create(producer)
for i = 1, 3 do
	local ok, v = coroutine.resume(co, 3)
	assert(ok and v == i)
	assert(coroutine.status(co) == "suspended")
end
local ok, v = coroutine.resume(co)
assert(ok and v == "done" and coroutine.status(co) == "dead")
assert(not coroutine.resume(co))

-- yield from deep inside interpreted calls, values flow both ways
local function deep(depth)
	if depth == 0 then
		return coroutine.yield("bottom") * 2
	end
	return deep(depth - 1) + 1
end
local gen = coroutine.wrap(function()
	return deep(10)
end)
assert(gen() == "bottom")
assert(gen(5) == 20)

-- yield across pcall and inside generic loops
local inner = coroutine.wrap(function()
	local ok2, r = pcall(function()
		for _, x in ipairs({ 10, 20 }) do
			coroutine.yield(x)
		end
		error("after")
	end)
	return ok2, r
end)
assert(inner() == 10)
assert(inner() == 20)
local ok3, r3 = inner()
assert(ok3 == false and string.find(r3, "after", 1, true))

-- running/isyieldable
local self
self = coroutine.create(function()
	assert(coroutine.running() == self)
	assert(coroutine.isyieldable())
	return coroutine.status(self)
end)
local ok4, status = coroutine.resume(self)
assert(ok4 and status == "running")

-- errors close the coroutine and carry their value
local failing = coroutine.create(function()
	error({ code = 7 })
end)
local ok5, e = coroutine.resume(failing)
assert(not ok5 and type(e) == "table" and e.code == 7)
assert(coroutine.status(failing) == "dead")

-- close
local closable = coroutine.create(function()
	coroutine.yield()
end)
coroutine.resume(closable)
assert(coroutine.close(closable))
assert(coroutine.status(closable) == "dead")

-- interpreted functions as host callbacks while suspended threads exist
local values = {}
local lazy = coroutine.wrap(function()
	table.sort(values, function(a, b)
		return a > b
	end)
	coroutine.yield(values[1])
end)
for i = 1, 20 do
	values[i] = i
end
assert(lazy() == 20)

return "OK"
