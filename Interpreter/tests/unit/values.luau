-- Arithmetic, strings, tables and constants: the instructions most often folded or fused.

-- numeric edge cases
assert(7 // 2 == 3 and -7 // 2 == -4 and 7 % -3 == -2 and -7 % 3 == 2)
assert(2 ^ 10 == 1024 and 10 / 4 == 2.5)
assert(1 / 0 == math.huge and -1 / 0 == -math.huge)
local nan = 0 / 0
assert(nan ~= nan)
assert(math.floor(-0.5) == -1 and math.ceil(-0.5) == 0)
assert(3 - -3 == 6 and -(-3) == 3)
assert("10" + 5 == 15 and "3" * "4" == 12)
assert(not pcall(function()
	return {} + 1
end))
local k = 5
assert(k + 1 == 6 and k - 1 == 4 and k * 2 == 10 and k / 2 == 2.5 and k % 3 == 2 and k // 2 == 2 and k ^ 2 == 25)
assert(1 - k == -4 and 10 / k == 2)

-- bit32 and math builtins usually compiled to fastcalls
assert(bit32.band(0xF0, 0x3C) == 0x30 and bit32.bor(1, 2) == 3 and bit32.bxor(3, 1) == 2)
assert(bit32.lshift(1, 4) == 16 and bit32.rshift(16, 4) == 1 and bit32.arshift(-16, 2) == bit32.arshift(-16, 2))
assert(math.max(1, 5, 3) == 5 and math.min(4, 2) == 2 and math.abs(-3) == 3)
assert(math.clamp(5, 1, 3) == 3 and math.sign(-2) == -1)
assert(select("#", math.modf(3.5)) == 2)

-- strings
local s = "hello"
assert(#s == 5 and s .. " world" == "hello world")
assert(s:sub(2, 3) == "el" and s:find("l") == 3 and s:byte(1) == 104)
assert(string.format("%d-%s-%.2f", 1, "x", 1.5) == "1-x-1.50")
assert(`{s}!{1 + 1}` == "hello!2")
assert(tostring(12) == "12" and tonumber("0x10") == 16 and tonumber("z", 36) == 35)
assert(("x"):rep(3) == "xxx")
local parts = {}
for w in ("a,b,,c"):gmatch("([^,]*)") do
	table.insert(parts, w)
end
assert(#parts >= 4)

-- tables: constructors, array/hash parts, length, insert/remove, sort, concat
local arr = { 1, 2, 3, [5] = 5, x = "x", ["y z"] = 1 }
assert(arr[5] == 5 and arr.x == "x" and arr["y z"] == 1)
local big = {}
for i = 1, 100 do
	big[i] = i
end
assert(#big == 100)
table.insert(big, 1, 0)
assert(big[1] == 0 and #big == 101)
assert(table.remove(big) == 100 and #big == 100)
table.sort(big, function(a, b)
	return a > b
end)
assert(big[1] == 99)
assert(table.concat({ 1, 2, 3 }, "+") == "1+2+3")
assert(table.find({ "a", "b" }, "b") == 2)
local cloned = table.clone({ a = 1 })
assert(cloned.a == 1)
local frozen = table.freeze({ 1 })
assert(table.isfrozen(frozen) and not pcall(function()
	frozen[1] = 2
end))
local created = table.create(3, "v")
assert(#created == 3 and created[3] == "v")
local moved = table.move({ 1, 2, 3 }, 1, 3, 2, {})
assert(moved[1] == nil and moved[4] == 3)

-- nested constructors and templates reused across calls must not share state
local function make()
	return { list = {}, count = 0 }
end
local m1, m2 = make(), make()
m1.count = 5
table.insert(m1.list, 1)
assert(m2.count == 0 and #m2.list == 0)

-- traversal order of a constructed table matches the host
local order = {}
for key in pairs({ a = 1, b = 2, c = 3, d = 4 }) do
	table.insert(order, key)
end
local expected = {}
for key in pairs(loadstring("return { a = 1, b = 2, c = 3, d = 4 }")()) do
	table.insert(expected, key)
end
assert(table.concat(order) == table.concat(expected))

-- booleans and nil constants
local f, t, n = false, true, nil
assert(f == false and t == true and n == nil and not n and not f)

-- buffers
local b = buffer.create(8)
buffer.writeu32(b, 0, 0xDEADBEEF)
assert(buffer.readu32(b, 0) == 0xDEADBEEF and buffer.len(b) == 8)

-- vectors when the library exists
if vector then
	local v = vector.create(1, 2, 3)
	assert(v.x == 1 and v.Y == nil or v.y == 2)
	assert((v + v).z == 6)
end

return "OK"
