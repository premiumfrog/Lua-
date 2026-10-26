-- Control flow the analysis rewrites: loops, breaks, continues, nested exits and branch fusion.

-- numeric loops: float steps, negative steps, zero iterations, modification of the visible variable
local acc = {}
for i = 1, 2, 0.5 do
	table.insert(acc, i)
end
assert(#acc == 3 and acc[3] == 2)
local count = 0
for i = 10, 1, -3 do
	count += i
end
assert(count == 10 + 7 + 4 + 1)
for _ = 1, 0 do
	error("must not run")
end
local seen = 0
for i = 1, 3 do
	i = i * 10 -- assigning the copy does not change iteration
	seen += i
end
assert(seen == 60)

-- loops whose body always leaves
local function firstEven(t)
	for _, v in ipairs(t) do
		if v % 2 == 0 then
			return v
		end
		break
	end
	return nil
end
assert(firstEven({ 2, 3 }) == 2 and firstEven({ 1, 2 }) == nil)
local hits = 0
for i = 1, 5 do
	hits += 1
	break
end
assert(hits == 1)

-- continue, nested loops and labelled exits through repeat/while
local out = {}
for i = 1, 4 do
	for j = 1, 4 do
		if j > i then
			break
		end
		if (i + j) % 2 == 1 then
			continue
		end
		table.insert(out, i * 10 + j)
	end
end
assert(table.concat(out, ",") == "11,22,31,33,42,44")

local n, steps = 27, 0
while n ~= 1 do
	n = if n % 2 == 0 then n // 2 else 3 * n + 1
	steps += 1
end
assert(steps == 111)

local r = 0
repeat
	local stop = r >= 5
	r += 1
until stop
assert(r == 6)

-- generic loops over next, pairs with holes, ipairs stopping at nil
local t = { 1, 2, nil, 4, x = 5 }
local total = 0
for _, v in pairs(t) do
	total += v
end
assert(total == 12)
local ip = 0
for _ in ipairs(t) do
	ip += 1
end
assert(ip == 2)
local keys = 0
for _ in next, { a = 1, b = 2 } do
	keys += 1
end
assert(keys == 2)

-- closures capturing loop variables get a fresh variable per iteration
local fns = {}
for i = 1, 3 do
	fns[i] = function()
		return i
	end
end
assert(fns[1]() == 1 and fns[3]() == 3)
local wfns = {}
local k = 0
while k < 3 do
	k += 1
	local captured = k
	wfns[k] = function()
		captured += 10
		return captured
	end
end
assert(wfns[1]() == 11 and wfns[1]() == 21 and wfns[2]() == 12)

-- and/or chains, comparisons stored as values, branch on fields
local o = { flag = false, n = 3 }
local both = o.flag and "yes" or "no"
assert(both == "no")
local isBig = o.n > 2
assert(isBig == true)
local function cmp(a, b)
	return a < b, a <= b, a == b, a ~= b
end
local lt, le, eq, ne = cmp(1, 2)
assert(lt and le and not eq and ne)
assert(not (o.missing and o.missing.deeper))
if o.n % 3 == 0 then
	o.hit = true
end
assert(o.hit)

-- string/number comparisons error like the host
assert(not pcall(function()
	return 1 < "2"
end))

return "OK"
